use super::app::App;
use crate::model::Tweet;
use crate::tui::ask::{self, AskView};
use crate::tui::brief::{self, BriefView};
use crate::tui::event::Event;
use crate::tui::filter::{
    self, Classifier, FilterCache, FilterConfig, FilterDecision, FilterMode, FilterState,
    TweetPayload,
};
use crate::tui::focus::{self, FocusEntry};
use crate::tui::source::SourceKind;
use std::path::Path;

pub(crate) fn init_filter_stack(
    config_dir: &Path,
    cache_dir: &Path,
) -> (
    Option<FilterConfig>,
    Option<FilterCache>,
    Option<Classifier>,
) {
    let cfg = match FilterConfig::load_or_init(&config_dir.join("filter.toml")) {
        Ok(c) => c,
        Err(e) => {
            tracing::warn!("filter config failed to load: {e} — filter disabled");
            return (None, None, None);
        }
    };
    let cache = match FilterCache::open(&cache_dir.join("filter.db"), cfg.rubric_hash()) {
        Ok(c) => c,
        Err(e) => {
            tracing::warn!("filter cache failed to open: {e} — filter disabled");
            return (None, None, None);
        }
    };
    let classifier = Classifier::new(&cfg);
    (Some(cfg), Some(cache), Some(classifier))
}

impl App {
    pub fn toggle_filter(&mut self) {
        if self.filter_classifier.is_none() {
            self.filter_mode = FilterMode::Off;
            self.set_status("filter unavailable (ollama down)");
            return;
        }
        self.filter_mode = match self.filter_mode {
            FilterMode::On => FilterMode::Off,
            FilterMode::Off => FilterMode::On,
        };
        if matches!(self.filter_mode, FilterMode::Off) {
            let drained: Vec<Tweet> = self.pending_classification.drain(..).collect();
            for t in drained {
                if !self.source.tweets.iter().any(|x| x.rest_id == t.rest_id) {
                    self.source.tweets.push(t);
                }
            }
        }
        let msg = match self.filter_mode {
            FilterMode::On => "filter: on",
            FilterMode::Off => "filter: off",
        };
        self.set_status(msg);
    }

    pub(super) fn queue_filter_classification(&mut self, tweets: Vec<Tweet>) {
        if !matches!(self.filter_mode, FilterMode::On) {
            return;
        }
        let (Some(cache), Some(classifier)) =
            (self.filter_cache.as_mut(), self.filter_classifier.as_ref())
        else {
            return;
        };
        for t in &tweets {
            if self.filter_verdicts.contains_key(&t.rest_id) {
                continue;
            }
            if let Some(decision) = cache.get(&t.rest_id) {
                self.filter_verdicts
                    .insert(t.rest_id.clone(), FilterState::Classified(decision));
                continue;
            }
            if !self.filter_inflight.insert(t.rest_id.clone()) {
                continue;
            }
            self.filter_verdicts
                .insert(t.rest_id.clone(), FilterState::Unclassified);
            let payload = TweetPayload {
                rest_id: t.rest_id.clone(),
                text: filter::build_classification_text(t),
            };
            classifier.classify_async(payload, self.tx.clone());
        }
    }

    pub(super) fn handle_tweet_classified(&mut self, rest_id: String, verdict: FilterDecision) {
        self.filter_inflight.remove(&rest_id);
        if let Some(cache) = self.filter_cache.as_mut() {
            cache.put(&rest_id, verdict);
        }
        self.filter_verdicts
            .insert(rest_id.clone(), FilterState::Classified(verdict));
        if matches!(verdict, FilterDecision::Hide) {
            if self.filter_counted_ids.insert(rest_id.clone()) {
                self.filter_hidden_count += 1;
            }
            let in_pending = self
                .pending_classification
                .iter()
                .any(|t| t.rest_id == rest_id);
            if !in_pending {
                self.remove_tweet_by_id(&rest_id);
            }
        }
        self.drain_pending_classification();
    }

    pub(super) fn drain_pending_classification(&mut self) {
        let is_following = matches!(self.source.kind, Some(SourceKind::Home { following: true }));
        let original_selected = self.source.state.selected;
        let mut cursor = original_selected;

        while let Some(front) = self.pending_classification.first() {
            match self.filter_verdicts.get(&front.rest_id) {
                Some(FilterState::Classified(FilterDecision::Keep)) => {
                    let t = self.pending_classification.remove(0);
                    if !self.source.tweets.iter().any(|x| x.rest_id == t.rest_id) {
                        if is_following {
                            let pos = self
                                .source
                                .tweets
                                .partition_point(|x| x.created_at > t.created_at);
                            if pos <= cursor {
                                cursor += 1;
                            }
                            self.source.tweets.insert(pos, t);
                        } else {
                            self.source.tweets.push(t);
                        }
                    }
                }
                Some(FilterState::Classified(FilterDecision::Hide)) => {
                    self.pending_classification.remove(0);
                }
                _ => break,
            }
        }
        if is_following && original_selected > 0 {
            self.source.state.selected = cursor;
        }
        self.try_advance_fetch_target();
    }

    pub(super) fn sort_source_if_following(&mut self) {
        if !matches!(self.source.kind, Some(SourceKind::Home { following: true })) {
            return;
        }
        let selected_id = if self.source.state.selected > 0 {
            self.source
                .tweets
                .get(self.source.state.selected)
                .map(|t| t.rest_id.clone())
        } else {
            None
        };
        self.source
            .tweets
            .sort_by_key(|t| std::cmp::Reverse(t.created_at));
        if let Some(id) = selected_id {
            if let Some(idx) = self.source.tweets.iter().position(|t| t.rest_id == id) {
                self.source.state.selected = idx;
            }
        }
    }

    pub(super) fn try_advance_fetch_target(&mut self) {
        let Some(baseline) = self.fetch_baseline else {
            return;
        };
        let target = baseline + super::app::FETCH_TARGET_TWEETS;

        if self.source.tweets.len() >= target {
            self.fetch_baseline = None;
            self.source.loading = false;
            self.clear_status();
            return;
        }

        let total_eventual = self.source.tweets.len() + self.pending_classification.len();
        let is_home = self
            .source
            .kind
            .as_ref()
            .is_some_and(|k| matches!(k, SourceKind::Home { .. }));
        let can_fetch_more = self.source.cursor.is_some() && !self.source.exhausted && is_home;

        if total_eventual < target && can_fetch_more {
            if !self.source.loading {
                self.fetch_source(true, false);
            }
            return;
        }

        if self.pending_classification.is_empty() {
            self.fetch_baseline = None;
            self.source.loading = false;
            self.clear_status();
            return;
        }

        self.source.loading = true;
    }

    pub(super) fn translate_selected(&mut self) {
        let (rest_id, text) = match self.selected_tweet() {
            Some(t) => (t.rest_id.clone(), t.text.clone()),
            None => return,
        };

        if self.translations.remove(&rest_id).is_some() {
            self.set_status("translation removed");
            return;
        }

        if self.translation_inflight.contains(&rest_id) {
            self.set_status("translating…");
            return;
        }

        let Some(ollama) = self.filter_cfg.as_ref().map(|c| c.ollama.clone()) else {
            self.set_status("translation unavailable (no ollama config)");
            return;
        };

        self.translation_inflight.insert(rest_id.clone());
        self.set_status("translating…");
        filter::translate_async(rest_id, text, ollama, self.tx.clone());
    }

    pub(super) fn handle_tweet_translated(&mut self, rest_id: String, translated: String) {
        self.translation_inflight.remove(&rest_id);
        self.translations.insert(rest_id, translated);
        self.set_status("translated");
    }

    pub(super) fn open_ask_for_selected(&mut self) {
        let tweet = match self.selected_tweet() {
            Some(t) => t.clone(),
            None => {
                self.set_status("no tweet selected");
                return;
            }
        };
        let Some(ollama) = self.filter_cfg.as_ref().map(|c| c.ollama.clone()) else {
            self.set_status("ask unavailable (no ollama config)");
            return;
        };
        ask::preload(ollama);

        let in_detail = self.active == super::app::ActivePane::Detail;
        let asked_parent_id = tweet.in_reply_to_tweet_id.clone();
        let needs_ancestors = asked_parent_id.is_some();

        let preseed_thread: Option<ask::ThreadContext> = if in_detail && needs_ancestors {
            self.top_detail().and_then(|d| {
                if d.tweet.rest_id == tweet.rest_id {
                    None
                } else if asked_parent_id.as_deref() == Some(d.tweet.rest_id.as_str()) {
                    let siblings: Vec<Tweet> = d
                        .replies
                        .iter()
                        .filter(|r| r.rest_id != tweet.rest_id)
                        .cloned()
                        .collect();
                    Some(ask::ThreadContext {
                        ancestors: vec![d.tweet.clone()],
                        siblings,
                    })
                } else {
                    None
                }
            })
        } else {
            None
        };

        let replies_in_detail = if in_detail && !needs_ancestors {
            self.top_detail()
                .filter(|d| d.tweet.rest_id == tweet.rest_id)
                .map(|d| d.replies.clone())
        } else {
            None
        };
        let replies = replies_in_detail.clone().unwrap_or_default();
        let needs_replies_fetch = replies_in_detail.is_none() && tweet.reply_count > 0;
        let needs_fetch = needs_ancestors || needs_replies_fetch;

        tracing::info!(
            tweet_id = %tweet.rest_id,
            replies = replies.len(),
            preseed_ancestors = preseed_thread.as_ref().map(|c| c.ancestors.len()).unwrap_or(0),
            has_parent = needs_ancestors,
            will_fetch = needs_fetch,
            "ask view opened"
        );
        let mut view = AskView::new(tweet.clone(), replies, needs_replies_fetch);
        if let Some(ctx) = preseed_thread {
            view = view.with_thread(ctx);
        }
        if needs_ancestors {
            view = view.with_thread_loading();
        }
        self.focus_stack.push(FocusEntry::Ask(view));
        self.active = super::app::ActivePane::Detail;
        self.set_status("ask: digit = preset, type for custom, Enter to send");
        if needs_fetch {
            let tweet_id = tweet.rest_id.clone();
            let parent_id = asked_parent_id.clone();
            let client = self.client.clone();
            let tx = self.tx.clone();
            tokio::spawn(async move {
                match focus::fetch_thread(&client, &tweet_id).await {
                    Ok(page) => {
                        let by_id: std::collections::HashMap<String, Tweet> = page
                            .tweets
                            .iter()
                            .cloned()
                            .map(|t| (t.rest_id.clone(), t))
                            .collect();
                        let replies: Vec<Tweet> = page
                            .tweets
                            .iter()
                            .filter(|t| {
                                t.rest_id != tweet_id
                                    && t.in_reply_to_tweet_id.as_deref() == Some(&tweet_id)
                            })
                            .cloned()
                            .collect();
                        let mut ancestors: Vec<Tweet> = Vec::new();
                        let mut cur = parent_id.clone();
                        let mut guard = 0usize;
                        while let Some(id) = cur {
                            if guard > 32 {
                                break;
                            }
                            guard += 1;
                            match by_id.get(&id) {
                                Some(t) => {
                                    cur = t.in_reply_to_tweet_id.clone();
                                    ancestors.push(t.clone());
                                }
                                None => break,
                            }
                        }
                        ancestors.reverse();
                        let siblings: Vec<Tweet> = if let Some(pid) = parent_id.as_ref() {
                            page.tweets
                                .iter()
                                .filter(|t| {
                                    t.rest_id != tweet_id
                                        && t.in_reply_to_tweet_id.as_deref() == Some(pid.as_str())
                                })
                                .cloned()
                                .collect()
                        } else {
                            Vec::new()
                        };
                        tracing::info!(
                            tweet_id = %tweet_id,
                            replies = replies.len(),
                            ancestors = ancestors.len(),
                            siblings = siblings.len(),
                            "ask thread loaded"
                        );
                        let _ = tx.send(Event::AskThreadLoaded {
                            tweet_id,
                            replies,
                            ancestors,
                            siblings,
                        });
                    }
                    Err(e) => {
                        tracing::warn!(tweet_id = %tweet_id, "ask thread fetch failed: {e}");
                        let _ = tx.send(Event::AskThreadLoaded {
                            tweet_id,
                            replies: Vec::new(),
                            ancestors: Vec::new(),
                            siblings: Vec::new(),
                        });
                    }
                }
            });
        }
    }

    pub(super) fn handle_ask_thread_loaded(
        &mut self,
        tweet_id: String,
        replies: Vec<Tweet>,
        ancestors: Vec<Tweet>,
        siblings: Vec<Tweet>,
    ) {
        if let Some(FocusEntry::Ask(view)) = self.focus_stack.last_mut()
            && view.tweet_id() == tweet_id
        {
            if view.replies_loading {
                view.replies = replies;
                view.replies_loading = false;
            } else if view.replies.is_empty() && !replies.is_empty() {
                view.replies = replies;
            }
            if !ancestors.is_empty() || !siblings.is_empty() {
                view.thread = Some(ask::ThreadContext {
                    ancestors,
                    siblings,
                });
            }
            view.thread_loading = false;
        }
    }

    pub(super) fn ask_submit_input(&mut self) {
        let Some(ollama) = self.filter_cfg.as_ref().map(|c| c.ollama.clone()) else {
            self.set_status("ask unavailable (no ollama config)");
            return;
        };
        let Some(FocusEntry::Ask(view)) = self.focus_stack.last_mut() else {
            return;
        };
        if view.streaming {
            return;
        }
        let prompt_text = view.editor.input.trim().to_string();
        let effective_prompt = if prompt_text.is_empty() {
            ask::DEFAULT_PROMPT.to_string()
        } else {
            prompt_text
        };
        view.editor.input.clear();
        view.editor.cursor_pos = 0;
        view.push_user_message(effective_prompt);
        view.auto_follow = true;
        let tweet = view.tweet.clone();
        let replies = view.replies.clone();
        let thread = view.thread.clone();
        let turns = view.turn_texts();
        let tx = self.tx.clone();
        ask::send(ollama, tweet, replies, thread, turns, tx);
    }

    pub(super) fn ask_fire_preset(&mut self, index: usize) {
        let Some(FocusEntry::Ask(view)) = self.focus_stack.last_mut() else {
            return;
        };
        if view.streaming || !view.editor.input.is_empty() {
            return;
        }
        let Some(preset) = ask::PRESETS.get(index.saturating_sub(1)) else {
            return;
        };
        if !view.preset_enabled(preset) {
            self.set_status(format!("[{index}] needs thread context"));
            return;
        }
        view.editor.input = preset.prompt.to_string();
        view.editor.cursor_pos = view.editor.input.len();
        self.ask_submit_input();
    }

    pub(super) fn handle_ask_token(&mut self, tweet_id: String, token: String) {
        if let Some(FocusEntry::Ask(view)) = self.focus_stack.last_mut()
            && view.tweet_id() == tweet_id
        {
            view.append_token(&token);
        }
    }

    pub(super) fn handle_ask_stream_finished(&mut self, tweet_id: String, error: Option<String>) {
        if let Some(FocusEntry::Ask(view)) = self.focus_stack.last_mut()
            && view.tweet_id() == tweet_id
        {
            if let Some(err) = &error {
                tracing::warn!(tweet_id = %tweet_id, "ask stream error: {err}");
                self.set_status(format!("ask error: {err}"));
            } else {
                self.set_status("ask done");
            }
            if let Some(FocusEntry::Ask(view)) = self.focus_stack.last_mut() {
                view.mark_done(error);
            }
        }
    }

    pub(super) fn open_brief_for_target(&mut self) {
        let Some(ollama) = self.filter_cfg.as_ref().map(|c| c.ollama.clone()) else {
            self.set_status("profile unavailable (no ollama config)");
            return;
        };
        if self.block_if_read_limited() {
            return;
        }
        let (handle, prefetched) = match self.brief_target() {
            Some(h) => h,
            None => {
                self.set_status("no target for profile");
                return;
            }
        };
        if let Some(cached) = self.brief_cache.get(&handle).cloned() {
            tracing::info!(handle = %handle, "profile view opened from cache");
            self.focus_stack.push(FocusEntry::Brief(cached));
            self.active = super::app::ActivePane::Detail;
            self.set_status("profile cached · R to re-read");
            ask::preload(ollama);
            return;
        }
        tracing::info!(handle = %handle, "profile view opened");
        let view = BriefView::new(handle.clone());
        self.focus_stack.push(FocusEntry::Brief(view));
        self.active = super::app::ActivePane::Detail;
        self.set_status(format!("profile · jacking into @{handle}…"));
        ask::preload(ollama.clone());
        brief::start(
            self.client.clone(),
            ollama,
            handle,
            prefetched,
            self.tx.clone(),
        );
    }

    pub(super) fn brief_target(&self) -> Option<(String, Option<Vec<Tweet>>)> {
        if let Some(SourceKind::User { handle }) = &self.source.kind {
            let mine: Vec<Tweet> = self
                .source
                .tweets
                .iter()
                .filter(|t| t.author.handle.eq_ignore_ascii_case(handle))
                .cloned()
                .collect();
            return Some((handle.clone(), Some(mine)));
        }
        let tweet = self.selected_tweet()?;
        Some((tweet.author.handle.clone(), None))
    }

    pub(super) fn refresh_brief(&mut self) {
        let handle = {
            let Some(FocusEntry::Brief(view)) = self.focus_stack.last_mut() else {
                return;
            };
            if view.streaming || view.loading_tweets {
                return;
            }
            view.handle.clone()
        };
        let Some(ollama) = self.filter_cfg.as_ref().map(|c| c.ollama.clone()) else {
            return;
        };
        self.brief_cache.remove(&handle);
        if let Some(FocusEntry::Brief(view)) = self.focus_stack.last_mut() {
            *view = BriefView::new(handle.clone());
        }
        self.set_status(format!("profile · re-reading @{handle}…"));
        brief::start(self.client.clone(), ollama, handle, None, self.tx.clone());
    }

    pub(super) fn handle_brief_sample_ready(
        &mut self,
        handle: String,
        count: usize,
        span_label: String,
        error: Option<String>,
        sample: Vec<Tweet>,
    ) {
        let mut status_msg: Option<String> = None;
        if let Some(FocusEntry::Brief(view)) = self.focus_stack.last_mut()
            && view.handle == handle
        {
            if let Some(err) = error {
                let msg = err.clone();
                view.set_error(err);
                status_msg = Some(format!("profile: {msg}"));
            } else {
                view.start_analysis(count, span_label, sample);
            }
        }
        if let Some(msg) = status_msg {
            self.set_status(msg);
        }
    }

    pub(super) fn handle_brief_fetch_progress(
        &mut self,
        handle: String,
        pages: usize,
        authored: usize,
    ) {
        if let Some(FocusEntry::Brief(view)) = self.focus_stack.last_mut()
            && view.handle == handle
        {
            view.fetch_pages = pages;
            view.fetch_authored = authored;
        }
    }

    pub(super) fn handle_brief_token(&mut self, handle: String, token: String) {
        if let Some(FocusEntry::Brief(view)) = self.focus_stack.last_mut()
            && view.handle == handle
        {
            view.append_token(&token);
        }
    }

    pub(super) fn handle_brief_stream_finished(&mut self, handle: String, error: Option<String>) {
        let mut done_text: Option<BriefView> = None;
        if let Some(FocusEntry::Brief(view)) = self.focus_stack.last_mut()
            && view.handle == handle
        {
            view.mark_done(error.clone());
            if error.is_none() && !view.text.trim().is_empty() {
                done_text = Some(BriefView {
                    handle: view.handle.clone(),
                    sample: view.sample.clone(),
                    sample_count: view.sample_count,
                    span_label: view.span_label.clone(),
                    loading_tweets: false,
                    fetch_pages: view.fetch_pages,
                    fetch_authored: view.fetch_authored,
                    streaming: false,
                    complete: true,
                    text: view.text.clone(),
                    error: None,
                    scroll: 0,
                });
            }
        }
        if let Some(err) = error {
            tracing::warn!(handle = %handle, "profile error: {err}");
            self.set_status(format!("profile aborted: {err}"));
        } else {
            self.set_status("profile complete");
        }
        if let Some(snap) = done_text {
            self.brief_cache.insert(handle, snap);
        }
    }
}
