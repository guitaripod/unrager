use super::app::{ActivePane, App, FeedMode};
use crate::config;
use crate::model::Tweet;
use crate::tui::ask;
use crate::tui::engage::EngageAction;
use crate::tui::event::Event;
use crate::tui::external;
use crate::tui::focus::{FocusEntry, TweetDetail};
use crate::tui::source::{self, SourceKind};
use crate::tui::ui;

impl App {
    pub(super) fn switch_source(&mut self, kind: SourceKind) {
        if self.source.kind.as_ref() == Some(&kind) {
            return;
        }
        while self.history.len() > self.history_cursor + 1 {
            self.history.pop();
        }
        self.history.push(kind.clone());
        self.history_cursor = self.history.len() - 1;
        self.replace_source(kind);
    }

    pub(super) fn replace_source(&mut self, kind: SourceKind) {
        self.source = source::Source::new(kind);
        self.error = None;
        self.focus_stack.clear();
        self.active = ActivePane::Source;
        self.expanded_bodies.clear();
        self.inline_threads.clear();
        self.filter_verdicts.clear();
        self.filter_inflight.clear();
        self.filter_hidden_count = 0;
        self.pending_classification.clear();
        self.translations.clear();
        self.translation_inflight.clear();
        self.engage_inflight.clear();
        self.fetch_source(false, false);
        self.save_session();
    }

    pub(super) fn history_back(&mut self) {
        if self.history_cursor == 0 {
            return;
        }
        self.history_cursor -= 1;
        if let Some(kind) = self.history.get(self.history_cursor).cloned() {
            self.replace_source(kind);
        }
    }

    pub(super) fn history_forward(&mut self) {
        if self.history_cursor + 1 >= self.history.len() {
            return;
        }
        self.history_cursor += 1;
        if let Some(kind) = self.history.get(self.history_cursor).cloned() {
            self.replace_source(kind);
        }
    }

    pub(super) fn back_out(&mut self, can_quit: bool) {
        if let Some(popped) = self.focus_stack.pop() {
            if matches!(popped, FocusEntry::Ask(_) | FocusEntry::Brief(_))
                && let Some(ollama) = self.filter_cfg.as_ref().map(|c| c.ollama.clone())
            {
                ask::unload(ollama);
            }
            self.pending_thread = None;
            if self.focus_stack.is_empty() {
                self.active = ActivePane::Source;
            }
            return;
        }
        let on_home_following =
            matches!(self.source.kind, Some(SourceKind::Home { following: true }));
        if on_home_following {
            if can_quit {
                self.running = false;
            }
            return;
        }
        if self.history_cursor > 0 {
            self.history_back();
        } else {
            self.switch_source(SourceKind::Home { following: true });
        }
    }

    pub(super) fn push_tweet(&mut self, tweet: Tweet) {
        if tweet.favorited {
            self.liked_tweet_ids.insert(tweet.rest_id.clone());
        }
        let focal_id = tweet.rest_id.clone();
        self.media.ensure_tweet_media(&tweet, &self.tx);
        let detail = TweetDetail::new(tweet);
        self.focus_stack.push(FocusEntry::Tweet(detail));
        self.active = ActivePane::Detail;
        self.fetch_thread(focal_id);
    }

    pub(super) fn selected_tweet(&self) -> Option<&Tweet> {
        match self.active {
            ActivePane::Source => self.source.tweets.get(self.source.selected()),
            ActivePane::Detail => {
                let detail = self.top_detail()?;
                detail.selected_reply().or(Some(&detail.tweet))
            }
        }
    }

    pub(super) fn mark_current_seen(&mut self) {
        if let Some(t) = self.source.tweets.get(self.source.selected()) {
            self.seen.mark_seen(&t.rest_id);
        }
    }

    pub(super) fn mark_current_notif_seen(&mut self) {
        let Some(FocusEntry::Notifications(view)) = self.focus_stack.last() else {
            return;
        };
        if let Some(n) = view.notifications.get(view.selected()) {
            self.notif_seen.mark_seen(&n.id);
        }
    }

    pub(super) fn jump_next_unread(&mut self) {
        if self.active == ActivePane::Detail
            && matches!(self.focus_stack.last(), Some(FocusEntry::Notifications(_)))
        {
            self.jump_next_unread_notif();
            return;
        }
        let start = self.source.selected() + 1;
        for i in start..self.source.tweets.len() {
            if !self.seen.is_seen(&self.source.tweets[i].rest_id) {
                self.source.set_selected(i);
                self.mark_current_seen();
                self.maybe_load_more();
                return;
            }
        }
        self.set_status("no more unread tweets in this source");
    }

    fn jump_next_unread_notif(&mut self) {
        let Some(FocusEntry::Notifications(view)) = self.focus_stack.last_mut() else {
            return;
        };
        let start = view.selected() + 1;
        let mut hit = None;
        for i in start..view.notifications.len() {
            if !self.notif_seen.is_seen(&view.notifications[i].id) {
                hit = Some(i);
                break;
            }
        }
        match hit {
            Some(i) => {
                view.set_selected(i);
                self.mark_current_notif_seen();
                self.maybe_load_more_notifications();
            }
            None => self.set_status("no more unread notifications"),
        }
    }

    pub(super) fn mark_all_seen_in_source(&mut self) {
        if self.active == ActivePane::Detail
            && let Some(FocusEntry::Notifications(view)) = self.focus_stack.last()
        {
            let ids: Vec<String> = view.notifications.iter().map(|n| n.id.clone()).collect();
            let n = ids.len();
            self.notif_seen.mark_all(ids);
            self.set_status(format!("marked {n} notifications as read"));
            return;
        }
        let ids: Vec<String> = self
            .source
            .tweets
            .iter()
            .map(|t| t.rest_id.clone())
            .collect();
        let n = ids.len();
        self.seen.mark_all(ids);
        self.set_status(format!("marked {n} tweets as read"));
    }

    pub(super) fn maybe_load_more(&mut self) {
        if self.source.loading || self.source.exhausted || self.source.cursor.is_none() {
            return;
        }
        if self.source.near_bottom() {
            self.fetch_source(true, false);
        }
    }

    pub(super) fn maybe_load_more_notifications(&mut self) {
        let Some(FocusEntry::Notifications(view)) = self.focus_stack.last() else {
            return;
        };
        if view.loading || view.exhausted || view.cursor.is_none() || !view.near_bottom() {
            return;
        }
        self.fetch_notifications_view(true, false);
    }

    pub(super) fn maybe_load_more_likers(&mut self) {
        let Some(FocusEntry::Likers(view)) = self.focus_stack.last() else {
            return;
        };
        if view.loading || view.exhausted || view.cursor.is_none() || !view.near_bottom() {
            return;
        }
        let tweet_id = view.tweet_id.clone();
        let cursor = view.cursor.clone();
        if let Some(FocusEntry::Likers(v)) = self.focus_stack.last_mut() {
            v.loading = true;
        }
        self.fetch_likers_page(tweet_id, cursor, true);
    }

    pub(super) fn engage(&mut self, action: EngageAction) {
        if self.block_if_write_limited() {
            return;
        }
        let (rest_id, was_engaged) = if let Some(tweet) = self.selected_tweet() {
            (tweet.rest_id.clone(), action.is_engaged(tweet))
        } else if let Some(tid) = self.selected_notification_tweet_id() {
            let engaged = self.liked_tweet_ids.contains(&tid);
            (tid, engaged)
        } else {
            return;
        };
        if self.engage_inflight.contains(&rest_id) {
            return;
        }

        self.engage_inflight.insert(rest_id.clone());
        self.mutate_tweet_by_id(&rest_id, |t| action.apply(t));
        if !was_engaged {
            self.liked_tweet_ids.insert(rest_id.clone());
        } else {
            self.liked_tweet_ids.remove(&rest_id);
        }
        self.set_status(action.verb(was_engaged));

        crate::tui::engage::dispatch(
            action,
            rest_id,
            was_engaged,
            self.client.clone(),
            self.tx.clone(),
        );
    }

    pub(super) fn handle_engage_result(
        &mut self,
        rest_id: String,
        action: EngageAction,
        error: Option<String>,
    ) {
        self.engage_inflight.remove(&rest_id);
        if let Some(err) = error {
            self.mutate_tweet_by_id(&rest_id, |t| action.apply(t));
            if self.liked_tweet_ids.contains(&rest_id) {
                self.liked_tweet_ids.remove(&rest_id);
            } else {
                self.liked_tweet_ids.insert(rest_id);
            }
            self.error = Some(err);
        }
    }

    pub(super) fn mutate_tweet_by_id(&mut self, rest_id: &str, f: impl Fn(&mut Tweet)) {
        for tweet in &mut self.source.tweets {
            if tweet.rest_id == rest_id {
                f(tweet);
            }
        }
        for entry in &mut self.focus_stack {
            if let FocusEntry::Tweet(detail) = entry {
                if detail.tweet.rest_id == rest_id {
                    f(&mut detail.tweet);
                }
                for reply in &mut detail.replies {
                    if reply.rest_id == rest_id {
                        f(reply);
                    }
                }
            }
        }
        for inline in self.inline_threads.values_mut() {
            for (_, tweet) in &mut inline.replies {
                if tweet.rest_id == rest_id {
                    f(tweet);
                }
            }
        }
    }

    pub(super) fn track_liked_tweets(&mut self, tweets: &[Tweet]) {
        for t in tweets {
            if t.favorited {
                self.liked_tweet_ids.insert(t.rest_id.clone());
            }
        }
    }

    pub(super) fn selected_notification_tweet_id(&self) -> Option<String> {
        if self.active != ActivePane::Detail {
            return None;
        }
        let FocusEntry::Notifications(view) = self.focus_stack.last()? else {
            return None;
        };
        view.notifications
            .get(view.selected())
            .and_then(|n| n.target_tweet_id.clone())
    }

    pub(super) fn remove_tweet_by_id(&mut self, rest_id: &str) {
        let Some(idx) = self.source.tweets.iter().position(|t| t.rest_id == rest_id) else {
            return;
        };
        self.source.tweets.remove(idx);
        if self.source.tweets.is_empty() {
            self.source.state = crate::tui::source::PaneState::default();
            return;
        }
        let sel = self.source.state.selected;
        let new_sel = if idx < sel {
            sel - 1
        } else {
            sel.min(self.source.tweets.len() - 1)
        };
        self.source.set_selected(new_sel);
    }

    pub(super) fn open_profile(&mut self) {
        if let Some(handle) = self.selected_author_handle() {
            self.switch_source(SourceKind::User { handle });
            return;
        }
        if let Some(handle) = self.self_handle.clone() {
            self.switch_source(SourceKind::User { handle });
            return;
        }
        self.set_status("resolving handle…");
        let client = self.client.clone();
        let tx = self.tx.clone();
        tokio::spawn(async move {
            match source::fetch_self_handle(&client).await {
                Ok(handle) => {
                    let _ = tx.send(Event::SelfHandleResolved { handle });
                }
                Err(e) => {
                    tracing::warn!("failed to resolve self handle: {e}");
                }
            }
        });
    }

    fn selected_author_handle(&self) -> Option<String> {
        if self.active == ActivePane::Detail
            && let Some(FocusEntry::Notifications(view)) = self.focus_stack.last()
        {
            let n = view.notifications.get(view.selected())?;
            let idx = view.actor_cursor.unwrap_or(0);
            return n.actors.get(idx).map(|a| a.handle.clone());
        }
        self.selected_tweet().map(|t| t.author.handle.clone())
    }

    pub(super) fn open_tweet_in_browser(&mut self) {
        let Some(tweet) = self.selected_tweet() else {
            return;
        };
        self.open_url(&tweet.url.clone());
    }

    pub(super) fn open_own_profile_in_browser(&mut self) {
        let Some(handle) = &self.self_handle else {
            self.set_status("own handle not resolved yet");
            return;
        };
        let url = format!("https://x.com/{handle}");
        self.open_url(&url);
    }

    pub(super) fn open_author_in_browser(&mut self) {
        let Some(tweet) = self.selected_tweet() else {
            return;
        };
        let url = format!("https://x.com/{}", tweet.author.handle);
        self.open_url(&url);
    }

    pub(super) fn open_media_external(&mut self) {
        let Some(tweet) = self.selected_tweet() else {
            return;
        };
        if tweet.media.is_empty() {
            self.set_status("no media on selected tweet");
            return;
        }
        let cache_dir = match config::cache_dir() {
            Ok(p) => p.join("media"),
            Err(e) => {
                self.error = Some(format!("cache dir: {e}"));
                return;
            }
        };
        let tweet_dir = cache_dir.join(&tweet.rest_id);
        let targets = external::collect_open_targets(tweet, &tweet_dir);
        let count = targets.len();
        let tweet_id = tweet.rest_id.clone();
        let label = if count > 1 {
            format!("opening {count} files…")
        } else {
            "opening media…".to_string()
        };
        tracing::info!(
            %tweet_id,
            count,
            "open_media_external: dispatching download + native viewer",
        );
        self.set_status(label);
        let tx = self.tx.clone();
        tokio::spawn(async move {
            let result = external::download_and_open(targets).await;
            if let Err(e) = &result {
                tracing::warn!(error = %e, "open_media_external failed");
            }
            let _ = tx.send(Event::MediaOpenResult { result });
        });
    }

    pub(super) fn handle_media_open_result(
        &mut self,
        result: std::result::Result<Vec<std::path::PathBuf>, String>,
    ) {
        match result {
            Ok(paths) if paths.len() == 1 => {
                self.set_status(format!("opened {}", paths[0].display()));
            }
            Ok(paths) => {
                if let Some(dir) = paths.first().and_then(|p| p.parent()) {
                    self.set_status(format!("opened {} · {}", paths[0].display(), dir.display()));
                } else {
                    self.set_status(format!("opened {} files", paths.len()));
                }
            }
            Err(e) => self.error = Some(e),
        }
    }

    pub(super) fn open_url(&mut self, url: &str) {
        let (program, args) = self.app_config.browser_parts();
        let mut cmd = std::process::Command::new(program);
        if self.app_config.has_url_placeholder() {
            cmd.args(args.iter().map(|a| a.replace("{}", url)));
        } else {
            cmd.args(args).arg(url);
        }
        match cmd
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
        {
            Ok(_) => self.set_status(format!("opened {url}")),
            Err(e) => self.error = Some(format!("{program} failed: {e}")),
        }
    }

    pub(super) fn yank_url(&mut self) {
        let Some(tweet) = self.selected_tweet() else {
            return;
        };
        let text = tweet
            .url
            .replace("x.com/", "fixupx.com/")
            .replace("twitter.com/", "fixuptwitter.com/");
        self.copy_to_clipboard(text, "url copied");
    }

    pub(super) fn yank_json(&mut self) {
        let Some(tweet) = self.selected_tweet() else {
            return;
        };
        match serde_json::to_string_pretty(tweet) {
            Ok(json) => self.copy_to_clipboard(json, "json copied"),
            Err(e) => self.error = Some(format!("serialize failed: {e}")),
        }
    }

    pub(super) fn copy_to_clipboard(&mut self, text: String, note: &str) {
        use std::io::Write;
        use std::process::{Command, Stdio};
        let result = Command::new("wl-copy")
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .or_else(|_| {
                Command::new("xclip")
                    .args(["-selection", "clipboard"])
                    .stdin(Stdio::piped())
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .spawn()
            });
        match result {
            Ok(mut child) => {
                if let Some(mut stdin) = child.stdin.take() {
                    let _ = stdin.write_all(text.as_bytes());
                }
                self.set_status(note.to_string());
            }
            Err(e) => self.error = Some(format!("clipboard failed: {e}")),
        }
    }

    pub(super) fn toggle_feed_mode(&mut self) {
        if !matches!(self.source.kind, Some(SourceKind::Home { .. })) {
            self.set_status("V only toggles on home feed");
            return;
        }
        self.feed_mode = match self.feed_mode {
            FeedMode::All => FeedMode::Originals,
            FeedMode::Originals => FeedMode::All,
        };
        let msg = match self.feed_mode {
            FeedMode::All => "feed: all tweets",
            FeedMode::Originals => "feed: originals only",
        };
        self.set_status(msg);
        self.save_session();
        self.reload_source();
    }

    pub(super) fn toggle_home_mode(&mut self) {
        let current_following =
            matches!(self.source.kind, Some(SourceKind::Home { following: true }));
        let current_is_home = matches!(self.source.kind, Some(SourceKind::Home { .. }));
        if !current_is_home {
            self.set_status("F only toggles on home source; use :user etc for others");
            return;
        }
        self.switch_source(SourceKind::Home {
            following: !current_following,
        });
    }

    pub(super) fn toggle_user_replies(&mut self) {
        match &self.source.kind {
            Some(SourceKind::User { handle, .. }) => {
                let query = format!("from:{handle} filter:replies");
                self.switch_source(SourceKind::Search {
                    query,
                    product: source::SearchProduct::Latest,
                });
            }
            Some(SourceKind::Search { query, .. }) if query.contains("filter:replies") => {
                let handle = query
                    .strip_prefix("from:")
                    .and_then(|s| s.split_whitespace().next())
                    .unwrap_or("")
                    .to_string();
                if !handle.is_empty() {
                    self.switch_source(SourceKind::User { handle });
                }
            }
            _ => {
                self.set_status("R only toggles on a user profile");
            }
        }
    }

    pub(super) fn start_reply(&mut self) {
        if self.active == ActivePane::Source {
            let Some(tweet) = self.source.tweets.get(self.source.selected()).cloned() else {
                return;
            };
            self.mark_current_seen();
            self.push_tweet(tweet);
        }
        let Some(FocusEntry::Tweet(detail)) = self.focus_stack.last_mut() else {
            return;
        };
        if detail.reply_bar.is_some() {
            return;
        }
        detail.reply_bar = Some(crate::tui::compose::ReplyBar::new());
        self.active = ActivePane::Detail;
        if let Some(remaining) = self.write_rate_limit_remaining() {
            self.set_status(format!(
                "X cooldown · wait {} before sending",
                ui::format_countdown(remaining)
            ));
        } else {
            self.set_status("reply: type, Enter send, Esc close");
        }
    }

    pub(super) fn submit_reply(&mut self) {
        let (text, in_reply_to) = {
            let Some(FocusEntry::Tweet(detail)) = self.focus_stack.last() else {
                return;
            };
            let Some(bar) = &detail.reply_bar else {
                return;
            };
            if bar.sending || bar.editor.input.trim().is_empty() {
                return;
            }
            (
                bar.editor.input.trim().to_string(),
                detail.tweet.rest_id.clone(),
            )
        };
        if self.block_if_write_limited() {
            return;
        }
        if let Some(FocusEntry::Tweet(detail)) = self.focus_stack.last_mut() {
            if let Some(bar) = &mut detail.reply_bar {
                bar.sending = true;
                bar.error = None;
            }
        }
        self.error = None;
        self.set_status("sending reply…");
        crate::tui::compose::dispatch_reply(
            text,
            in_reply_to,
            self.client.clone(),
            self.tx.clone(),
        );
    }

    pub(super) fn handle_reply_result(
        &mut self,
        in_reply_to: String,
        result: std::result::Result<String, String>,
    ) {
        let is_match = matches!(
            self.focus_stack.last(),
            Some(FocusEntry::Tweet(d)) if d.tweet.rest_id == in_reply_to && d.reply_bar.is_some()
        );
        if !is_match {
            return;
        }
        match result {
            Ok(new_id) => {
                self.error = None;
                self.set_status(format!("reply sent · {new_id}"));
                if let Some(FocusEntry::Tweet(detail)) = self.focus_stack.last_mut() {
                    detail.reply_bar = None;
                }
                self.fetch_thread(in_reply_to);
            }
            Err(err) => {
                let friendly = crate::tui::compose::friendly_error(&err);
                if let Some(FocusEntry::Tweet(detail)) = self.focus_stack.last_mut() {
                    if let Some(bar) = &mut detail.reply_bar {
                        bar.sending = false;
                        bar.error = Some(friendly.clone());
                    }
                }
                self.error = Some(friendly);
            }
        }
    }

    pub(super) fn cycle_reply_sort(&mut self) {
        self.reply_sort = self.reply_sort.cycle();
        if let Some(FocusEntry::Tweet(detail)) = self.focus_stack.last_mut() {
            detail.sort_replies(self.reply_sort);
        }
        self.set_status(format!("replies sorted by {}", self.reply_sort.label()));
        self.save_session();
    }
}
