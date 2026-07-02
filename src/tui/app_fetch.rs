use super::app::*;
use crate::error::Result;
use crate::model::Tweet;
use crate::parse::timeline::TimelinePage;
use crate::store::feed::{self, FeedVariant};
use crate::tui::event::{self, Event, EventTx};
use crate::tui::filter::{FilterCache, FilterDecision, FilterMode};
use crate::tui::focus::{self, FocusEntry, TweetDetail};
use crate::tui::source::{self, SourceKind};
use crate::tui::whisper::{self, NotifEntry, WhisperEntry};
use std::collections::{HashMap, HashSet};
use std::time::Instant;

impl App {
    pub fn load_initial(&mut self) {
        self.spawn_self_handle_resolve();
        self.fetch_source(false, false);
    }

    pub(super) fn spawn_self_handle_resolve(&self) {
        if self.self_handle.is_some() {
            return;
        }
        let client = self.client.clone();
        let tx = self.tx.clone();
        tokio::spawn(async move {
            match source::fetch_self_handle(&client).await {
                Ok(handle) => {
                    let _ = tx.send(Event::SelfHandleBackgroundResolved { handle });
                }
                Err(e) => {
                    tracing::warn!("background self handle resolve failed: {e}");
                }
            }
        });
    }

    pub(super) fn reload_source(&mut self) {
        if self.active == ActivePane::Detail
            && matches!(self.focus_stack.last(), Some(FocusEntry::Notifications(_)))
        {
            if let Some(FocusEntry::Notifications(view)) = self.focus_stack.last_mut() {
                view.loading = false;
                view.cursor = None;
                view.exhausted = false;
                view.set_selected(0);
            }
            self.fetch_notifications_view(false);
            return;
        }
        self.source.loading = false;
        self.source.silent_refreshing = false;
        self.source.cursor = None;
        self.source.exhausted = false;
        self.source.set_selected(0);
        self.fetch_source(false, false);
    }

    /// Serve a standing Home feed from the materialized `feed.db` buffer when
    /// it's warm, bypassing the live X fetch and the Ollama classification gate
    /// (rows arrive pre-classified). Returns `false` — and the caller falls
    /// back to a live fetch — for non-Home sources, a cold buffer, or a
    /// live (non-store) pagination cursor. Synchronous: SQLite keyset reads are
    /// sub-millisecond, so this routes straight through `handle_timeline_loaded`
    /// with no spawn.
    fn try_fetch_from_store(&mut self, kind: &SourceKind, append: bool, silent: bool) -> bool {
        const STORE_PAGE_SIZE: usize = 40;
        let variant = match kind {
            SourceKind::Home { following } => FeedVariant::from_following(*following),
            _ => return false,
        };
        let Some(store) = self.feed_store.as_ref() else {
            return false;
        };
        let cursor = if append {
            match self.source.cursor.clone() {
                Some(c) => Some(c),
                None => return false,
            }
        } else {
            None
        };
        if !feed::cursor_belongs_to_store(cursor.as_deref()) {
            return false;
        }
        if !append {
            match store.count(variant) {
                Ok(0) | Err(_) => return false,
                Ok(_) => {}
            }
        }
        let page = match store.read_page(variant, cursor.as_deref(), STORE_PAGE_SIZE) {
            Ok(p) => p,
            Err(e) => {
                tracing::warn!(?kind, error = %e, "feed store read failed; falling back to live");
                return false;
            }
        };
        let store_rubric = store.rubric_hash();
        if let Some(sig) = self.self_ingest.as_ref() {
            sig.activity.touch();
        }
        if let Some(cache) = self.filter_cache.as_mut() {
            match store_rubric.as_deref() {
                Some(h) if h == cache.rubric_hash() => {
                    for item in &page.items {
                        if let Some(v) = item.verdict {
                            cache.put(&item.tweet.rest_id, v);
                        }
                    }
                }
                Some(h) => {
                    tracing::info!(
                        store_rubric = h,
                        live_rubric = cache.rubric_hash(),
                        "feed store verdicts skipped: stored rubric differs from live rubric"
                    );
                }
                None => {
                    if !self.rubric_marker_warned {
                        self.rubric_marker_warned = true;
                        if self.self_ingest.is_none() {
                            tracing::warn!(
                                live_rubric = cache.rubric_hash(),
                                "feed store has no rubric marker: stored verdicts predate the \
                                 rubric marker and will be re-classified locally; restart \
                                 `unrager serve` to migrate the buffer"
                            );
                        } else {
                            tracing::debug!(
                                live_rubric = cache.rubric_hash(),
                                "feed store rubric marker unset; the in-process ingest worker \
                                 will record it on its first cycle"
                            );
                        }
                    }
                }
            }
        }
        let tweets: Vec<Tweet> = page.items.into_iter().map(|s| s.tweet).collect();
        let count = tweets.len();
        let tl = TimelinePage {
            tweets,
            next_cursor: page.next_cursor,
            top_cursor: None,
            profile_user: None,
        };
        tracing::info!(
            ?kind,
            append,
            silent,
            count,
            "timeline served from feed store"
        );
        self.handle_timeline_loaded(kind.clone(), Ok(tl), append, silent);
        true
    }

    pub(super) fn fetch_source(&mut self, append: bool, silent: bool) {
        let Some(kind) = self.source.kind.clone() else {
            return;
        };
        if self.source.loading || self.source.silent_refreshing {
            return;
        }
        if self.try_fetch_from_store(&kind, append, silent) {
            return;
        }
        if silent {
            self.source.silent_refreshing = true;
        } else {
            self.source.loading = true;
        }
        if self.fetch_baseline.is_none() {
            self.fetch_baseline = Some(self.source.tweets.len());
        }
        let client = self.client.clone();
        let tx = self.tx.clone();
        let cursor = if append {
            self.source.cursor.clone()
        } else {
            None
        };
        let seen_ids = self.home_seen_ids_for_request(&kind, append, silent);
        tracing::info!(
            kind = ?kind,
            append,
            silent,
            cursor = cursor.is_some(),
            seen_ids = seen_ids.len(),
            source_total = self.source.tweets.len(),
            "timeline fetch started"
        );
        tokio::spawn(async move {
            let mut result = source::fetch_page(&client, &kind, cursor.clone(), &seen_ids).await;
            if result.is_err() && !append {
                tracing::info!("transient fetch error, retrying in 2s");
                tokio::time::sleep(tokio::time::Duration::from_secs(2)).await;
                result = source::fetch_page(&client, &kind, cursor, &seen_ids).await;
            }
            let _ = tx.send(Event::TimelineLoaded {
                kind,
                result,
                append,
                silent,
            });
        });
    }

    /// Builds the `seenTweetIds` array sent to the For You GraphQL operation.
    /// Empty for everything else: the chronological Following feed
    /// (HomeLatestTimeline) and non-Home sources are cursor-driven and the
    /// field is either ignored or actively distorts the response. Capped to
    /// the most recent 100 IDs to keep the request body bounded.
    fn home_seen_ids_for_request(
        &self,
        kind: &SourceKind,
        append: bool,
        silent: bool,
    ) -> Vec<String> {
        if !matches!(kind, SourceKind::Home { following: false }) || !append || silent {
            return Vec::new();
        }
        const MAX_SEEN: usize = 100;
        let tweets = &self.source.tweets;
        let start = tweets.len().saturating_sub(MAX_SEEN);
        tweets[start..].iter().map(|t| t.rest_id.clone()).collect()
    }

    pub(super) fn handle_timeline_loaded(
        &mut self,
        kind: SourceKind,
        result: Result<TimelinePage>,
        append: bool,
        silent: bool,
    ) {
        if self.source.kind.as_ref() != Some(&kind) {
            if silent {
                self.source.silent_refreshing = false;
            } else {
                self.source.loading = false;
            }
            return;
        }
        if silent {
            self.source.silent_refreshing = false;
        } else {
            self.source.loading = false;
        }
        match result {
            Ok(mut page) => {
                if let Some(user) = page.profile_user.take()
                    && matches!(kind, SourceKind::User { .. })
                {
                    self.queue_avatar(&user);
                    let mut batch_seen = HashSet::new();
                    self.enqueue_about(&user, &mut batch_seen);
                    self.drain_about_pending();
                    self.source.profile_user = Some(user);
                }
                let total_incoming = page.tweets.len();
                let hidden = filter_incoming_page(
                    &mut page,
                    &kind,
                    self.feed_mode,
                    FilterContext {
                        mode: self.filter_mode,
                        has_classifier: self.filter_classifier.is_some(),
                        cache: self.filter_cache.as_ref(),
                        counted_ids: &mut self.filter_counted_ids,
                    },
                );
                self.filter_hidden_count += hidden;
                if matches!(kind, SourceKind::Home { following: true }) {
                    page.tweets.sort_by_key(|t| std::cmp::Reverse(t.created_at));
                }
                let filter_active =
                    matches!(self.filter_mode, FilterMode::On) && self.filter_classifier.is_some();
                let cold_start_following = !silent
                    && self.source.tweets.is_empty()
                    && matches!(kind, SourceKind::Home { following: true });
                let held: Vec<Tweet> = if !filter_active {
                    Vec::new()
                } else if cold_start_following {
                    std::mem::take(&mut page.tweets)
                } else if matches!(kind, SourceKind::Home { following: true }) {
                    let mut uncached = Vec::new();
                    let mut cached = Vec::with_capacity(page.tweets.len());
                    for t in page.tweets.drain(..) {
                        if self
                            .filter_cache
                            .as_ref()
                            .is_some_and(|c| c.get(&t.rest_id).is_some())
                        {
                            cached.push(t);
                        } else {
                            uncached.push(t);
                        }
                    }
                    page.tweets = cached;
                    uncached
                } else {
                    let split_idx = page
                        .tweets
                        .iter()
                        .position(|t| {
                            self.filter_cache
                                .as_ref()
                                .is_some_and(|c| c.get(&t.rest_id).is_none())
                        })
                        .unwrap_or(page.tweets.len());
                    page.tweets.drain(split_idx..).collect()
                };
                let old_len = self.source.tweets.len();
                if !append && !silent {
                    self.pending_classification.clear();
                }
                let added;
                if silent {
                    added = self.source.prepend_fresh(page);
                    if added > 0 && self.source.state.selected > 0 {
                        self.source.state.selected += added;
                    }
                    if added > 0 {
                        self.sort_source_if_following();
                    }
                } else if append {
                    self.source.append(page);
                    added = self.source.tweets.len().saturating_sub(old_len);
                } else {
                    self.source.reset_with(page);
                    added = self.source.tweets.len();
                }
                for t in &self.source.tweets {
                    if t.favorited {
                        self.liked_tweet_ids.insert(t.rest_id.clone());
                    }
                }
                let held_count = held.len();
                self.pending_classification.extend(held.iter().cloned());
                if total_incoming > 0 {
                    // `hidden` counts only newly-classified tweets (ids fresh
                    // to `filter_counted_ids`), so a heavily-filtered page of
                    // genuinely new tweets still reads as progress — only a
                    // page that surfaced nothing new (X recycling behind a
                    // stale cursor) leaves all three at zero. A run of those
                    // pauses the auto-paginate burst (via `try_advance_fetch_target`)
                    // without dead-ending the feed — `exhausted` stays
                    // cursor-driven, so scrolling re-attempts the work and X's
                    // recycling never shows a false `[end of timeline]`.
                    let made_progress = added > 0 || held_count > 0 || hidden > 0;
                    if append && !made_progress {
                        self.source.empty_appends = self.source.empty_appends.saturating_add(1);
                        if self.source.empty_appends == EMPTY_APPEND_LIMIT {
                            tracing::info!(
                                empty_appends = self.source.empty_appends,
                                "pagination paused: X is recycling already-loaded tweets; retries on scroll"
                            );
                        }
                    } else {
                        self.source.empty_appends = 0;
                    }
                }
                self.error = None;
                let mut new_tweets: Vec<Tweet> = if silent {
                    self.source.tweets[..added].to_vec()
                } else if append {
                    self.source.tweets[old_len..].to_vec()
                } else {
                    self.source.tweets.clone()
                };
                new_tweets.extend(held);
                tracing::info!(
                    kind = ?kind,
                    append,
                    silent,
                    incoming = total_incoming,
                    hidden,
                    held = held_count,
                    pending = self.pending_classification.len(),
                    inflight = self.filter_inflight.len(),
                    added,
                    cursor = self.source.cursor.is_some(),
                    exhausted = self.source.exhausted,
                    total = self.source.tweets.len(),
                    "timeline fetch loaded"
                );
                self.queue_source_media(&new_tweets);
                self.queue_filter_classification(new_tweets);
                if silent {
                    self.fetch_baseline = None;
                    self.clear_status();
                }
                self.drain_pending_classification();
            }
            Err(e) => {
                self.fetch_baseline = None;
                if silent {
                    tracing::warn!("silent timeline refresh failed: {e}");
                } else {
                    tracing::warn!(kind = ?kind, append, "timeline fetch failed: {e}");
                    self.error = Some(e.to_string());
                    self.clear_status();
                }
            }
        }
    }

    pub(super) fn open_notifications(&mut self) {
        if matches!(self.focus_stack.last(), Some(FocusEntry::Notifications(_))) {
            self.active = ActivePane::Detail;
            return;
        }
        self.focus_stack.push(FocusEntry::Notifications(
            crate::tui::focus::NotificationsView::new(),
        ));
        self.active = ActivePane::Detail;
        self.fetch_notifications_view(false);
    }

    pub(super) fn fetch_notifications_view(&mut self, append: bool) {
        let Some(FocusEntry::Notifications(view)) = self.focus_stack.last_mut() else {
            return;
        };
        if view.loading {
            tracing::debug!("notification fetch skipped: already loading");
            return;
        }
        tracing::info!(append, "notification fetch started");
        view.loading = true;
        let cursor = if append { view.cursor.clone() } else { None };
        let client = self.client.clone();
        let tx = self.tx.clone();
        tokio::spawn(async move {
            let timeout_dur = tokio::time::Duration::from_secs(15);
            let mut result = match tokio::time::timeout(
                timeout_dur,
                whisper::fetch_notifications(&client, cursor.as_deref()),
            )
            .await
            {
                Ok(r) => r,
                Err(_) => Err(crate::error::Error::GraphqlShape(
                    "notification fetch timed out".into(),
                )),
            };
            if result.is_err() && !append {
                tracing::info!("transient notification fetch error, retrying in 2s");
                tokio::time::sleep(tokio::time::Duration::from_secs(2)).await;
                result = match tokio::time::timeout(
                    timeout_dur,
                    whisper::fetch_notifications(&client, cursor.as_deref()),
                )
                .await
                {
                    Ok(r) => r,
                    Err(_) => Err(crate::error::Error::GraphqlShape(
                        "notification fetch timed out".into(),
                    )),
                };
            }
            let _ = tx.send(Event::NotificationPageLoaded { result, append });
        });
    }

    pub(super) fn handle_notification_page_loaded(
        &mut self,
        result: Result<crate::parse::notification::NotificationPage>,
        append: bool,
    ) {
        let Some(FocusEntry::Notifications(view)) = self.focus_stack.last_mut() else {
            tracing::debug!("notification page arrived but pane no longer active, discarding");
            return;
        };
        view.loading = false;
        let mut avatar_urls: Vec<String> = Vec::new();
        match result {
            Ok(page) => {
                tracing::info!(
                    count = page.notifications.len(),
                    has_cursor = page.next_cursor.is_some(),
                    append,
                    "notification page loaded"
                );
                let mut favorited_ids = Vec::new();
                for n in &page.notifications {
                    if n.target_tweet_favorited
                        && let Some(tid) = &n.target_tweet_id
                    {
                        favorited_ids.push(tid.clone());
                    }
                    if let Some(actor) = n.actors.first()
                        && let Some(url) = actor.avatar_url.as_deref()
                        && !url.is_empty()
                    {
                        avatar_urls.push(url.to_string());
                    }
                }
                if append {
                    view.append(page);
                } else {
                    view.reset_with(page);
                }
                view.error = None;
                for tid in favorited_ids {
                    self.liked_tweet_ids.insert(tid);
                }
                self.error = None;
                self.clear_status();
            }
            Err(ref e) => {
                tracing::warn!("notification fetch failed: {e}");
                view.error = Some(e.to_string());
                self.clear_status();
            }
        }
        if self.feed_avatars && self.media.is_kitty() {
            for url in avatar_urls {
                self.media.ensure_avatar_url(&url, &self.tx);
            }
        }
    }

    pub(super) fn fetch_thread(&mut self, focal_id: String) {
        let client = self.client.clone();
        let tx = self.tx.clone();
        tokio::spawn(async move {
            let result = focus::fetch_thread(&client, &focal_id).await;
            let _ = tx.send(Event::ThreadLoaded { focal_id, result });
        });
    }

    /// The topmost still-loading tweet detail for `focal_id`, wherever it
    /// sits in the focus stack. A thread result must land on its own detail
    /// even when the user has stacked notifications/likers/ask panes on top
    /// (or opened another tweet) while the fetch was in flight — otherwise
    /// the buried detail is stuck on "loading" forever. A detail that was
    /// popped or already loaded simply matches nothing and the result drops.
    fn loading_detail_mut(&mut self, focal_id: &str) -> Option<&mut TweetDetail> {
        self.focus_stack
            .iter_mut()
            .rev()
            .find_map(|entry| match entry {
                FocusEntry::Tweet(d) if d.loading && d.tweet.rest_id == focal_id => Some(d),
                _ => None,
            })
    }

    pub(super) fn handle_thread_loaded(&mut self, focal_id: String, result: Result<TimelinePage>) {
        let scroll_target = if self.pending_notif_scroll.as_deref() == Some(focal_id.as_str()) {
            self.pending_notif_scroll.take()
        } else {
            None
        };
        let reply_sort = self.reply_sort;
        let Some(detail) = self.loading_detail_mut(&focal_id) else {
            tracing::debug!(
                focal_id,
                "thread result arrived for a gone detail, discarding"
            );
            return;
        };
        let replies_snapshot: Vec<Tweet> = match result {
            Ok(page) => {
                if scroll_target.is_some() {
                    apply_conversation_view(detail, page, scroll_target.as_deref());
                } else {
                    detail.apply_page(page);
                    detail.sort_replies(reply_sort);
                }
                detail.replies.clone()
            }
            Err(e) => {
                detail.loading = false;
                detail.error = Some(e.to_string());
                Vec::new()
            }
        };
        self.track_liked_tweets(&replies_snapshot);
        self.queue_thread_media(&replies_snapshot);
    }

    pub(super) fn handle_inline_thread_loaded(
        &mut self,
        focal_id: String,
        result: Result<TimelinePage>,
    ) {
        let Some(entry) = self.inline_threads.get_mut(&focal_id) else {
            return;
        };
        entry.loading = false;
        let replies_snapshot: Vec<Tweet> = match result {
            Ok(page) => {
                let all_tweets: Vec<Tweet> = page
                    .tweets
                    .into_iter()
                    .filter(|t| t.rest_id != focal_id)
                    .collect();
                let tree = build_reply_tree(&focal_id, &all_tweets);
                let n = tree.len();
                entry.replies = tree;
                entry.error = None;
                self.set_status(format!("thread loaded ({n} replies)"));
                self.inline_threads
                    .get(&focal_id)
                    .map(|e| e.replies.iter().map(|(_, t)| t.clone()).collect())
                    .unwrap_or_default()
            }
            Err(e) => {
                entry.error = Some(e.to_string());
                self.clear_status();
                Vec::new()
            }
        };
        self.queue_thread_media(&replies_snapshot);
    }

    pub(super) fn open_tweet_by_id(&mut self, id: String) {
        let request_id = event::next_request_id();
        self.pending_open = Some(request_id);
        let client = self.client.clone();
        let tx = self.tx.clone();
        tokio::spawn(async move {
            let result = source::fetch_single_tweet(&client, &id).await;
            let _ = tx.send(Event::OpenTweetResolved { request_id, result });
        });
    }

    pub(super) fn handle_open_tweet_resolved(
        &mut self,
        request_id: event::RequestId,
        result: Result<Tweet>,
    ) {
        if self.pending_open != Some(request_id) {
            return;
        }
        self.pending_open = None;
        match result {
            Ok(tweet) => self.push_tweet(tweet),
            Err(e) => {
                self.pending_notif_scroll = None;
                self.error = Some(e.to_string());
            }
        }
    }

    pub(super) fn open_user_in_detail(&mut self, handle: String, user_id: Option<String>) {
        let request_id = event::next_request_id();
        self.pending_user_detail = Some(request_id);
        self.set_status(format!("loading @{handle}…"));
        let client = self.client.clone();
        let tx = self.tx.clone();
        tokio::spawn(async move {
            let result = match user_id {
                Some(id) => crate::tui::source::fetch_user_tweets_by_id(&client, &id, None).await,
                None => {
                    crate::tui::source::fetch_page(&client, &SourceKind::User { handle }, None, &[])
                        .await
                }
            };
            let _ = tx.send(Event::UserTimelineLoaded { request_id, result });
        });
    }

    pub(super) fn handle_user_timeline_loaded(
        &mut self,
        request_id: event::RequestId,
        result: Result<TimelinePage>,
    ) {
        if self.pending_user_detail != Some(request_id) {
            tracing::debug!("user timeline result arrived for an abandoned open, discarding");
            return;
        }
        self.pending_user_detail = None;
        match result {
            Ok(page) => {
                let mut tweets = page.tweets.into_iter();
                let Some(focal) = tweets.next() else {
                    self.set_status("no tweets from this user");
                    return;
                };
                self.ensure_tweet_resources(&focal);
                let mut detail = TweetDetail::new(focal);
                detail.loading = false;
                detail.replies = tweets.collect();
                for t in &detail.replies {
                    self.ensure_tweet_resources(t);
                }
                self.focus_stack.push(FocusEntry::Tweet(detail));
                self.active = ActivePane::Detail;
                self.clear_status();
            }
            Err(e) => {
                self.error = Some(e.to_string());
            }
        }
    }

    pub(super) fn open_selected_notification(&mut self) {
        let Some(FocusEntry::Notifications(view)) = self.focus_stack.last() else {
            return;
        };
        let Some(notif) = view.notifications.get(view.selected()).cloned() else {
            return;
        };
        let actor_idx = view.actor_cursor.unwrap_or(0);
        self.notif_seen.mark_seen(&notif.id);

        match notif.notification_type.as_str() {
            "Like" | "Reply" | "Quote" | "Mention" | "Retweet" => {
                if let Some(tweet_id) = notif.target_tweet_id {
                    self.pending_notif_scroll = Some(tweet_id.clone());
                    self.open_tweet_by_id(tweet_id);
                } else {
                    self.set_status("no target tweet for this notification");
                }
            }
            "Follow" => {
                if let Some(actor) = notif.actors.get(actor_idx) {
                    self.open_user_in_detail(actor.handle.clone(), Some(actor.rest_id.clone()));
                } else {
                    self.set_status("no actor for this follow notification");
                }
            }
            _ => {
                self.set_status("nothing to open for this notification");
            }
        }
    }

    pub(super) fn show_likers_for_selected(&mut self) {
        if self.active == ActivePane::Detail
            && matches!(self.focus_stack.last(), Some(FocusEntry::Notifications(_)))
        {
            self.set_status("L works on tweets, not notifications");
            return;
        }
        let tweet = match self.active {
            ActivePane::Source => self.source.tweets.get(self.source.selected()).cloned(),
            ActivePane::Detail => self.selected_tweet().cloned(),
        };
        let Some(tweet) = tweet else {
            return;
        };
        let Some(ref self_handle) = self.self_handle else {
            self.set_status("self handle not resolved yet");
            return;
        };
        if !tweet.author.handle.eq_ignore_ascii_case(self_handle) {
            self.set_status("likers only visible on your own tweets");
            return;
        }
        let tweet_id = tweet.rest_id.clone();
        let title = format!("likers · {} likes", tweet.like_count);
        let view = crate::tui::focus::LikersView::new(tweet_id.clone(), title);
        self.focus_stack.push(FocusEntry::Likers(view));
        self.active = ActivePane::Detail;
        self.fetch_likers_page(tweet_id, None, false);
    }

    pub(super) fn fetch_likers_page(
        &mut self,
        tweet_id: String,
        cursor: Option<String>,
        append: bool,
    ) {
        let client = self.client.clone();
        let tx = self.tx.clone();
        tokio::spawn(async move {
            let result =
                crate::tui::focus::fetch_likers(&client, &tweet_id, cursor.as_deref()).await;
            let _ = tx.send(Event::LikersPageLoaded {
                tweet_id,
                result,
                append,
            });
        });
    }

    pub(super) fn handle_likers_page_loaded(
        &mut self,
        tweet_id: String,
        result: Result<crate::tui::focus::LikersPage>,
        append: bool,
    ) {
        let Some(FocusEntry::Likers(view)) = self.focus_stack.last_mut() else {
            return;
        };
        if view.tweet_id != tweet_id {
            return;
        }
        view.loading = false;
        let mut avatar_urls: Vec<String> = Vec::new();
        match result {
            Ok(page) => {
                let mut all_dupes = false;
                if append {
                    let existing: std::collections::HashSet<String> =
                        view.users.iter().map(|u| u.rest_id.clone()).collect();
                    let incoming = page.users.len();
                    let before = view.users.len();
                    for u in page.users {
                        if !existing.contains(&u.rest_id) {
                            if let Some(url) = u.avatar_url.as_deref() {
                                avatar_urls.push(url.to_string());
                            }
                            view.users.push(u);
                        }
                    }
                    all_dupes = incoming > 0 && view.users.len() == before;
                } else {
                    avatar_urls.extend(
                        page.users
                            .iter()
                            .filter_map(|u| u.avatar_url.clone())
                            .filter(|s| !s.is_empty()),
                    );
                    view.users = page.users;
                }
                view.cursor = page.next_cursor;
                view.exhausted = view.cursor.is_none() || all_dupes;
                view.error = None;
                tracing::info!(
                    tweet_id = %view.tweet_id,
                    total = view.users.len(),
                    append,
                    "likers loaded"
                );
            }
            Err(e) => {
                tracing::warn!("likers fetch failed: {e}");
                view.error = Some(e.to_string());
            }
        }
        if self.feed_avatars && self.media.is_kitty() {
            for url in avatar_urls {
                self.media.ensure_avatar_url(&url, &self.tx);
            }
        }
    }

    pub(super) fn queue_source_media(&mut self, tweets: &[Tweet]) {
        self.queue_about_fetch(tweets);
        if !self.media.supported() {
            return;
        }
        // YouTube and Article cards always render in the feed; their cover
        // thumbnails and YouTube oEmbed metadata load without waiting for
        // auto-expand.
        for t in tweets {
            self.media.ensure_tweet_card_thumbnails(t, &self.tx);
            self.youtube.ensure_tweet(t, &self.tx);
            self.songlink_reg.ensure_tweet(t, &self.tx);
        }
        if self.feed_avatars && self.media.is_kitty() {
            for t in tweets {
                self.queue_avatar(&t.author);
            }
        }
        if !self.media_auto_expand {
            return;
        }
        for t in tweets {
            self.media.ensure_tweet_media(t, &self.tx);
        }
    }

    pub(super) fn queue_avatar(&mut self, user: &crate::model::User) {
        if let Some(url) = user.avatar_url.as_deref() {
            self.media.ensure_avatar_url(url, &self.tx);
        }
    }

    pub(super) fn queue_about_fetch(&mut self, tweets: &[Tweet]) {
        let mut batch: HashSet<String> = HashSet::new();
        for t in tweets {
            self.enqueue_about(&t.author, &mut batch);
            if let Some(q) = t.quoted_tweet.as_deref() {
                self.enqueue_about(&q.author, &mut batch);
            }
        }
        self.drain_about_pending();
    }

    pub(super) fn enqueue_about(&mut self, user: &crate::model::User, batch: &mut HashSet<String>) {
        if user.rest_id.is_empty() || user.handle.is_empty() {
            return;
        }
        if !batch.insert(user.rest_id.clone()) {
            return;
        }
        if self.about.has(&user.rest_id) {
            return;
        }
        if self.about_inflight.contains(&user.rest_id) {
            return;
        }
        if self.about_pending.iter().any(|(id, _)| id == &user.rest_id) {
            return;
        }
        self.about_pending
            .push_back((user.rest_id.clone(), user.handle.clone()));
    }

    /// Pops one request per call, only when nothing is in flight and the
    /// read budget is healthy. Called from `queue_about_fetch` on
    /// timeline load AND from the per-second Tick, so a single big page
    /// drips out at ~1 request/sec instead of bursting and tripping the
    /// AboutAccountQuery rate limit.
    pub(super) fn drain_about_pending(&mut self) {
        if !self.about_inflight.is_empty() {
            return;
        }
        if self.client.about_rate_limit_remaining().is_some() {
            return;
        }
        let Some((rest_id, handle)) = self.about_pending.pop_front() else {
            return;
        };
        if self.about.has(&rest_id) {
            return;
        }
        self.about_inflight.insert(rest_id.clone());
        self.about_fetcher.spawn(rest_id, handle, self.tx.clone());
    }

    pub(super) fn handle_about_profile_resolved(
        &mut self,
        rest_id: String,
        result: crate::tui::about_fetch::FetchOutcome,
    ) {
        self.about_inflight.remove(&rest_id);
        match result {
            Ok(profile) => self.about.put(&rest_id, profile),
            Err(()) => {
                // Transport / rate-limit / parse failure. Do not poison
                // the cache — leave the entry untracked so a future feed
                // load can retry once the limit clears.
            }
        }
        self.dirty = true;
        self.drain_about_pending();
    }

    pub(super) fn queue_thread_media(&mut self, replies: &[Tweet]) {
        if !self.media.supported() {
            return;
        }
        for t in replies {
            self.ensure_tweet_resources(t);
        }
    }

    pub(super) fn handle_whisper_poll_tick(&mut self) {
        self.whisper.tick();
        let should_poll = self.whisper.should_poll();
        if should_poll
            && self.source.selected() == 0
            && !self.source.loading
            && !self.source.silent_refreshing
            && matches!(self.source.kind, Some(SourceKind::Home { following: true }))
        {
            self.fetch_source(false, true);
        }
        if should_poll {
            self.whisper.poll_inflight = true;
            self.whisper.last_poll = Some(Instant::now());
            let client = self.client.clone();
            let tx = self.tx.clone();
            tokio::spawn(async move {
                match whisper::fetch_notifications(&client, None).await {
                    Ok(page) => {
                        let _ = tx.send(Event::NotificationsLoaded {
                            notifications: page.notifications,
                            top_cursor: page.top_cursor,
                        });
                    }
                    Err(e) => {
                        let _ = tx.send(Event::NotificationsFailed { err: e.to_string() });
                    }
                }
            });
        }
    }

    pub(super) fn handle_notifications_loaded(
        &mut self,
        raw_notifs: Vec<crate::parse::notification::RawNotification>,
        _top_cursor: Option<String>,
    ) {
        self.whisper.poll_inflight = false;

        self.notif_unread_badge = raw_notifs
            .iter()
            .filter(|n| !self.notif_seen.is_seen(&n.id))
            .count();

        let mut new_avatar_urls: Vec<String> = Vec::new();
        if let Some(FocusEntry::Notifications(view)) = self.focus_stack.last_mut()
            && view.selected() == 0
            && !view.loading
        {
            let before: std::collections::HashSet<String> =
                view.notifications.iter().map(|n| n.id.clone()).collect();
            let added = view.prepend_fresh(&raw_notifs);
            if added > 0 {
                tracing::debug!(added, "merged fresh notifs into open view");
                for n in view.notifications.iter().take(added) {
                    if before.contains(&n.id) {
                        continue;
                    }
                    if let Some(actor) = n.actors.first()
                        && let Some(url) = actor.avatar_url.as_deref()
                        && !url.is_empty()
                    {
                        new_avatar_urls.push(url.to_string());
                    }
                }
            }
        }
        if self.feed_avatars && self.media.is_kitty() {
            for url in new_avatar_urls {
                self.media.ensure_avatar_url(&url, &self.tx);
            }
        }

        let first_poll = self.whisper.watermark_ts == 0;

        let newest_ts = raw_notifs
            .iter()
            .map(|n| n.timestamp.timestamp_millis())
            .max()
            .unwrap_or(0);

        if first_poll {
            self.whisper.watermark_ts = newest_ts;
            return;
        }

        let wm = self.whisper.watermark_ts;
        let new_notifs: Vec<_> = raw_notifs
            .into_iter()
            .filter(|n| n.timestamp.timestamp_millis() > wm)
            .collect();

        if newest_ts > wm {
            self.whisper.watermark_ts = newest_ts;
        }

        let entries: Vec<NotifEntry> = new_notifs.iter().map(NotifEntry::from_raw).collect();

        let mut milestones = Vec::new();
        for rn in &new_notifs {
            if let (Some(tweet_id), Some(like_count), Some(created_at)) = (
                &rn.target_tweet_id,
                rn.target_tweet_like_count,
                rn.target_tweet_created_at,
            ) {
                if let Some(milestone) = self
                    .whisper
                    .milestones
                    .update(tweet_id, like_count, created_at)
                {
                    milestones.push((tweet_id.clone(), milestone, rn.target_tweet_snippet.clone()));
                }
            }
        }
        self.whisper.milestones.gc();

        let llm_request = self.whisper.ingest(&entries, &milestones);

        match llm_request {
            whisper::LlmRequest::None => {}
            whisper::LlmRequest::SingleWhisper(entry) => {
                if !self.whisper.llm_inflight {
                    if let Some(ollama) = self.filter_cfg.as_ref().map(|c| c.ollama.clone()) {
                        self.whisper.llm_inflight = true;
                        whisper::whisper_llm_async(entry, ollama, self.tx.clone());
                    } else {
                        let text = whisper::build_heuristic_whisper(&entry);
                        self.whisper.push_entry(WhisperEntry {
                            text,
                            created: Instant::now(),
                            priority: entry.priority,
                        });
                    }
                }
            }
            whisper::LlmRequest::SurgeSummary(surge_entries) => {
                if !self.whisper.llm_inflight {
                    if let Some(ollama) = self.filter_cfg.as_ref().map(|c| c.ollama.clone()) {
                        self.whisper.llm_inflight = true;
                        whisper::surge_llm_async(surge_entries, ollama, self.tx.clone());
                    } else {
                        let text = whisper::build_heuristic_whisper(
                            surge_entries.first().unwrap_or(&NotifEntry {
                                kind: whisper::NotifKind::Other,
                                actor_handle: String::new(),
                                target_tweet_id: None,
                                target_tweet_snippet: None,
                                target_tweet_like_count: None,
                                priority: 5,
                            }),
                        );
                        self.whisper.text = text;
                    }
                }
            }
        }
    }

    pub(super) fn refresh_current_thread(&mut self) {
        let Some(FocusEntry::Tweet(detail)) = self.focus_stack.last() else {
            return;
        };
        if detail.loading {
            return;
        }
        let focal_id = detail.tweet.rest_id.clone();
        self.set_status("refreshing thread…");
        let client = self.client.clone();
        let tx = self.tx.clone();
        tokio::spawn(async move {
            let result = focus::fetch_thread(&client, &focal_id).await;
            let _ = tx.send(Event::ThreadRefreshed { focal_id, result });
        });
    }

    pub(super) fn handle_thread_refreshed(
        &mut self,
        focal_id: String,
        result: Result<TimelinePage>,
    ) {
        let Some(FocusEntry::Tweet(detail)) = self.focus_stack.last_mut() else {
            return;
        };
        if detail.tweet.rest_id != focal_id {
            return;
        }
        match result {
            Ok(page) => {
                let before = detail.replies.len();
                let selected_id = detail.selected_reply().map(|t| t.rest_id.clone());
                detail.merge_refreshed_replies(page);
                detail.sort_replies(self.reply_sort);
                if let Some(ref id) = selected_id
                    && let Some(pos) = detail.replies.iter().position(|t| t.rest_id == *id)
                {
                    detail.state.selected = pos + 1;
                }
                let added = detail.replies.len().saturating_sub(before);
                if added == 0 {
                    self.set_status("thread up to date");
                } else {
                    self.set_status(format!("+{added} new"));
                }
            }
            Err(e) => {
                tracing::debug!(focal_id, "thread refresh failed: {e}");
                self.set_status("refresh failed");
            }
        }
    }
}

pub fn apply_conversation_view(
    detail: &mut TweetDetail,
    page: TimelinePage,
    scroll_to: Option<&str>,
) {
    detail.loading = false;
    let tweets_by_id: HashMap<String, Tweet> = page
        .tweets
        .into_iter()
        .map(|t| (t.rest_id.clone(), t))
        .collect();

    let mut root_id = detail.tweet.rest_id.clone();
    let mut visited = HashSet::new();
    while visited.insert(root_id.clone()) {
        if let Some(t) = tweets_by_id.get(&root_id) {
            if let Some(ref parent_id) = t.in_reply_to_tweet_id {
                if tweets_by_id.contains_key(parent_id) {
                    root_id = parent_id.clone();
                    continue;
                }
            }
        }
        break;
    }

    if let Some(root) = tweets_by_id.get(&root_id).cloned() {
        detail.tweet = root;
    }

    let mut conversation: Vec<Tweet> = tweets_by_id
        .into_values()
        .filter(|t| t.rest_id != detail.tweet.rest_id)
        .collect();
    conversation.sort_by_key(|t| t.created_at);

    let scroll_idx = scroll_to
        .and_then(|target| {
            conversation
                .iter()
                .position(|t| t.rest_id == target)
                .map(|i| i + 1)
        })
        .unwrap_or(0);

    detail.replies = conversation;
    detail.state = crate::tui::source::PaneState::with_selected(scroll_idx);
}

pub fn build_reply_tree(root_id: &str, tweets: &[Tweet]) -> Vec<(usize, Tweet)> {
    let mut children: HashMap<&str, Vec<&Tweet>> = HashMap::new();
    for t in tweets {
        if let Some(parent) = t.in_reply_to_tweet_id.as_deref() {
            children.entry(parent).or_default().push(t);
        }
    }
    for group in children.values_mut() {
        group.sort_by_key(|t| t.created_at);
    }
    let mut result = Vec::new();
    let mut stack: Vec<(&str, usize)> = vec![(root_id, 0)];
    while let Some((parent_id, depth)) = stack.pop() {
        if let Some(kids) = children.get(parent_id) {
            for kid in kids.iter().rev() {
                result.push((depth, (*kid).clone()));
                stack.push((&kid.rest_id, depth + 1));
            }
        }
    }
    result
}

pub struct FilterContext<'a> {
    pub mode: FilterMode,
    pub has_classifier: bool,
    pub cache: Option<&'a FilterCache>,
    pub counted_ids: &'a mut HashSet<String>,
}

pub fn filter_incoming_page(
    page: &mut TimelinePage,
    kind: &SourceKind,
    feed_mode: FeedMode,
    filter: FilterContext<'_>,
) -> usize {
    if matches!(feed_mode, FeedMode::Originals) && matches!(kind, SourceKind::Home { .. }) {
        page.tweets.retain(|t| {
            t.in_reply_to_tweet_id.is_none()
                && t.quoted_tweet.is_none()
                && !t.text.starts_with("RT @")
        });
    }
    let mut hidden = 0;
    if matches!(filter.mode, FilterMode::On) && filter.has_classifier {
        if let Some(cache) = filter.cache {
            page.tweets.retain(|t| {
                if matches!(cache.get(&t.rest_id), Some(FilterDecision::Hide)) {
                    if filter.counted_ids.insert(t.rest_id.clone()) {
                        hidden += 1;
                    }
                    false
                } else {
                    true
                }
            });
        }
    }
    hidden
}

pub fn spawn_update_check(tx: EventTx) {
    tokio::spawn(async move {
        match crate::update::check_latest().await {
            Ok(Some(version)) => {
                tracing::info!("update available: {version}");
                let _ = tx.send(Event::UpdateAvailable { version });
            }
            Ok(None) => {
                tracing::debug!("no update available");
            }
            Err(e) => {
                tracing::debug!("update check failed: {e}");
            }
        }
    });
}

#[cfg(test)]
mod store_tests {
    use super::*;
    use crate::store::feed::FeedStore;
    use crate::tui::filter::{Classifier, FilterConfig, OllamaConfig};
    use crate::tui::source::Source;
    use crate::tui::test_util::{dummy_app, make_tweet};

    fn dummy_cfg() -> FilterConfig {
        FilterConfig {
            drop_topics: vec![],
            extra_guidance: String::new(),
            ollama: OllamaConfig {
                model: "test".into(),
                host: "http://127.0.0.1:1".into(),
                timeout_seconds: 1,
                keep_alive: "10s".into(),
            },
        }
    }

    fn at(id: &str, ts: i64) -> Tweet {
        let mut t = make_tweet(id, "x");
        t.created_at = chrono::DateTime::from_timestamp(ts, 0).unwrap();
        t
    }

    #[tokio::test]
    async fn store_serves_following_newest_first() {
        let (mut app, _rx, tmp) = dummy_app();
        let mut store = FeedStore::open_writer(&tmp.path().join("feed.db"))
            .unwrap()
            .unwrap();
        for (id, ts) in [("a", 100), ("b", 300), ("c", 200)] {
            store.upsert(FeedVariant::Following, &at(id, ts)).unwrap();
        }
        app.feed_store = Some(store);
        app.filter_mode = FilterMode::Off;
        app.source = Source::new(SourceKind::Home { following: true });
        app.fetch_source(false, false);
        let ids: Vec<&str> = app
            .source
            .tweets
            .iter()
            .map(|t| t.rest_id.as_str())
            .collect();
        assert_eq!(ids, vec!["b", "c", "a"], "chronological, newest first");
        assert!(!app.source.loading, "store read finishes synchronously");
    }

    #[tokio::test]
    async fn store_drops_hide_keeps_keep_without_ollama() {
        let (mut app, _rx, tmp) = dummy_app();
        let mut store = FeedStore::open_writer(&tmp.path().join("feed.db"))
            .unwrap()
            .unwrap();
        store.ensure_rubric_hash("h").unwrap();
        // For You orders by ingest order DESC, so insert 3,2,1 → reads 1,2,3.
        for (id, v) in [
            ("3", FilterDecision::Keep),
            ("2", FilterDecision::Hide),
            ("1", FilterDecision::Keep),
        ] {
            store
                .upsert(FeedVariant::ForYou, &make_tweet(id, "x"))
                .unwrap();
            store.update_verdict(FeedVariant::ForYou, id, v).unwrap();
        }
        app.feed_store = Some(store);
        app.filter_cache = Some(FilterCache::open(&tmp.path().join("fc.db"), "h".into()).unwrap());
        app.filter_classifier = Some(Classifier::new(&dummy_cfg()));
        app.filter_mode = FilterMode::On;
        app.source = Source::new(SourceKind::Home { following: false });
        app.fetch_source(false, false);
        let ids: Vec<&str> = app
            .source
            .tweets
            .iter()
            .map(|t| t.rest_id.as_str())
            .collect();
        assert_eq!(ids, vec!["1", "3"], "Hide dropped, Keep shown");
        assert!(
            app.filter_inflight.is_empty(),
            "pre-classified rows make no Ollama calls"
        );
        assert!(app.pending_classification.is_empty());
    }

    #[tokio::test]
    async fn store_following_cold_start_makes_no_ollama_calls() {
        // Regression guard: a cold-start Following load from the store routes
        // every row through the cold_start_following held/drain path, but the
        // seeded verdicts make each a cache hit — so zero classification spawns.
        let (mut app, _rx, tmp) = dummy_app();
        let mut store = FeedStore::open_writer(&tmp.path().join("feed.db"))
            .unwrap()
            .unwrap();
        store.ensure_rubric_hash("h").unwrap();
        for (id, ts) in [("a", 300), ("b", 200), ("c", 100)] {
            store.upsert(FeedVariant::Following, &at(id, ts)).unwrap();
            store
                .update_verdict(FeedVariant::Following, id, FilterDecision::Keep)
                .unwrap();
        }
        app.feed_store = Some(store);
        app.filter_cache = Some(FilterCache::open(&tmp.path().join("fc.db"), "h".into()).unwrap());
        app.filter_classifier = Some(Classifier::new(&dummy_cfg()));
        app.filter_mode = FilterMode::On;
        app.source = Source::new(SourceKind::Home { following: true });
        app.fetch_source(false, false);
        assert!(
            app.filter_inflight.is_empty(),
            "pre-classified cold-start Following must not spawn Ollama"
        );
        assert!(app.pending_classification.is_empty());
        let ids: Vec<&str> = app
            .source
            .tweets
            .iter()
            .map(|t| t.rest_id.as_str())
            .collect();
        assert_eq!(
            ids,
            vec!["a", "b", "c"],
            "all Keep rows shown, newest first"
        );
    }

    /// Verdicts stored under a previous rubric must not be laundered into
    /// the live FilterCache under the new rubric hash, and the rows must
    /// flow through as unclassified instead of being silently hidden by the
    /// old rubric's Hide decision.
    #[tokio::test]
    async fn stale_rubric_store_verdicts_are_never_seeded() {
        let (mut app, _rx, tmp) = dummy_app();
        let mut store = FeedStore::open_writer(&tmp.path().join("feed.db"))
            .unwrap()
            .unwrap();
        store.ensure_rubric_hash("old-rubric").unwrap();
        store
            .upsert(FeedVariant::ForYou, &make_tweet("1", "x"))
            .unwrap();
        store
            .update_verdict(FeedVariant::ForYou, "1", FilterDecision::Hide)
            .unwrap();
        app.feed_store = Some(store);
        app.filter_cache =
            Some(FilterCache::open(&tmp.path().join("fc.db"), "new-rubric".into()).unwrap());
        app.filter_classifier = Some(Classifier::new(&dummy_cfg()));
        app.filter_mode = FilterMode::On;
        app.source = Source::new(SourceKind::Home { following: false });
        app.fetch_source(false, false);
        assert!(
            !app.filter_cache.as_ref().unwrap().contains("1"),
            "old-rubric verdict must not be written into the new-rubric cache"
        );
        let treated_unclassified = app.pending_classification.iter().any(|t| t.rest_id == "1")
            || app.source.tweets.iter().any(|t| t.rest_id == "1");
        assert!(
            treated_unclassified,
            "the row is re-classified under the new rubric, not silently hidden"
        );
    }

    /// A buffer written before the rubric marker existed has verdicts but no
    /// recorded hash. The TUI must fail closed (re-classify, never seed) and
    /// set the once-per-session latch behind the actionable warn.
    #[tokio::test]
    async fn unset_rubric_marker_sets_the_warn_latch_and_reclassifies() {
        let (mut app, _rx, tmp) = dummy_app();
        let mut store = FeedStore::open_writer(&tmp.path().join("feed.db"))
            .unwrap()
            .unwrap();
        store
            .upsert(FeedVariant::ForYou, &make_tweet("1", "x"))
            .unwrap();
        store
            .update_verdict(FeedVariant::ForYou, "1", FilterDecision::Hide)
            .unwrap();
        assert_eq!(store.rubric_hash(), None);
        app.feed_store = Some(store);
        app.filter_cache = Some(FilterCache::open(&tmp.path().join("fc.db"), "h".into()).unwrap());
        app.filter_classifier = Some(Classifier::new(&dummy_cfg()));
        app.filter_mode = FilterMode::On;
        app.source = Source::new(SourceKind::Home { following: false });
        assert!(!app.rubric_marker_warned);
        app.fetch_source(false, false);
        assert!(
            app.rubric_marker_warned,
            "the unset-marker warning latch fires on the first store read"
        );
        assert!(
            !app.filter_cache.as_ref().unwrap().contains("1"),
            "marker-less verdicts must not seed the live cache"
        );
    }

    #[tokio::test]
    async fn live_cursor_append_bypasses_the_store() {
        let (mut app, _rx, tmp) = dummy_app();
        let mut store = FeedStore::open_writer(&tmp.path().join("feed.db"))
            .unwrap()
            .unwrap();
        store
            .upsert(FeedVariant::ForYou, &make_tweet("1", "x"))
            .unwrap();
        app.feed_store = Some(store);
        app.filter_mode = FilterMode::Off;
        app.source = Source::new(SourceKind::Home { following: false });
        app.source.cursor = Some("DAABCgABGKkX-qzAJxEKAAIYqRACRRrQAAgAAwAAAAEAAA".into());
        app.fetch_source(true, false);
        assert!(
            app.source.loading,
            "a live X cursor keeps paginating the live path, not the store"
        );
    }

    #[tokio::test]
    async fn cursorless_append_bypasses_the_store() {
        let (mut app, _rx, tmp) = dummy_app();
        let mut store = FeedStore::open_writer(&tmp.path().join("feed.db"))
            .unwrap()
            .unwrap();
        store
            .upsert(FeedVariant::ForYou, &make_tweet("1", "x"))
            .unwrap();
        app.feed_store = Some(store);
        app.filter_mode = FilterMode::Off;
        app.source = Source::new(SourceKind::Home { following: false });
        app.source.cursor = None;
        app.fetch_source(true, false);
        assert!(
            app.source.loading,
            "an append without a cursor must not replay the buffer head as page 2"
        );
    }

    #[tokio::test]
    async fn cold_store_falls_back_to_live() {
        let (mut app, _rx, tmp) = dummy_app();
        let store = FeedStore::open_writer(&tmp.path().join("feed.db"))
            .unwrap()
            .unwrap();
        app.feed_store = Some(store);
        app.filter_mode = FilterMode::Off;
        app.source = Source::new(SourceKind::Home { following: false });
        app.fetch_source(false, false);
        assert!(
            app.source.loading,
            "an empty buffer falls through to the live fetch path"
        );
    }

    #[tokio::test]
    async fn store_pagination_appends_next_keyset_page() {
        let (mut app, _rx, tmp) = dummy_app();
        let mut store = FeedStore::open_writer(&tmp.path().join("feed.db"))
            .unwrap()
            .unwrap();
        for i in 0..60 {
            store
                .upsert(FeedVariant::Following, &at(&format!("{i:02}"), 1000 - i))
                .unwrap();
        }
        app.feed_store = Some(store);
        app.filter_mode = FilterMode::Off;
        app.source = Source::new(SourceKind::Home { following: true });
        app.fetch_source(false, false);
        let first = app.source.tweets.len();
        assert_eq!(first, 40, "first store page is one keyset window");
        assert!(app.source.cursor.is_some(), "a store cursor enables paging");
        app.fetch_source(true, false);
        assert_eq!(
            app.source.tweets.len(),
            60,
            "append pulled the rest of the buffer"
        );
    }
}

#[cfg(test)]
mod pending_state_tests {
    use super::*;
    use crate::tui::focus::NotificationsView;
    use crate::tui::source::Source;
    use crate::tui::test_util::{dummy_app, make_page, make_tweet};

    #[tokio::test]
    async fn thread_result_lands_on_buried_detail() {
        let (mut app, _rx, _tmp) = dummy_app();
        app.focus_stack
            .push(FocusEntry::Tweet(TweetDetail::new(make_tweet(
                "t1", "focal",
            ))));
        app.focus_stack
            .push(FocusEntry::Notifications(NotificationsView::new()));
        let mut reply = make_tweet("r1", "reply");
        reply.in_reply_to_tweet_id = Some("t1".into());
        app.handle_thread_loaded(
            "t1".into(),
            Ok(make_page(vec![make_tweet("t1", "focal"), reply])),
        );
        let FocusEntry::Tweet(detail) = &app.focus_stack[0] else {
            panic!("expected the buried tweet detail");
        };
        assert!(
            !detail.loading,
            "a detail under an overlay must not stay stuck on loading"
        );
        assert_eq!(detail.replies.len(), 1);
    }

    #[tokio::test]
    async fn thread_error_lands_on_buried_detail() {
        let (mut app, _rx, _tmp) = dummy_app();
        app.focus_stack
            .push(FocusEntry::Tweet(TweetDetail::new(make_tweet(
                "t1", "focal",
            ))));
        app.focus_stack
            .push(FocusEntry::Notifications(NotificationsView::new()));
        app.handle_thread_loaded(
            "t1".into(),
            Err(crate::error::Error::Config("network down".into())),
        );
        let FocusEntry::Tweet(detail) = &app.focus_stack[0] else {
            panic!("expected the buried tweet detail");
        };
        assert!(!detail.loading);
        assert!(detail.error.is_some());
    }

    #[tokio::test]
    async fn thread_result_for_popped_detail_is_discarded() {
        let (mut app, _rx, _tmp) = dummy_app();
        app.handle_thread_loaded("gone".into(), Ok(make_page(vec![make_tweet("r", "x")])));
        assert!(
            app.focus_stack.is_empty(),
            "nothing to apply, nothing pushed"
        );
    }

    #[tokio::test]
    async fn stale_notif_scroll_target_does_not_hijack_unrelated_thread() {
        let (mut app, _rx, _tmp) = dummy_app();
        app.pending_notif_scroll = Some("deleted-tweet".into());
        app.focus_stack
            .push(FocusEntry::Tweet(TweetDetail::new(make_tweet(
                "t1", "focal",
            ))));
        let root = make_tweet("root", "root");
        let mut focal = make_tweet("t1", "focal");
        focal.in_reply_to_tweet_id = Some("root".into());
        app.handle_thread_loaded("t1".into(), Ok(make_page(vec![root, focal])));
        let FocusEntry::Tweet(detail) = &app.focus_stack[0] else {
            panic!("expected the tweet detail");
        };
        assert_eq!(
            detail.tweet.rest_id, "t1",
            "a leaked scroll target must not re-root an unrelated thread into conversation view"
        );
    }

    #[tokio::test]
    async fn matching_notif_scroll_target_applies_conversation_view() {
        let (mut app, _rx, _tmp) = dummy_app();
        app.pending_notif_scroll = Some("t1".into());
        app.focus_stack
            .push(FocusEntry::Tweet(TweetDetail::new(make_tweet(
                "t1", "focal",
            ))));
        let root = make_tweet("root", "root");
        let mut focal = make_tweet("t1", "focal");
        focal.in_reply_to_tweet_id = Some("root".into());
        app.handle_thread_loaded("t1".into(), Ok(make_page(vec![root, focal])));
        assert!(app.pending_notif_scroll.is_none(), "target consumed");
        let FocusEntry::Tweet(detail) = &app.focus_stack[0] else {
            panic!("expected the tweet detail");
        };
        assert_eq!(
            detail.tweet.rest_id, "root",
            "the notification jump re-roots to the conversation root"
        );
    }

    #[tokio::test]
    async fn failed_notification_open_clears_scroll_target() {
        let (mut app, _rx, _tmp) = dummy_app();
        app.pending_open = Some(7);
        app.pending_notif_scroll = Some("t9".into());
        app.handle_open_tweet_resolved(7, Err(crate::error::Error::Config("deleted".into())));
        assert!(app.pending_open.is_none());
        assert!(
            app.pending_notif_scroll.is_none(),
            "a failed open must not leak its scroll target into the next thread load"
        );
        assert!(app.error.is_some());
    }

    #[tokio::test]
    async fn stale_user_timeline_result_is_ignored() {
        let (mut app, _rx, _tmp) = dummy_app();
        app.pending_user_detail = Some(3);
        app.handle_user_timeline_loaded(2, Ok(make_page(vec![make_tweet("u1", "x")])));
        assert!(
            app.focus_stack.is_empty(),
            "a superseded or abandoned profile fetch must not push a pane"
        );
        app.handle_user_timeline_loaded(3, Ok(make_page(vec![make_tweet("u1", "x")])));
        assert_eq!(app.focus_stack.len(), 1, "the live request still lands");
        assert!(app.pending_user_detail.is_none());
    }

    #[tokio::test]
    async fn replace_source_abandons_pending_navigation() {
        let (mut app, _rx, _tmp) = dummy_app();
        app.pending_open = Some(1);
        app.pending_user_detail = Some(2);
        app.pending_notif_scroll = Some("t".into());
        app.fetch_baseline = Some(100);
        app.replace_source(SourceKind::User {
            handle: "foo".into(),
        });
        assert!(app.pending_open.is_none());
        assert!(app.pending_user_detail.is_none());
        assert!(app.pending_notif_scroll.is_none());
        assert_eq!(
            app.fetch_baseline,
            Some(0),
            "the new source starts from a fresh baseline, not the previous feed's"
        );
        app.handle_open_tweet_resolved(1, Ok(make_tweet("t", "x")));
        assert!(
            app.focus_stack.is_empty(),
            "an open resolved after the switch must not steal the new source's pane"
        );
    }

    #[tokio::test]
    async fn back_out_abandons_pending_navigation() {
        let (mut app, _rx, _tmp) = dummy_app();
        app.focus_stack
            .push(FocusEntry::Notifications(NotificationsView::new()));
        app.pending_open = Some(5);
        app.pending_user_detail = Some(6);
        app.pending_notif_scroll = Some("t".into());
        app.back_out(false);
        assert!(app.pending_open.is_none());
        assert!(app.pending_user_detail.is_none());
        assert!(app.pending_notif_scroll.is_none());
        app.handle_open_tweet_resolved(5, Ok(make_tweet("t", "x")));
        assert!(
            app.focus_stack.is_empty(),
            "an open resolved after Esc must not push a pane"
        );
    }

    #[tokio::test]
    async fn failed_fetch_clears_fetch_baseline() {
        let (mut app, _rx, _tmp) = dummy_app();
        let kind = SourceKind::Home { following: true };
        app.source = Source::new(kind.clone());
        app.fetch_baseline = Some(40);
        app.handle_timeline_loaded(
            kind.clone(),
            Err(crate::error::Error::Config("net".into())),
            true,
            false,
        );
        assert!(
            app.fetch_baseline.is_none(),
            "a failed append must not leave a baseline driving phantom pagination"
        );
        app.fetch_baseline = Some(40);
        app.handle_timeline_loaded(
            kind,
            Err(crate::error::Error::Config("net".into())),
            false,
            true,
        );
        assert!(
            app.fetch_baseline.is_none(),
            "a failed silent refresh clears the baseline too"
        );
    }
}
