use super::app::*;
use crate::error::Result;
use crate::model::Tweet;
use crate::parse::timeline::TimelinePage;
use crate::tui::event::{self, Event, EventTx};
use crate::tui::filter::{FilterCache, FilterDecision, FilterMode};
use crate::tui::focus::{self, FocusEntry, TweetDetail};
use crate::tui::seen::SeenStore;
use crate::tui::source::{self, SourceKind};
use crate::tui::whisper::{self, NotifEntry, WhisperEntry};
use std::collections::{HashMap, HashSet};
use std::time::Instant;

impl App {
    pub fn load_initial(&mut self) {
        self.spawn_self_handle_resolve();
        if self.source.is_notifications() {
            self.fetch_notifications_source(false, false);
        } else {
            self.fetch_source(false, false);
        }
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
        self.source.loading = false;
        self.source.silent_refreshing = false;
        self.source.cursor = None;
        self.source.exhausted = false;
        self.source.set_selected(0);
        if self.source.is_notifications() {
            self.fetch_notifications_source(false, false);
        } else {
            self.fetch_source(false, false);
        }
    }

    pub(super) fn fetch_source(&mut self, append: bool, silent: bool) {
        let Some(kind) = self.source.kind.clone() else {
            return;
        };
        if self.source.loading || self.source.silent_refreshing {
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
        tokio::spawn(async move {
            let mut result = source::fetch_page(&client, &kind, cursor.clone()).await;
            if result.is_err() && !append {
                tracing::info!("transient fetch error, retrying in 2s");
                tokio::time::sleep(tokio::time::Duration::from_secs(2)).await;
                result = source::fetch_page(&client, &kind, cursor).await;
            }
            let _ = tx.send(Event::TimelineLoaded {
                kind,
                result,
                append,
                silent,
            });
        });
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
                let total_incoming = page.tweets.len();
                let hidden = filter_incoming_page(
                    &mut page,
                    &kind,
                    self.feed_mode,
                    self.filter_mode,
                    self.filter_classifier.is_some(),
                    self.filter_cache.as_ref(),
                    &self.seen,
                );
                self.filter_hidden_count += hidden;
                if matches!(kind, SourceKind::Home { following: true }) {
                    page.tweets.sort_by(|a, b| b.created_at.cmp(&a.created_at));
                }
                let filter_active =
                    matches!(self.filter_mode, FilterMode::On) && self.filter_classifier.is_some();
                let held: Vec<Tweet> = if !filter_active {
                    Vec::new()
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
                self.pending_classification.extend(held.iter().cloned());
                if total_incoming > 0 && self.source.cursor.is_some() {
                    self.source.exhausted = false;
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
                self.queue_source_media(&new_tweets);
                self.queue_filter_classification(new_tweets);
                if silent {
                    self.fetch_baseline = None;
                    self.clear_status();
                }
                self.drain_pending_classification();
            }
            Err(e) => {
                if silent {
                    tracing::warn!("silent timeline refresh failed: {e}");
                } else {
                    self.error = Some(e.to_string());
                    self.clear_status();
                }
            }
        }
    }

    pub(super) fn fetch_notifications_source(&mut self, append: bool, silent: bool) {
        if self.source.loading || self.source.silent_refreshing {
            tracing::debug!("notification fetch skipped: already loading");
            return;
        }
        tracing::info!(append, silent, "notification fetch started");
        if silent {
            self.source.silent_refreshing = true;
        } else {
            self.source.loading = true;
        }
        let client = self.client.clone();
        let tx = self.tx.clone();
        let cursor = if append {
            self.source.cursor.clone()
        } else {
            None
        };
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
            let _ = tx.send(Event::NotificationPageLoaded {
                result,
                append,
                silent,
            });
        });
    }

    pub(super) fn handle_notification_page_loaded(
        &mut self,
        result: Result<crate::parse::notification::NotificationPage>,
        append: bool,
        silent: bool,
    ) {
        if !self.source.is_notifications() {
            tracing::debug!("notification page arrived but source changed, discarding");
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
            Ok(page) => {
                tracing::info!(
                    count = page.notifications.len(),
                    has_cursor = page.next_cursor.is_some(),
                    append,
                    silent,
                    "notification page loaded"
                );
                for n in &page.notifications {
                    if n.target_tweet_favorited {
                        if let Some(tid) = &n.target_tweet_id {
                            self.liked_tweet_ids.insert(tid.clone());
                        }
                    }
                }
                if append {
                    self.source.append_notifications(page);
                } else {
                    self.source.reset_with_notifications(page);
                }
                self.error = None;
                if !silent {
                    self.clear_status();
                }
            }
            Err(ref e) => {
                if silent {
                    tracing::warn!("silent notification refresh failed: {e}");
                } else {
                    tracing::warn!("notification fetch failed: {e}");
                    self.error = Some(e.to_string());
                    self.clear_status();
                }
            }
        }
    }

    pub(super) fn fetch_thread(&mut self, focal_id: String) {
        let request_id = event::next_request_id();
        self.pending_thread = Some(request_id);
        let client = self.client.clone();
        let tx = self.tx.clone();
        tokio::spawn(async move {
            let result = focus::fetch_thread(&client, &focal_id).await;
            let _ = tx.send(Event::ThreadLoaded {
                request_id,
                focal_id,
                result,
            });
        });
    }

    pub(super) fn handle_thread_loaded(
        &mut self,
        request_id: event::RequestId,
        focal_id: String,
        result: Result<TimelinePage>,
    ) {
        if self.pending_thread != Some(request_id) {
            return;
        }
        self.pending_thread = None;
        let Some(FocusEntry::Tweet(detail)) = self.focus_stack.last_mut() else {
            return;
        };
        if detail.tweet.rest_id != focal_id {
            return;
        }
        let scroll_target = self.pending_notif_scroll.take();
        let reply_sort = self.reply_sort;
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
            Err(e) => self.error = Some(e.to_string()),
        }
    }

    pub(super) fn open_user_in_detail(&mut self, handle: String, user_id: Option<String>) {
        self.set_status(format!("loading @{handle}…"));
        let client = self.client.clone();
        let tx = self.tx.clone();
        tokio::spawn(async move {
            let result = match user_id {
                Some(id) => crate::tui::source::fetch_user_tweets_by_id(&client, &id, None).await,
                None => {
                    crate::tui::source::fetch_page(&client, &SourceKind::User { handle }, None)
                        .await
                }
            };
            let _ = tx.send(Event::UserTimelineLoaded { result });
        });
    }

    pub(super) fn handle_user_timeline_loaded(&mut self, result: Result<TimelinePage>) {
        match result {
            Ok(page) => {
                let mut tweets = page.tweets.into_iter();
                let Some(focal) = tweets.next() else {
                    self.set_status("no tweets from this user");
                    return;
                };
                self.media.ensure_tweet_media(&focal, &self.tx);
                let mut detail = TweetDetail::new(focal);
                detail.loading = false;
                detail.replies = tweets.collect();
                for t in &detail.replies {
                    self.media.ensure_tweet_media(t, &self.tx);
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
        let Some(notif) = self
            .source
            .notifications
            .get(self.source.selected())
            .cloned()
        else {
            return;
        };
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
                let idx = self.notif_actor_cursor.unwrap_or(0);
                if let Some(actor) = notif.actors.get(idx) {
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
        let tweet = match self.active {
            ActivePane::Source => {
                if self.source.is_notifications() {
                    self.set_status("L works on tweets, not notifications");
                    return;
                }
                self.source.tweets.get(self.source.selected()).cloned()
            }
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
        match result {
            Ok(page) => {
                if append {
                    let existing: std::collections::HashSet<String> =
                        view.users.iter().map(|u| u.rest_id.clone()).collect();
                    for u in page.users {
                        if !existing.contains(&u.rest_id) {
                            view.users.push(u);
                        }
                    }
                } else {
                    view.users = page.users;
                }
                view.cursor = page.next_cursor;
                view.exhausted = view.cursor.is_none();
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
    }

    pub(super) fn queue_source_media(&mut self, tweets: &[Tweet]) {
        if !self.media.supported() || !self.media_auto_expand {
            return;
        }
        for t in tweets {
            self.media.ensure_tweet_media(t, &self.tx);
        }
    }

    pub(super) fn queue_thread_media(&mut self, replies: &[Tweet]) {
        if !self.media.supported() {
            return;
        }
        for t in replies {
            self.media.ensure_tweet_media(t, &self.tx);
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
    conversation.sort_by(|a, b| a.created_at.cmp(&b.created_at));

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

pub fn filter_incoming_page(
    page: &mut TimelinePage,
    kind: &SourceKind,
    feed_mode: FeedMode,
    filter_mode: FilterMode,
    has_classifier: bool,
    filter_cache: Option<&FilterCache>,
    seen: &SeenStore,
) -> usize {
    if matches!(kind, SourceKind::Home { following: false }) {
        let unseen: Vec<_> = page
            .tweets
            .iter()
            .filter(|t| !seen.is_seen(&t.rest_id))
            .cloned()
            .collect();
        if !unseen.is_empty() {
            page.tweets = unseen;
        }
    }
    if matches!(feed_mode, FeedMode::Originals) && matches!(kind, SourceKind::Home { .. }) {
        page.tweets.retain(|t| {
            t.in_reply_to_tweet_id.is_none()
                && t.quoted_tweet.is_none()
                && !t.text.starts_with("RT @")
        });
    }
    let mut hidden = 0;
    if matches!(filter_mode, FilterMode::On) && has_classifier {
        if let Some(cache) = filter_cache {
            let before = page.tweets.len();
            page.tweets
                .retain(|t| !matches!(cache.get(&t.rest_id), Some(FilterDecision::Hide)));
            hidden = before - page.tweets.len();
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
