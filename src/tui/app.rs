use crate::cli::common;
use crate::config::{self, AppConfig};
use crate::error::Result;
use crate::gql::GqlClient;
use crate::model::Tweet;
use crate::parse::timeline::TimelinePage;
use crate::tui::ask::{self, AskView};
use crate::tui::brief::{self, BriefView};
use crate::tui::command::{self, Command};
use crate::tui::engage::EngageAction;
use crate::tui::event::{self, Event, EventTx, RequestId};
use crate::tui::filter::{
    self, Classifier, FilterCache, FilterConfig, FilterDecision, FilterMode, FilterState,
    TweetPayload,
};
use crate::tui::focus::{self, FocusEntry, TweetDetail};
use crate::tui::media::MediaRegistry;
use crate::tui::seen::SeenStore;
use crate::tui::session::{self, SessionState};
use crate::tui::source::{self, Source, SourceKind};
use crate::tui::ui;
use crate::tui::whisper::{self, NotifEntry, WhisperEntry, WhisperState};
use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::DefaultTerminal;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};

pub const DEFAULT_STATUS: &str = "? for help";

#[derive(Debug, Default)]
pub struct InlineThread {
    pub loading: bool,
    pub replies: Vec<(usize, Tweet)>,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ActivePane {
    Source,
    Detail,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InputMode {
    Normal,
    Command,
    Help,
    Changelog,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TimestampStyle {
    Absolute,
    Relative,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MetricsStyle {
    Visible,
    Hidden,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DisplayNameStyle {
    Visible,
    Hidden,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FeedMode {
    All,
    Originals,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum ReplySortOrder {
    #[default]
    Newest,
    Likes,
    Replies,
    Retweets,
    Views,
}

impl ReplySortOrder {
    pub fn cycle(self) -> Self {
        match self {
            Self::Newest => Self::Likes,
            Self::Likes => Self::Replies,
            Self::Replies => Self::Retweets,
            Self::Retweets => Self::Views,
            Self::Views => Self::Newest,
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Self::Newest => "newest",
            Self::Likes => "likes",
            Self::Replies => "replies",
            Self::Retweets => "retweets",
            Self::Views => "views",
        }
    }
}

pub struct App {
    pub running: bool,
    pub mode: InputMode,
    pub command_buffer: String,
    pub source: Source,
    pub focus_stack: Vec<FocusEntry>,
    pub active: ActivePane,
    pub history: Vec<SourceKind>,
    pub history_cursor: usize,
    pub status: String,
    pub status_until: Option<Instant>,
    pub error: Option<String>,
    pub last_tick: Instant,
    pub terminal_focused: bool,
    pub last_render_at: Option<Instant>,
    pub dirty: bool,
    pub seen: SeenStore,
    pub session_path: PathBuf,
    pub timestamps: TimestampStyle,
    pub metrics: MetricsStyle,
    pub display_names: DisplayNameStyle,
    pub split_pct: u16,
    pub spinner_frame: usize,
    pub is_dark: bool,
    pub expanded_bodies: HashSet<String>,
    pub inline_threads: HashMap<String, InlineThread>,
    pub media: MediaRegistry,
    pub media_auto_expand: bool,
    pub feed_mode: FeedMode,
    pub self_handle: Option<String>,
    pub filter_mode: FilterMode,
    pub filter_cfg: Option<FilterConfig>,
    pub filter_cache: Option<FilterCache>,
    pub filter_classifier: Option<Classifier>,
    pub filter_verdicts: HashMap<String, FilterState>,
    pub filter_inflight: HashSet<String>,
    pub filter_hidden_count: usize,
    pub pending_classification: Vec<Tweet>,
    pub translations: HashMap<String, String>,
    pub translation_inflight: HashSet<String>,
    pub engage_inflight: HashSet<String>,
    pub brief_cache: HashMap<String, BriefView>,
    pub reply_sort: ReplySortOrder,
    pub app_config: AppConfig,
    pub help_scroll: u16,
    pub whisper: WhisperState,
    pub notif_seen: SeenStore,
    pub notif_unread_badge: usize,
    pub notif_actor_cursor: Option<usize>,
    pub(super) client: Arc<GqlClient>,
    pub(super) tx: EventTx,
    pub(super) pending_thread: Option<RequestId>,
    pub(super) pending_open: Option<RequestId>,
    pub(super) pending_notif_scroll: Option<String>,
    pub(super) fetch_baseline: Option<usize>,
    pub update_available: Option<String>,
    pub changelog: Option<Vec<crate::update::ReleaseEntry>>,
    pub changelog_scroll: u16,
    pub changelog_loading: bool,
}

pub const SPINNER_FRAMES: &[&str] = &["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];

const FETCH_TARGET_TWEETS: usize = 50;

impl App {
    pub async fn new(tx: EventTx, is_dark: bool) -> Result<Self> {
        let client = Arc::new(common::build_gql_client().await?);

        let cache_dir = config::cache_dir()?;
        let config_dir = config::config_dir()?;
        let seen = SeenStore::open(&cache_dir.join("seen.db"))?;
        let notif_seen = SeenStore::open(&cache_dir.join("notif_seen.db"))?;
        let session_path = config_dir.join("session.json");

        let app_config = AppConfig::load(&config_dir);

        let (filter_cfg, filter_cache, filter_classifier) =
            init_filter_stack(&config_dir, &cache_dir);
        let filter_classifier = match filter_classifier {
            Some(mut c) => match c.init().await {
                Ok(()) => Some(c),
                Err(e) => {
                    tracing::warn!("ollama init failed: {e} — filter disabled");
                    None
                }
            },
            None => None,
        };

        let loaded = session::load(&session_path);
        let (initial_kind, initial_selected) = loaded
            .as_ref()
            .map(|s| (s.source_kind.clone(), s.selected))
            .unwrap_or_else(|| (SourceKind::Home { following: false }, 0));
        let loaded_metrics = loaded
            .as_ref()
            .and_then(|s| s.metrics)
            .unwrap_or(MetricsStyle::Visible);
        let loaded_display_names = loaded
            .as_ref()
            .and_then(|s| s.display_names)
            .unwrap_or(DisplayNameStyle::Visible);
        let loaded_timestamps = loaded
            .as_ref()
            .and_then(|s| s.timestamps)
            .unwrap_or(TimestampStyle::Relative);
        let loaded_feed_mode = loaded
            .as_ref()
            .and_then(|s| s.feed_mode)
            .unwrap_or(FeedMode::All);
        let loaded_reply_sort = loaded
            .as_ref()
            .and_then(|s| s.reply_sort)
            .unwrap_or_default();

        let mut source = Source::new(initial_kind.clone());
        source.set_selected(initial_selected);

        let mut whisper_state = WhisperState::new();
        if let Some(ref s) = loaded {
            if let Some(ref cursor) = s.whisper_cursor {
                if let Ok(ts) = cursor.parse::<i64>() {
                    whisper_state.watermark_ts = ts;
                }
            }
        }

        whisper::start_poll_loop(tx.clone());
        spawn_update_check(tx.clone());

        Ok(Self {
            running: true,
            mode: InputMode::Normal,
            command_buffer: String::new(),
            source,
            focus_stack: Vec::new(),
            active: ActivePane::Source,
            history: vec![initial_kind],
            history_cursor: 0,
            status: DEFAULT_STATUS.into(),
            status_until: None,
            error: None,
            last_tick: Instant::now(),
            terminal_focused: true,
            last_render_at: None,
            dirty: true,
            seen,
            session_path,
            timestamps: loaded_timestamps,
            metrics: loaded_metrics,
            display_names: loaded_display_names,
            split_pct: 50,
            spinner_frame: 0,
            is_dark,
            expanded_bodies: HashSet::new(),
            inline_threads: HashMap::new(),
            media: MediaRegistry::new(),
            media_auto_expand: false,
            feed_mode: loaded_feed_mode,
            reply_sort: loaded_reply_sort,
            self_handle: None,
            filter_mode: FilterMode::On,
            filter_cfg,
            filter_cache,
            filter_classifier,
            filter_verdicts: HashMap::new(),
            filter_inflight: HashSet::new(),
            filter_hidden_count: 0,
            pending_classification: Vec::new(),
            translations: HashMap::new(),
            translation_inflight: HashSet::new(),
            engage_inflight: HashSet::new(),
            brief_cache: HashMap::new(),
            app_config,
            help_scroll: 0,
            whisper: whisper_state,
            notif_seen,
            notif_unread_badge: 0,
            notif_actor_cursor: None,
            client,
            tx,
            pending_thread: None,
            pending_open: None,
            pending_notif_scroll: None,
            fetch_baseline: None,
            update_available: None,
            changelog: None,
            changelog_scroll: 0,
            changelog_loading: false,
        })
    }

    pub fn set_status(&mut self, msg: impl Into<String>) {
        self.status = msg.into();
        self.status_until = Some(Instant::now() + Duration::from_secs(3));
    }

    pub fn rate_limit_remaining(&self) -> Option<std::time::Duration> {
        self.client.rate_limit_remaining()
    }

    fn block_if_rate_limited(&mut self) -> bool {
        if let Some(remaining) = self.rate_limit_remaining() {
            let secs = remaining.as_secs();
            let label = if secs < 60 {
                format!("{secs}s")
            } else {
                format!("{}:{:02}", secs / 60, secs % 60)
            };
            self.set_status(format!("rate-limited · retry in {label}"));
            true
        } else {
            false
        }
    }

    pub fn clear_status(&mut self) {
        self.status = DEFAULT_STATUS.into();
        self.status_until = None;
    }

    fn tick_status(&mut self) {
        if let Some(until) = self.status_until
            && Instant::now() >= until
        {
            self.clear_status();
        }
    }

    pub fn filter_pending_count(&self) -> usize {
        self.filter_inflight.len()
    }

    pub fn is_own_profile(&self) -> bool {
        match (&self.self_handle, &self.source.kind) {
            (Some(self_handle), Some(SourceKind::User { handle })) => {
                self_handle.eq_ignore_ascii_case(handle)
            }
            _ => false,
        }
    }

    fn open_profile(&mut self) {
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

    fn queue_filter_classification(&mut self, tweets: Vec<Tweet>) {
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

    fn handle_tweet_classified(&mut self, rest_id: String, verdict: FilterDecision) {
        self.filter_inflight.remove(&rest_id);
        if let Some(cache) = self.filter_cache.as_mut() {
            cache.put(&rest_id, verdict);
        }
        self.filter_verdicts
            .insert(rest_id.clone(), FilterState::Classified(verdict));
        if matches!(verdict, FilterDecision::Hide) {
            self.filter_hidden_count += 1;
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

    fn drain_pending_classification(&mut self) {
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

    fn sort_source_if_following(&mut self) {
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
            .sort_by(|a, b| b.created_at.cmp(&a.created_at));
        if let Some(id) = selected_id {
            if let Some(idx) = self.source.tweets.iter().position(|t| t.rest_id == id) {
                self.source.state.selected = idx;
            }
        }
    }

    fn try_advance_fetch_target(&mut self) {
        let Some(baseline) = self.fetch_baseline else {
            return;
        };
        let target = baseline + FETCH_TARGET_TWEETS;

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

    fn translate_selected(&mut self) {
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

    fn handle_tweet_translated(&mut self, rest_id: String, translated: String) {
        self.translation_inflight.remove(&rest_id);
        self.translations.insert(rest_id, translated);
        self.set_status("translated");
    }

    fn engage(&mut self, action: EngageAction) {
        if self.block_if_rate_limited() {
            return;
        }
        let Some(tweet) = self.selected_tweet().cloned() else {
            return;
        };
        if self.engage_inflight.contains(&tweet.rest_id) {
            return;
        }

        let verb = action.verb(action.is_engaged(&tweet));
        self.engage_inflight.insert(tweet.rest_id.clone());
        self.mutate_tweet_by_id(&tweet.rest_id, |t| action.apply(t));
        self.set_status(verb);

        crate::tui::engage::dispatch(action, &tweet, self.client.clone(), self.tx.clone());
    }

    fn handle_engage_result(
        &mut self,
        rest_id: String,
        action: EngageAction,
        error: Option<String>,
    ) {
        self.engage_inflight.remove(&rest_id);
        if let Some(err) = error {
            self.mutate_tweet_by_id(&rest_id, |t| action.apply(t));
            self.error = Some(err);
        }
    }

    fn mutate_tweet_by_id(&mut self, rest_id: &str, f: impl Fn(&mut Tweet)) {
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

    fn open_ask_for_selected(&mut self) {
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
        let replies_in_detail = if self.active == ActivePane::Detail {
            self.top_detail()
                .filter(|d| d.tweet.rest_id == tweet.rest_id)
                .map(|d| d.replies.clone())
        } else {
            None
        };
        let should_fetch = replies_in_detail.is_none() && tweet.reply_count > 0;
        let replies = replies_in_detail.unwrap_or_default();
        tracing::info!(
            tweet_id = %tweet.rest_id,
            replies = replies.len(),
            will_fetch = should_fetch,
            "ask view opened"
        );
        let view = AskView::new(tweet.clone(), replies, should_fetch);
        self.focus_stack.push(FocusEntry::Ask(view));
        self.active = ActivePane::Detail;
        self.set_status("ask: digit = preset, type for custom, Enter to send");
        if should_fetch {
            let tweet_id = tweet.rest_id.clone();
            let client = self.client.clone();
            let tx = self.tx.clone();
            tokio::spawn(async move {
                match focus::fetch_thread(&client, &tweet_id).await {
                    Ok(page) => {
                        let focal_id = tweet_id.clone();
                        let replies: Vec<Tweet> = page
                            .tweets
                            .into_iter()
                            .filter(|t| {
                                t.rest_id != focal_id
                                    && t.in_reply_to_tweet_id.as_deref() == Some(&focal_id)
                            })
                            .collect();
                        tracing::info!(
                            tweet_id = %tweet_id,
                            count = replies.len(),
                            "ask replies loaded"
                        );
                        let _ = tx.send(Event::AskRepliesLoaded { tweet_id, replies });
                    }
                    Err(e) => {
                        tracing::warn!(tweet_id = %tweet_id, "ask reply fetch failed: {e}");
                        let _ = tx.send(Event::AskRepliesLoaded {
                            tweet_id,
                            replies: Vec::new(),
                        });
                    }
                }
            });
        }
    }

    fn handle_ask_replies_loaded(&mut self, tweet_id: String, replies: Vec<Tweet>) {
        if let Some(FocusEntry::Ask(view)) = self.focus_stack.last_mut()
            && view.tweet_id() == tweet_id
        {
            view.replies = replies;
            view.replies_loading = false;
        }
    }

    fn open_brief_for_target(&mut self) {
        let Some(ollama) = self.filter_cfg.as_ref().map(|c| c.ollama.clone()) else {
            self.set_status("profile unavailable (no ollama config)");
            return;
        };
        if self.block_if_rate_limited() {
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
            self.active = ActivePane::Detail;
            self.set_status("profile cached · R to re-read");
            ask::preload(ollama);
            return;
        }
        tracing::info!(handle = %handle, "profile view opened");
        let view = BriefView::new(handle.clone());
        self.focus_stack.push(FocusEntry::Brief(view));
        self.active = ActivePane::Detail;
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

    fn brief_target(&self) -> Option<(String, Option<Vec<Tweet>>)> {
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

    fn refresh_brief(&mut self) {
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

    fn handle_brief_sample_ready(
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

    fn handle_brief_fetch_progress(&mut self, handle: String, pages: usize, authored: usize) {
        if let Some(FocusEntry::Brief(view)) = self.focus_stack.last_mut()
            && view.handle == handle
        {
            view.fetch_pages = pages;
            view.fetch_authored = authored;
        }
    }

    fn handle_brief_token(&mut self, handle: String, token: String) {
        if let Some(FocusEntry::Brief(view)) = self.focus_stack.last_mut()
            && view.handle == handle
        {
            view.append_token(&token);
        }
    }

    fn handle_brief_stream_finished(&mut self, handle: String, error: Option<String>) {
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

    fn handle_key_brief(&mut self, key: KeyEvent) {
        fn scroll_by(view: &mut BriefView, delta: i32) {
            view.scroll = if delta >= 0 {
                view.scroll.saturating_add(delta as u16)
            } else {
                view.scroll.saturating_sub((-delta) as u16)
            };
        }
        match (key.code, key.modifiers) {
            (KeyCode::Char('c'), KeyModifiers::CONTROL) => self.running = false,
            (KeyCode::Esc, _) | (KeyCode::Char('q'), KeyModifiers::NONE) => self.back_out(false),
            (KeyCode::Tab, _) if self.is_split() => {
                self.active = match self.active {
                    ActivePane::Source => ActivePane::Detail,
                    ActivePane::Detail => ActivePane::Source,
                };
            }
            (KeyCode::Char('R'), _) => self.refresh_brief(),
            (KeyCode::Char('j'), KeyModifiers::NONE) | (KeyCode::Down, _) => {
                if let Some(FocusEntry::Brief(view)) = self.focus_stack.last_mut() {
                    scroll_by(view, 1);
                }
            }
            (KeyCode::Char('k'), KeyModifiers::NONE) | (KeyCode::Up, _) => {
                if let Some(FocusEntry::Brief(view)) = self.focus_stack.last_mut() {
                    scroll_by(view, -1);
                }
            }
            (KeyCode::Char('d'), KeyModifiers::CONTROL) => {
                if let Some(FocusEntry::Brief(view)) = self.focus_stack.last_mut() {
                    scroll_by(view, 10);
                }
            }
            (KeyCode::Char('u'), KeyModifiers::CONTROL) => {
                if let Some(FocusEntry::Brief(view)) = self.focus_stack.last_mut() {
                    scroll_by(view, -10);
                }
            }
            (KeyCode::Char('f'), KeyModifiers::CONTROL)
            | (KeyCode::PageDown, _)
            | (KeyCode::Char(' '), KeyModifiers::NONE) => {
                if let Some(FocusEntry::Brief(view)) = self.focus_stack.last_mut() {
                    scroll_by(view, 20);
                }
            }
            (KeyCode::Char('b'), KeyModifiers::CONTROL) | (KeyCode::PageUp, _) => {
                if let Some(FocusEntry::Brief(view)) = self.focus_stack.last_mut() {
                    scroll_by(view, -20);
                }
            }
            (KeyCode::Char('g'), KeyModifiers::NONE) | (KeyCode::Home, _) => {
                if let Some(FocusEntry::Brief(view)) = self.focus_stack.last_mut() {
                    view.scroll = 0;
                }
            }
            (KeyCode::Char('G'), KeyModifiers::NONE | KeyModifiers::SHIFT) | (KeyCode::End, _) => {
                if let Some(FocusEntry::Brief(view)) = self.focus_stack.last_mut() {
                    view.scroll = u16::MAX;
                }
            }
            _ => {}
        }
    }

    fn ask_submit_input(&mut self) {
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
        let prompt_text = view.input.trim().to_string();
        let effective_prompt = if prompt_text.is_empty() {
            ask::DEFAULT_PROMPT.to_string()
        } else {
            prompt_text
        };
        view.input.clear();
        view.push_user_message(effective_prompt);
        view.auto_follow = true;
        let tweet = view.tweet.clone();
        let replies = view.replies.clone();
        let turns = view.turn_texts();
        let tx = self.tx.clone();
        ask::send(ollama, tweet, replies, turns, tx);
    }

    fn ask_fire_preset(&mut self, index: usize) {
        let Some(FocusEntry::Ask(view)) = self.focus_stack.last_mut() else {
            return;
        };
        if view.streaming || !view.input.is_empty() {
            return;
        }
        let Some(preset) = ask::PRESETS.get(index.saturating_sub(1)) else {
            return;
        };
        if !view.preset_enabled(preset) {
            self.set_status(format!("[{index}] needs thread context"));
            return;
        }
        view.input = preset.prompt.to_string();
        self.ask_submit_input();
    }

    fn handle_ask_token(&mut self, tweet_id: String, token: String) {
        if let Some(FocusEntry::Ask(view)) = self.focus_stack.last_mut()
            && view.tweet_id() == tweet_id
        {
            view.append_token(&token);
        }
    }

    fn handle_ask_stream_finished(&mut self, tweet_id: String, error: Option<String>) {
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

    fn handle_key_ask(&mut self, key: KeyEvent) {
        match (key.code, key.modifiers) {
            (KeyCode::Char('c'), KeyModifiers::CONTROL) => self.running = false,
            (KeyCode::Esc, _) => self.back_out(false),
            (KeyCode::Tab, _) if self.is_split() => {
                self.active = match self.active {
                    ActivePane::Source => ActivePane::Detail,
                    ActivePane::Detail => ActivePane::Source,
                };
            }
            (KeyCode::Enter, _) => self.ask_submit_input(),
            (KeyCode::Backspace, _) => {
                if let Some(FocusEntry::Ask(view)) = self.focus_stack.last_mut() {
                    view.input.pop();
                }
            }
            (KeyCode::Char('u'), KeyModifiers::CONTROL) => {
                if let Some(FocusEntry::Ask(view)) = self.focus_stack.last_mut() {
                    view.input.clear();
                }
            }
            (KeyCode::Char('w'), KeyModifiers::CONTROL) => {
                if let Some(FocusEntry::Ask(view)) = self.focus_stack.last_mut() {
                    let trimmed_end = view.input.trim_end_matches(char::is_whitespace).len();
                    let cut_to = view.input[..trimmed_end]
                        .rfind(char::is_whitespace)
                        .map(|i| i + 1)
                        .unwrap_or(0);
                    view.input.truncate(cut_to);
                }
            }
            (KeyCode::Up, _) => {
                if let Some(FocusEntry::Ask(view)) = self.focus_stack.last_mut() {
                    view.auto_follow = false;
                    view.state.scroll = view.state.scroll.saturating_sub(1);
                }
            }
            (KeyCode::Down, _) => {
                if let Some(FocusEntry::Ask(view)) = self.focus_stack.last_mut() {
                    view.state.scroll = view.state.scroll.saturating_add(1);
                }
            }
            (KeyCode::PageUp, _) => {
                if let Some(FocusEntry::Ask(view)) = self.focus_stack.last_mut() {
                    view.auto_follow = false;
                    view.state.scroll = view.state.scroll.saturating_sub(10);
                }
            }
            (KeyCode::PageDown, _) => {
                if let Some(FocusEntry::Ask(view)) = self.focus_stack.last_mut() {
                    view.state.scroll = view.state.scroll.saturating_add(10);
                }
            }
            (KeyCode::Char(c @ '1'..='9'), m)
                if !m.contains(KeyModifiers::CONTROL) && !m.contains(KeyModifiers::ALT) =>
            {
                let input_empty = self
                    .focus_stack
                    .last()
                    .map(|e| match e {
                        FocusEntry::Ask(v) => v.input.is_empty() && !v.streaming,
                        _ => false,
                    })
                    .unwrap_or(false);
                if input_empty {
                    if let Some(idx) = c.to_digit(10) {
                        self.ask_fire_preset(idx as usize);
                    }
                } else if let Some(FocusEntry::Ask(view)) = self.focus_stack.last_mut()
                    && !view.streaming
                {
                    view.input.push(c);
                }
            }
            (KeyCode::Char(c), m)
                if !m.contains(KeyModifiers::CONTROL) && !m.contains(KeyModifiers::ALT) =>
            {
                if let Some(FocusEntry::Ask(view)) = self.focus_stack.last_mut()
                    && !view.streaming
                {
                    view.input.push(c);
                }
            }
            _ => {}
        }
    }

    fn handle_notifications_loaded(
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

    pub fn save_session(&self) {
        let Some(kind) = self.source.kind.clone() else {
            return;
        };
        let state = SessionState {
            source_kind: kind,
            selected: self.source.selected(),
            metrics: Some(self.metrics),
            display_names: Some(self.display_names),
            timestamps: Some(self.timestamps),
            feed_mode: Some(self.feed_mode),
            reply_sort: Some(self.reply_sort),
            whisper_cursor: if self.whisper.watermark_ts > 0 {
                Some(self.whisper.watermark_ts.to_string())
            } else {
                None
            },
        };
        if let Err(e) = session::save(&self.session_path, &state) {
            tracing::warn!("failed to save session: {e}");
        }
    }

    fn remove_tweet_by_id(&mut self, rest_id: &str) {
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

    fn mark_current_seen(&mut self) {
        if self.source.is_notifications() {
            if let Some(n) = self.source.notifications.get(self.source.selected()) {
                self.notif_seen.mark_seen(&n.id);
            }
        } else if let Some(t) = self.source.tweets.get(self.source.selected()) {
            self.seen.mark_seen(&t.rest_id);
        }
    }

    fn jump_next_unread(&mut self) {
        let start = self.source.selected() + 1;
        if self.source.is_notifications() {
            for i in start..self.source.notifications.len() {
                if !self.notif_seen.is_seen(&self.source.notifications[i].id) {
                    self.source.set_selected(i);
                    self.mark_current_seen();
                    self.maybe_load_more();
                    return;
                }
            }
            self.set_status("no more unread notifications");
        } else {
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
    }

    fn maybe_load_more(&mut self) {
        if self.source.loading || self.source.exhausted || self.source.cursor.is_none() {
            return;
        }
        if self.source.near_bottom() {
            if self.source.is_notifications() {
                self.fetch_notifications_source(true, false);
            } else {
                self.fetch_source(true, false);
            }
        }
    }

    fn mark_all_seen_in_source(&mut self) {
        if self.source.is_notifications() {
            let ids: Vec<String> = self
                .source
                .notifications
                .iter()
                .map(|n| n.id.clone())
                .collect();
            let n = ids.len();
            self.notif_seen.mark_all(ids);
            self.set_status(format!("marked {n} notifications as read"));
        } else {
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
    }

    pub fn load_initial(&mut self) {
        self.spawn_self_handle_resolve();
        if self.source.is_notifications() {
            self.fetch_notifications_source(false, false);
        } else {
            self.fetch_source(false, false);
        }
    }

    fn spawn_self_handle_resolve(&self) {
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

    pub fn is_split(&self) -> bool {
        !self.focus_stack.is_empty()
    }

    pub fn top_detail(&self) -> Option<&TweetDetail> {
        self.focus_stack.last().and_then(|entry| match entry {
            FocusEntry::Tweet(d) => Some(d),
            FocusEntry::Likers(_) | FocusEntry::Ask(_) | FocusEntry::Brief(_) => None,
        })
    }

    pub fn is_any_loading(&self) -> bool {
        self.source.loading
            || self.pending_thread.is_some()
            || self.pending_open.is_some()
            || self.focus_stack.last().is_some_and(|e| match e {
                FocusEntry::Tweet(d) => d.loading,
                FocusEntry::Likers(l) => l.loading,
                FocusEntry::Ask(a) => a.streaming,
                FocusEntry::Brief(b) => b.loading_tweets || b.streaming,
            })
    }

    pub fn handle_event(&mut self, event: Event, terminal: &mut DefaultTerminal) -> Result<()> {
        if !matches!(event, Event::Render) {
            self.dirty = true;
        }
        match event {
            Event::Render => {
                const BLURRED_MIN_INTERVAL: std::time::Duration = std::time::Duration::from_secs(1);
                if !self.dirty {
                    return Ok(());
                }
                let defer = !self.terminal_focused
                    && self
                        .last_render_at
                        .is_some_and(|t| t.elapsed() < BLURRED_MIN_INTERVAL);
                if defer {
                    return Ok(());
                }
                ui::emit_media_placements(self, terminal.size()?.width);
                terminal.draw(|frame| ui::draw(frame, self))?;
                self.last_render_at = Some(Instant::now());
                self.dirty = false;
            }
            Event::Tick => {
                self.last_tick = Instant::now();
                if self.is_any_loading() {
                    self.spinner_frame = self.spinner_frame.wrapping_add(1);
                }
                self.tick_status();
                self.mark_current_seen();
            }
            Event::Key(key) => self.handle_key(key),
            Event::Resize(_, _) => {
                ui::emit_media_placements(self, terminal.size()?.width);
                terminal.draw(|frame| ui::draw(frame, self))?;
            }
            Event::TimelineLoaded {
                kind,
                result,
                append,
                silent,
            } => self.handle_timeline_loaded(kind, result, append, silent),
            Event::ThreadLoaded {
                request_id,
                focal_id,
                result,
            } => self.handle_thread_loaded(request_id, focal_id, result),
            Event::OpenTweetResolved { request_id, result } => {
                self.handle_open_tweet_resolved(request_id, result);
            }
            Event::InlineThreadLoaded { focal_id, result } => {
                self.handle_inline_thread_loaded(focal_id, result);
            }
            Event::MediaLoadedKitty { url, id, w, h } => {
                self.media.mark_ready_kitty(&url, id, w, h);
            }
            Event::MediaLoadedPixels { url, pixels, w, h } => {
                self.media.mark_ready_pixels(&url, pixels, w, h);
            }
            Event::MediaFailed { url, err } => {
                self.media.mark_failed(&url, err);
            }
            Event::TweetClassified { rest_id, verdict } => {
                self.handle_tweet_classified(rest_id, verdict);
            }
            Event::TweetTranslated {
                rest_id,
                translated,
            } => {
                self.handle_tweet_translated(rest_id, translated);
            }
            Event::SelfHandleResolved { handle } => {
                self.self_handle = Some(handle.clone());
                self.switch_source(SourceKind::User { handle });
            }
            Event::SelfHandleBackgroundResolved { handle } => {
                tracing::info!(%handle, "self handle resolved in background");
                self.self_handle = Some(handle);
            }
            Event::NotificationPageLoaded {
                result,
                append,
                silent,
            } => {
                self.handle_notification_page_loaded(result, append, silent);
            }
            Event::UserTimelineLoaded { result } => {
                self.handle_user_timeline_loaded(result);
            }
            Event::LikersPageLoaded {
                tweet_id,
                result,
                append,
            } => {
                self.handle_likers_page_loaded(tweet_id, result, append);
            }
            Event::WhisperPollTick => {
                self.whisper.tick();
                let should_poll = self.whisper.should_poll();
                if should_poll
                    && self.source.selected() == 0
                    && !self.source.loading
                    && !self.source.silent_refreshing
                {
                    if self.source.is_notifications() {
                        self.fetch_notifications_source(false, true);
                    } else if matches!(self.source.kind, Some(SourceKind::Home { following: true }))
                    {
                        self.fetch_source(false, true);
                    }
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
            Event::NotificationsLoaded {
                notifications,
                top_cursor,
            } => {
                self.handle_notifications_loaded(notifications, top_cursor);
            }
            Event::NotificationsFailed { err } => {
                self.whisper.poll_inflight = false;
                tracing::warn!("notification poll failed: {err}");
            }
            Event::WhisperTextReady { text } => {
                self.whisper.llm_inflight = false;
                self.whisper.push_entry(WhisperEntry {
                    text,
                    created: Instant::now(),
                    priority: 1,
                });
            }
            Event::AskToken { tweet_id, token } => {
                self.handle_ask_token(tweet_id, token);
            }
            Event::AskStreamFinished { tweet_id, error } => {
                self.handle_ask_stream_finished(tweet_id, error);
            }
            Event::AskRepliesLoaded { tweet_id, replies } => {
                self.handle_ask_replies_loaded(tweet_id, replies);
            }
            Event::BriefSampleReady {
                handle,
                count,
                span_label,
                error,
                sample,
            } => {
                self.handle_brief_sample_ready(handle, count, span_label, error, sample);
            }
            Event::BriefToken { handle, token } => {
                self.handle_brief_token(handle, token);
            }
            Event::BriefStreamFinished { handle, error } => {
                self.handle_brief_stream_finished(handle, error);
            }
            Event::BriefFetchProgress {
                handle,
                pages,
                authored,
            } => {
                self.handle_brief_fetch_progress(handle, pages, authored);
            }
            Event::WhisperSurgeReady { summary, sentiment } => {
                self.whisper.llm_inflight = false;
                self.whisper.surge_sentiment = Some(sentiment);
                self.whisper.text = summary;
            }
            Event::EngageResult {
                rest_id,
                action,
                error,
            } => {
                self.handle_engage_result(rest_id, action, error);
            }
            Event::UpdateAvailable { version } => {
                self.update_available = Some(version);
            }
            Event::ChangelogLoaded { releases } => {
                self.changelog = Some(releases);
                self.changelog_loading = false;
            }
            Event::Quit => self.running = false,
            Event::FocusGained => {
                self.terminal_focused = true;
                if matches!(
                    self.focus_stack.last(),
                    Some(FocusEntry::Ask(_) | FocusEntry::Brief(_))
                ) && let Some(ollama) = self.filter_cfg.as_ref().map(|c| c.ollama.clone())
                {
                    ask::preload(ollama);
                }
            }
            Event::FocusLost => {
                self.terminal_focused = false;
                if matches!(
                    self.focus_stack.last(),
                    Some(FocusEntry::Ask(_) | FocusEntry::Brief(_))
                ) && let Some(ollama) = self.filter_cfg.as_ref().map(|c| c.ollama.clone())
                {
                    ask::unload(ollama);
                }
            }
        }
        Ok(())
    }

    fn handle_key(&mut self, key: KeyEvent) {
        if matches!(self.mode, InputMode::Command) {
            self.handle_key_command(key);
            return;
        }
        if self.active == ActivePane::Detail
            && matches!(self.focus_stack.last(), Some(FocusEntry::Ask(_)))
        {
            self.handle_key_ask(key);
            return;
        }
        if self.active == ActivePane::Detail
            && matches!(self.focus_stack.last(), Some(FocusEntry::Brief(_)))
        {
            self.handle_key_brief(key);
            return;
        }
        if matches!(self.mode, InputMode::Help | InputMode::Changelog) {
            let scroll = if self.mode == InputMode::Help {
                &mut self.help_scroll
            } else {
                &mut self.changelog_scroll
            };
            match key.code {
                KeyCode::Char('j') | KeyCode::Down => *scroll = scroll.saturating_add(1),
                KeyCode::Char('k') | KeyCode::Up => *scroll = scroll.saturating_sub(1),
                KeyCode::Char('d') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                    *scroll = scroll.saturating_add(10);
                }
                KeyCode::Char('u') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                    *scroll = scroll.saturating_sub(10);
                }
                KeyCode::Char('g') => *scroll = 0,
                KeyCode::Char('G') => *scroll = u16::MAX,
                _ => {
                    self.mode = InputMode::Normal;
                    self.help_scroll = 0;
                    self.changelog_scroll = 0;
                }
            }
            return;
        }
        match (key.code, key.modifiers) {
            (KeyCode::Char('c'), KeyModifiers::CONTROL) => self.running = false,
            (KeyCode::Tab, _) if self.is_split() => {
                self.active = match self.active {
                    ActivePane::Source => ActivePane::Detail,
                    ActivePane::Detail => ActivePane::Source,
                };
            }
            (KeyCode::Char(':'), _) => {
                self.mode = InputMode::Command;
                self.command_buffer.clear();
                self.error = None;
            }
            (KeyCode::Char('?'), _) => {
                self.mode = InputMode::Help;
                self.help_scroll = 0;
            }
            (KeyCode::Char('W'), _) => {
                self.mode = InputMode::Changelog;
                self.changelog_scroll = 0;
                if self.changelog.is_none() && !self.changelog_loading {
                    self.changelog_loading = true;
                    let tx = self.tx.clone();
                    tokio::spawn(async move {
                        match crate::update::fetch_changelog().await {
                            Ok(releases) => {
                                let _ = tx.send(Event::ChangelogLoaded { releases });
                            }
                            Err(e) => {
                                tracing::warn!("changelog fetch failed: {e}");
                                let _ = tx.send(Event::ChangelogLoaded {
                                    releases: Vec::new(),
                                });
                            }
                        }
                    });
                }
            }
            (KeyCode::Char('t'), KeyModifiers::NONE) => {
                self.timestamps = match self.timestamps {
                    TimestampStyle::Relative => TimestampStyle::Absolute,
                    TimestampStyle::Absolute => TimestampStyle::Relative,
                };
            }
            (KeyCode::Char('Z'), _) => {
                self.is_dark = !self.is_dark;
                let msg = if self.is_dark {
                    "theme: dark"
                } else {
                    "theme: light"
                };
                self.set_status(msg);
            }
            (KeyCode::Char(','), KeyModifiers::NONE) if self.is_split() => {
                self.split_pct = self.split_pct.saturating_sub(5).max(20);
            }
            (KeyCode::Char('.'), KeyModifiers::NONE) if self.is_split() => {
                self.split_pct = (self.split_pct + 5).min(80);
            }
            (KeyCode::Char('V'), _) => self.toggle_feed_mode(),
            (KeyCode::Char('F'), _) => self.toggle_home_mode(),
            (KeyCode::Char('M'), _) => {
                self.metrics = match self.metrics {
                    MetricsStyle::Visible => MetricsStyle::Hidden,
                    MetricsStyle::Hidden => MetricsStyle::Visible,
                };
                let msg = match self.metrics {
                    MetricsStyle::Visible => "metrics on",
                    MetricsStyle::Hidden => "metrics off",
                };
                self.set_status(msg);
                self.save_session();
            }
            (KeyCode::Char('N'), _) => {
                self.display_names = match self.display_names {
                    DisplayNameStyle::Visible => DisplayNameStyle::Hidden,
                    DisplayNameStyle::Hidden => DisplayNameStyle::Visible,
                };
                let msg = match self.display_names {
                    DisplayNameStyle::Visible => "display names on",
                    DisplayNameStyle::Hidden => "display names off (handles only)",
                };
                self.set_status(msg);
                self.save_session();
            }
            (KeyCode::Char('x'), KeyModifiers::NONE) => self.toggle_expand_selected(),
            (KeyCode::Char('I'), _) => {
                self.media_auto_expand = !self.media_auto_expand;
                if self.media_auto_expand {
                    let tweets = self.source.tweets.clone();
                    self.queue_source_media(&tweets);
                    self.set_status("media auto-expand on");
                } else {
                    self.set_status("media auto-expand off");
                }
            }
            (KeyCode::Char('X'), _) => {
                if self.active == ActivePane::Source && !self.source.is_notifications() {
                    if let Some(tweet) = self.source.tweets.get(self.source.selected()).cloned() {
                        self.mark_current_seen();
                        self.push_tweet(tweet);
                    }
                    self.toggle_inline_thread();
                } else if self.active == ActivePane::Detail {
                    self.toggle_inline_thread();
                }
            }
            (KeyCode::Char('p'), KeyModifiers::NONE) => self.open_profile(),
            (KeyCode::Char('P'), _) => self.open_own_profile_in_browser(),
            (KeyCode::Char('T'), _) => self.translate_selected(),
            (KeyCode::Char('A'), _) => self.open_ask_for_selected(),
            (KeyCode::Char('B'), _) => self.open_brief_for_target(),
            (KeyCode::Char('f'), KeyModifiers::NONE) => self.engage(EngageAction::Like),
            (KeyCode::Char('c'), KeyModifiers::NONE) => self.toggle_filter(),
            (KeyCode::Char('y'), KeyModifiers::NONE) => self.yank_url(),
            (KeyCode::Char('Y'), _) => self.yank_json(),
            (KeyCode::Char('R'), _) => self.toggle_user_replies(),
            (KeyCode::Char('L'), _) => self.show_likers_for_selected(),
            (KeyCode::Char('n'), KeyModifiers::NONE) => {
                self.switch_source(SourceKind::Notifications);
            }
            (KeyCode::Char('o'), KeyModifiers::NONE) => self.open_tweet_in_browser(),
            (KeyCode::Char('O'), _) => self.open_author_in_browser(),
            (KeyCode::Char('m'), KeyModifiers::NONE) => self.open_media_external(),
            (KeyCode::Char('q'), KeyModifiers::NONE) => self.back_out(true),
            (KeyCode::Esc, _) => self.back_out(false),
            (KeyCode::Char(']'), _) => self.history_forward(),
            (KeyCode::Char('['), _) => self.history_back(),
            _ => match self.active {
                ActivePane::Source => self.handle_key_source(key),
                ActivePane::Detail => self.handle_key_detail(key),
            },
        }
    }

    fn actor_count_for_current_notif(&self) -> Option<usize> {
        if !self.source.is_notifications() {
            return None;
        }
        let notif = self.source.notifications.get(self.source.selected())?;
        if notif.notification_type != "Follow"
            || notif.actors.len() < 2
            || !self.expanded_bodies.contains(&notif.id)
        {
            return None;
        }
        Some(notif.actors.len())
    }

    fn step_actor_cursor(&mut self, delta: isize) -> bool {
        let Some(count) = self.actor_count_for_current_notif() else {
            return false;
        };
        let current = self.notif_actor_cursor.unwrap_or(0) as isize;
        let next = current + delta;
        if next < 0 || next >= count as isize {
            return false;
        }
        self.notif_actor_cursor = Some(next as usize);
        true
    }

    fn toggle_expand_selected(&mut self) {
        if self.source.is_notifications() && self.active == ActivePane::Source {
            if let Some(notif) = self.source.notifications.get(self.source.selected()) {
                let id = notif.id.clone();
                let is_multi_follow = notif.notification_type == "Follow" && notif.actors.len() > 1;
                if !self.expanded_bodies.remove(&id) {
                    self.expanded_bodies.insert(id);
                    if is_multi_follow {
                        self.notif_actor_cursor = Some(0);
                    }
                    self.set_status("expanded");
                } else {
                    self.notif_actor_cursor = None;
                    self.set_status("collapsed");
                }
            }
            return;
        }
        let Some(tweet) = self.selected_tweet().cloned() else {
            return;
        };
        if !self.expanded_bodies.remove(&tweet.rest_id) {
            self.expanded_bodies.insert(tweet.rest_id.clone());
            self.media.ensure_tweet_media(&tweet, &self.tx);
            self.set_status("expanded");
        } else {
            self.set_status("collapsed");
        }
    }

    fn toggle_inline_thread(&mut self) {
        let Some(id) = self.selected_tweet().map(|t| t.rest_id.clone()) else {
            return;
        };
        if self.inline_threads.remove(&id).is_some() {
            self.set_status("thread collapsed");
            return;
        }
        self.expanded_bodies.insert(id.clone());
        if let Some(tweet) = self.selected_tweet().cloned() {
            self.media.ensure_tweet_media(&tweet, &self.tx);
        }
        self.inline_threads.insert(
            id.clone(),
            InlineThread {
                loading: true,
                replies: Vec::new(),
                error: None,
            },
        );
        self.set_status("loading thread…");
        let client = self.client.clone();
        let tx = self.tx.clone();
        let focal_id = id;
        tokio::spawn(async move {
            let result = focus::fetch_thread_recursive(&client, &focal_id).await;
            let _ = tx.send(Event::InlineThreadLoaded { focal_id, result });
        });
    }

    fn handle_inline_thread_loaded(&mut self, focal_id: String, result: Result<TimelinePage>) {
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

    fn selected_tweet(&self) -> Option<&Tweet> {
        match self.active {
            ActivePane::Source => {
                if self.source.is_notifications() {
                    return None;
                }
                self.source.tweets.get(self.source.selected())
            }
            ActivePane::Detail => {
                let detail = self.top_detail()?;
                detail.selected_reply().or(Some(&detail.tweet))
            }
        }
    }

    fn yank_url(&mut self) {
        let Some(tweet) = self.selected_tweet() else {
            return;
        };
        let text = tweet
            .url
            .replace("x.com/", "fixupx.com/")
            .replace("twitter.com/", "fixuptwitter.com/");
        self.copy_to_clipboard(text, "url copied");
    }

    fn yank_json(&mut self) {
        let Some(tweet) = self.selected_tweet() else {
            return;
        };
        match serde_json::to_string_pretty(tweet) {
            Ok(json) => self.copy_to_clipboard(json, "json copied"),
            Err(e) => self.error = Some(format!("serialize failed: {e}")),
        }
    }

    fn copy_to_clipboard(&mut self, text: String, note: &str) {
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

    fn toggle_feed_mode(&mut self) {
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

    fn toggle_home_mode(&mut self) {
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

    fn toggle_user_replies(&mut self) {
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

    fn cycle_reply_sort(&mut self) {
        self.reply_sort = self.reply_sort.cycle();
        if let Some(FocusEntry::Tweet(detail)) = self.focus_stack.last_mut() {
            detail.sort_replies(self.reply_sort);
        }
        self.set_status(format!("replies sorted by {}", self.reply_sort.label()));
        self.save_session();
    }

    fn open_tweet_in_browser(&mut self) {
        let Some(tweet) = self.selected_tweet() else {
            return;
        };
        self.open_url(&tweet.url.clone());
    }

    fn open_own_profile_in_browser(&mut self) {
        let Some(handle) = &self.self_handle else {
            self.set_status("own handle not resolved yet");
            return;
        };
        let url = format!("https://x.com/{handle}");
        self.open_url(&url);
    }

    fn open_author_in_browser(&mut self) {
        let Some(tweet) = self.selected_tweet() else {
            return;
        };
        let url = format!("https://x.com/{}", tweet.author.handle);
        self.open_url(&url);
    }

    fn open_media_external(&mut self) {
        let Some(tweet) = self.selected_tweet() else {
            return;
        };
        let Some(media) = tweet.media.first() else {
            self.set_status("no media on selected tweet");
            return;
        };
        self.open_url(&media.url.clone());
    }

    fn open_url(&mut self, url: &str) {
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

    fn handle_key_source(&mut self, key: KeyEvent) {
        match (key.code, key.modifiers) {
            (KeyCode::Char('j'), KeyModifiers::NONE) | (KeyCode::Down, _) => {
                if self.step_actor_cursor(1) {
                    return;
                }
                self.notif_actor_cursor = None;
                self.source.select_next();
                self.mark_current_seen();
                self.maybe_load_more();
            }
            (KeyCode::Char('k'), KeyModifiers::NONE) | (KeyCode::Up, _) => {
                if self.step_actor_cursor(-1) {
                    return;
                }
                self.notif_actor_cursor = None;
                self.source.select_prev();
                self.mark_current_seen();
            }
            (KeyCode::Char('g'), KeyModifiers::NONE) => {
                self.source.jump_top();
                self.mark_current_seen();
            }
            (KeyCode::Char('G'), KeyModifiers::NONE | KeyModifiers::SHIFT) => {
                self.source.jump_bottom();
                self.mark_current_seen();
                self.maybe_load_more();
            }
            (KeyCode::Char('r'), KeyModifiers::NONE) => self.reload_source(),
            (KeyCode::Char('u'), KeyModifiers::NONE) => self.jump_next_unread(),
            (KeyCode::Char('U'), KeyModifiers::NONE | KeyModifiers::SHIFT) => {
                self.mark_all_seen_in_source();
            }
            (KeyCode::Enter, _) | (KeyCode::Char('l'), KeyModifiers::NONE) => {
                if self.source.is_notifications() {
                    self.open_selected_notification();
                } else if let Some(tweet) = self.source.tweets.get(self.source.selected()).cloned()
                {
                    self.mark_current_seen();
                    self.push_tweet(tweet);
                }
            }
            (KeyCode::Char('d'), KeyModifiers::CONTROL) => {
                self.source.advance(10);
                self.mark_current_seen();
                self.maybe_load_more();
            }
            (KeyCode::Char('u'), KeyModifiers::CONTROL) => {
                self.source.advance(-10);
                self.mark_current_seen();
            }
            (KeyCode::Char('h'), KeyModifiers::NONE) | (KeyCode::Left, _) => {
                self.switch_source(SourceKind::Home { following: false });
            }
            _ => {}
        }
    }

    fn handle_key_detail(&mut self, key: KeyEvent) {
        match (key.code, key.modifiers) {
            (KeyCode::Char('j'), KeyModifiers::NONE) | (KeyCode::Down, _) => {
                match self.focus_stack.last_mut() {
                    Some(FocusEntry::Tweet(d)) => d.select_next(),
                    Some(FocusEntry::Likers(l)) => {
                        l.select_next();
                        self.maybe_load_more_likers();
                    }
                    Some(FocusEntry::Ask(_)) | Some(FocusEntry::Brief(_)) | None => {}
                }
            }
            (KeyCode::Char('k'), KeyModifiers::NONE) | (KeyCode::Up, _) => {
                match self.focus_stack.last_mut() {
                    Some(FocusEntry::Tweet(d)) => d.select_prev(),
                    Some(FocusEntry::Likers(l)) => l.select_prev(),
                    Some(FocusEntry::Ask(_)) | Some(FocusEntry::Brief(_)) | None => {}
                }
            }
            (KeyCode::Char('g'), KeyModifiers::NONE) => match self.focus_stack.last_mut() {
                Some(FocusEntry::Tweet(d)) => d.jump_top(),
                Some(FocusEntry::Likers(l)) => l.jump_top(),
                Some(FocusEntry::Ask(_)) | Some(FocusEntry::Brief(_)) | None => {}
            },
            (KeyCode::Char('G'), KeyModifiers::NONE | KeyModifiers::SHIFT) => {
                match self.focus_stack.last_mut() {
                    Some(FocusEntry::Tweet(d)) => d.jump_bottom(),
                    Some(FocusEntry::Likers(l)) => {
                        l.jump_bottom();
                        self.maybe_load_more_likers();
                    }
                    Some(FocusEntry::Ask(_)) | Some(FocusEntry::Brief(_)) | None => {}
                }
            }
            (KeyCode::Char('d'), KeyModifiers::CONTROL) => match self.focus_stack.last_mut() {
                Some(FocusEntry::Tweet(d)) => d.advance(10),
                Some(FocusEntry::Likers(l)) => {
                    l.advance(10);
                    self.maybe_load_more_likers();
                }
                Some(FocusEntry::Ask(_)) | Some(FocusEntry::Brief(_)) | None => {}
            },
            (KeyCode::Char('u'), KeyModifiers::CONTROL) => match self.focus_stack.last_mut() {
                Some(FocusEntry::Tweet(d)) => d.advance(-10),
                Some(FocusEntry::Likers(l)) => l.advance(-10),
                Some(FocusEntry::Ask(_)) | Some(FocusEntry::Brief(_)) | None => {}
            },
            (KeyCode::Char('h'), KeyModifiers::NONE) | (KeyCode::Left, _) => {
                self.active = ActivePane::Source;
            }
            (KeyCode::Char('s'), KeyModifiers::NONE) => self.cycle_reply_sort(),
            (KeyCode::Enter, _) | (KeyCode::Char('l'), KeyModifiers::NONE) => {
                match self.focus_stack.last() {
                    Some(FocusEntry::Tweet(_)) => {
                        if let Some(reply) =
                            self.top_detail().and_then(|d| d.selected_reply()).cloned()
                        {
                            self.push_tweet(reply);
                        }
                    }
                    Some(FocusEntry::Likers(l)) => {
                        if let Some(user) = l.selected_user().cloned() {
                            self.open_user_in_detail(user.handle, Some(user.rest_id));
                        }
                    }
                    Some(FocusEntry::Ask(_)) | Some(FocusEntry::Brief(_)) | None => {}
                }
            }
            _ => {}
        }
    }

    fn maybe_load_more_likers(&mut self) {
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

    fn handle_key_command(&mut self, key: KeyEvent) {
        match (key.code, key.modifiers) {
            (KeyCode::Esc, _) => {
                self.mode = InputMode::Normal;
                self.command_buffer.clear();
            }
            (KeyCode::Enter, _) => self.run_command_buffer(),
            (KeyCode::Backspace, _) => {
                self.command_buffer.pop();
            }
            (KeyCode::Char(c), _) => {
                self.command_buffer.push(c);
            }
            _ => {}
        }
    }

    fn run_command_buffer(&mut self) {
        let input = std::mem::take(&mut self.command_buffer);
        self.mode = InputMode::Normal;
        match command::parse(&input) {
            Ok(Command::SwitchSource(kind)) => self.switch_source(kind),
            Ok(Command::OpenTweet(id)) => self.open_tweet_by_id(id),
            Ok(Command::Quit) => self.running = false,
            Ok(Command::Help) => {
                self.status =
                    "help: j/k nav, Enter open, h back, q pop, : command, ] forward, [ back".into();
            }
            Err(e) => {
                self.error = Some(e.0);
            }
        }
    }

    fn switch_source(&mut self, kind: SourceKind) {
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

    fn replace_source(&mut self, kind: SourceKind) {
        let is_notifs = matches!(kind, SourceKind::Notifications);
        self.source = Source::new(kind);
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
        self.notif_actor_cursor = None;
        if is_notifs {
            self.fetch_notifications_source(false, false);
        } else {
            self.fetch_source(false, false);
        }
        self.save_session();
    }

    fn history_back(&mut self) {
        if self.history_cursor == 0 {
            return;
        }
        self.history_cursor -= 1;
        if let Some(kind) = self.history.get(self.history_cursor).cloned() {
            self.replace_source(kind);
        }
    }

    fn history_forward(&mut self) {
        if self.history_cursor + 1 >= self.history.len() {
            return;
        }
        self.history_cursor += 1;
        if let Some(kind) = self.history.get(self.history_cursor).cloned() {
            self.replace_source(kind);
        }
    }

    fn back_out(&mut self, can_quit: bool) {
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

    fn push_tweet(&mut self, tweet: Tweet) {
        let focal_id = tweet.rest_id.clone();
        self.media.ensure_tweet_media(&tweet, &self.tx);
        let detail = TweetDetail::new(tweet);
        self.focus_stack.push(FocusEntry::Tweet(detail));
        self.active = ActivePane::Detail;
        self.fetch_thread(focal_id);
    }

    fn open_tweet_by_id(&mut self, id: String) {
        let request_id = event::next_request_id();
        self.pending_open = Some(request_id);
        let client = self.client.clone();
        let tx = self.tx.clone();
        tokio::spawn(async move {
            let result = source::fetch_single_tweet(&client, &id).await;
            let _ = tx.send(Event::OpenTweetResolved { request_id, result });
        });
    }

    fn handle_open_tweet_resolved(&mut self, request_id: RequestId, result: Result<Tweet>) {
        if self.pending_open != Some(request_id) {
            return;
        }
        self.pending_open = None;
        match result {
            Ok(tweet) => self.push_tweet(tweet),
            Err(e) => self.error = Some(e.to_string()),
        }
    }

    fn fetch_thread(&mut self, focal_id: String) {
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

    fn handle_thread_loaded(
        &mut self,
        request_id: RequestId,
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
        self.queue_thread_media(&replies_snapshot);
    }

    fn reload_source(&mut self) {
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

    fn fetch_source(&mut self, append: bool, silent: bool) {
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
            let result = source::fetch_page(&client, &kind, cursor).await;
            let _ = tx.send(Event::TimelineLoaded {
                kind,
                result,
                append,
                silent,
            });
        });
    }

    fn handle_timeline_loaded(
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
                self.error = Some(e.to_string());
                self.clear_status();
            }
        }
    }

    fn queue_source_media(&mut self, tweets: &[Tweet]) {
        if !self.media.supported() || !self.media_auto_expand {
            return;
        }
        for t in tweets {
            self.media.ensure_tweet_media(t, &self.tx);
        }
    }

    fn queue_thread_media(&mut self, replies: &[Tweet]) {
        if !self.media.supported() {
            return;
        }
        for t in replies {
            self.media.ensure_tweet_media(t, &self.tx);
        }
    }

    fn fetch_notifications_source(&mut self, append: bool, silent: bool) {
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
            let timeout = tokio::time::Duration::from_secs(15);
            let fetch = whisper::fetch_notifications(&client, cursor.as_deref());
            let result = match tokio::time::timeout(timeout, fetch).await {
                Ok(r) => r,
                Err(_) => Err(crate::error::Error::GraphqlShape(
                    "notification fetch timed out".into(),
                )),
            };
            let _ = tx.send(Event::NotificationPageLoaded {
                result,
                append,
                silent,
            });
        });
    }

    fn handle_notification_page_loaded(
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

    fn open_selected_notification(&mut self) {
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

    fn open_user_in_detail(&mut self, handle: String, user_id: Option<String>) {
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

    fn handle_user_timeline_loaded(&mut self, result: Result<TimelinePage>) {
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

    fn show_likers_for_selected(&mut self) {
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

    fn fetch_likers_page(&mut self, tweet_id: String, cursor: Option<String>, append: bool) {
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

    fn handle_likers_page_loaded(
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
}

fn apply_conversation_view(detail: &mut TweetDetail, page: TimelinePage, scroll_to: Option<&str>) {
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

fn build_reply_tree(root_id: &str, tweets: &[Tweet]) -> Vec<(usize, Tweet)> {
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

fn filter_incoming_page(
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

fn spawn_update_check(tx: EventTx) {
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

fn init_filter_stack(
    config_dir: &std::path::Path,
    cache_dir: &std::path::Path,
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::User;
    use chrono::Utc;
    use tempfile::NamedTempFile;

    fn make_tweet(id: &str, text: &str) -> Tweet {
        Tweet {
            rest_id: id.to_string(),
            author: User {
                rest_id: "1".to_string(),
                handle: "test".to_string(),
                name: "Test".to_string(),
                verified: false,
                followers: 0,
                following: 0,
            },
            created_at: Utc::now(),
            text: text.to_string(),
            reply_count: 0,
            retweet_count: 0,
            like_count: 0,
            quote_count: 0,
            view_count: None,
            favorited: false,
            retweeted: false,
            bookmarked: false,
            lang: None,
            in_reply_to_tweet_id: None,
            quoted_tweet: None,
            media: vec![],
            url: format!("https://x.com/test/status/{id}"),
        }
    }

    fn make_page(tweets: Vec<Tweet>) -> TimelinePage {
        TimelinePage {
            tweets,
            next_cursor: None,
            top_cursor: None,
        }
    }

    fn fresh_seen() -> (NamedTempFile, SeenStore) {
        let tmp = NamedTempFile::new().unwrap();
        let store = SeenStore::open(tmp.path()).unwrap();
        (tmp, store)
    }

    #[test]
    fn filter_seen_on_home_for_you() {
        let (_tmp, mut seen) = fresh_seen();
        seen.mark_seen("1");
        seen.mark_seen("2");
        let mut page = make_page(vec![
            make_tweet("1", "old"),
            make_tweet("2", "old"),
            make_tweet("3", "new"),
        ]);
        let kind = SourceKind::Home { following: false };
        filter_incoming_page(
            &mut page,
            &kind,
            FeedMode::All,
            FilterMode::Off,
            false,
            None,
            &seen,
        );
        assert_eq!(page.tweets.len(), 1);
        assert_eq!(page.tweets[0].rest_id, "3");
    }

    #[test]
    fn filter_seen_keeps_all_when_everything_seen() {
        let (_tmp, mut seen) = fresh_seen();
        seen.mark_seen("1");
        seen.mark_seen("2");
        let mut page = make_page(vec![make_tweet("1", "a"), make_tweet("2", "b")]);
        let kind = SourceKind::Home { following: false };
        filter_incoming_page(
            &mut page,
            &kind,
            FeedMode::All,
            FilterMode::Off,
            false,
            None,
            &seen,
        );
        assert_eq!(page.tweets.len(), 2);
    }

    #[test]
    fn filter_seen_skipped_on_following() {
        let (_tmp, mut seen) = fresh_seen();
        seen.mark_seen("1");
        let mut page = make_page(vec![make_tweet("1", "seen"), make_tweet("2", "unseen")]);
        let kind = SourceKind::Home { following: true };
        filter_incoming_page(
            &mut page,
            &kind,
            FeedMode::All,
            FilterMode::Off,
            false,
            None,
            &seen,
        );
        assert_eq!(page.tweets.len(), 2);
    }

    #[test]
    fn filter_seen_skipped_on_non_home() {
        let (_tmp, mut seen) = fresh_seen();
        seen.mark_seen("1");
        let mut page = make_page(vec![make_tweet("1", "seen")]);
        let kind = SourceKind::User {
            handle: "someone".into(),
        };
        filter_incoming_page(
            &mut page,
            &kind,
            FeedMode::All,
            FilterMode::Off,
            false,
            None,
            &seen,
        );
        assert_eq!(page.tweets.len(), 1);
    }

    #[test]
    fn filter_originals_removes_replies_quotes_rts() {
        let (_tmp, seen) = fresh_seen();
        let mut reply = make_tweet("1", "replying");
        reply.in_reply_to_tweet_id = Some("0".into());
        let mut quote = make_tweet("2", "quoting");
        quote.quoted_tweet = Some(Box::new(make_tweet("99", "original")));
        let rt = make_tweet("3", "RT @someone big news");
        let original = make_tweet("4", "standalone thought");

        let mut page = make_page(vec![reply, quote, rt, original]);
        let kind = SourceKind::Home { following: false };
        filter_incoming_page(
            &mut page,
            &kind,
            FeedMode::Originals,
            FilterMode::Off,
            false,
            None,
            &seen,
        );
        assert_eq!(page.tweets.len(), 1);
        assert_eq!(page.tweets[0].rest_id, "4");
    }

    #[test]
    fn filter_originals_only_applies_to_home() {
        let (_tmp, seen) = fresh_seen();
        let mut reply = make_tweet("1", "replying");
        reply.in_reply_to_tweet_id = Some("0".into());

        let mut page = make_page(vec![reply]);
        let kind = SourceKind::User {
            handle: "someone".into(),
        };
        filter_incoming_page(
            &mut page,
            &kind,
            FeedMode::Originals,
            FilterMode::Off,
            false,
            None,
            &seen,
        );
        assert_eq!(page.tweets.len(), 1);
    }

    #[test]
    fn filter_cache_hides_tweets() {
        let (_tmp, seen) = fresh_seen();
        let cache_tmp = NamedTempFile::new().unwrap();
        let mut cache = FilterCache::open(cache_tmp.path(), "test_hash".to_string()).unwrap();
        cache.put("2", FilterDecision::Hide);
        cache.put("3", FilterDecision::Keep);

        let mut page = make_page(vec![
            make_tweet("1", "uncached"),
            make_tweet("2", "hidden"),
            make_tweet("3", "kept"),
        ]);
        let kind = SourceKind::Home { following: false };
        let hidden = filter_incoming_page(
            &mut page,
            &kind,
            FeedMode::All,
            FilterMode::On,
            true,
            Some(&cache),
            &seen,
        );
        assert_eq!(hidden, 1);
        assert_eq!(page.tweets.len(), 2);
        assert_eq!(page.tweets[0].rest_id, "1");
        assert_eq!(page.tweets[1].rest_id, "3");
    }

    #[test]
    fn filter_cache_skipped_when_filter_off() {
        let (_tmp, seen) = fresh_seen();
        let cache_tmp = NamedTempFile::new().unwrap();
        let mut cache = FilterCache::open(cache_tmp.path(), "test_hash".to_string()).unwrap();
        cache.put("1", FilterDecision::Hide);

        let mut page = make_page(vec![make_tweet("1", "should stay")]);
        let kind = SourceKind::Home { following: false };
        let hidden = filter_incoming_page(
            &mut page,
            &kind,
            FeedMode::All,
            FilterMode::Off,
            true,
            Some(&cache),
            &seen,
        );
        assert_eq!(hidden, 0);
        assert_eq!(page.tweets.len(), 1);
    }

    #[test]
    fn filter_cache_skipped_when_no_classifier() {
        let (_tmp, seen) = fresh_seen();
        let cache_tmp = NamedTempFile::new().unwrap();
        let mut cache = FilterCache::open(cache_tmp.path(), "test_hash".to_string()).unwrap();
        cache.put("1", FilterDecision::Hide);

        let mut page = make_page(vec![make_tweet("1", "should stay")]);
        let kind = SourceKind::Home { following: false };
        let hidden = filter_incoming_page(
            &mut page,
            &kind,
            FeedMode::All,
            FilterMode::On,
            false,
            Some(&cache),
            &seen,
        );
        assert_eq!(hidden, 0);
        assert_eq!(page.tweets.len(), 1);
    }

    #[test]
    fn filter_pipeline_combined() {
        let (_tmp, mut seen) = fresh_seen();
        seen.mark_seen("1");
        let cache_tmp = NamedTempFile::new().unwrap();
        let mut cache = FilterCache::open(cache_tmp.path(), "test_hash".to_string()).unwrap();
        cache.put("3", FilterDecision::Hide);

        let mut reply = make_tweet("2", "replying");
        reply.in_reply_to_tweet_id = Some("0".into());

        let mut page = make_page(vec![
            make_tweet("1", "seen"),
            reply,
            make_tweet("3", "hidden by filter"),
            make_tweet("4", "survives"),
        ]);
        let kind = SourceKind::Home { following: false };
        let hidden = filter_incoming_page(
            &mut page,
            &kind,
            FeedMode::Originals,
            FilterMode::On,
            true,
            Some(&cache),
            &seen,
        );
        assert_eq!(hidden, 1);
        assert_eq!(page.tweets.len(), 1);
        assert_eq!(page.tweets[0].rest_id, "4");
    }

    #[test]
    fn build_reply_tree_flat_replies() {
        let replies = vec![
            {
                let mut t = make_tweet("a", "first reply");
                t.in_reply_to_tweet_id = Some("root".into());
                t.created_at = Utc::now() - chrono::Duration::seconds(2);
                t
            },
            {
                let mut t = make_tweet("b", "second reply");
                t.in_reply_to_tweet_id = Some("root".into());
                t.created_at = Utc::now() - chrono::Duration::seconds(1);
                t
            },
        ];
        let tree = build_reply_tree("root", &replies);
        assert_eq!(tree.len(), 2);
        assert_eq!(tree[0].0, 0);
        assert_eq!(tree[0].1.rest_id, "b");
        assert_eq!(tree[1].0, 0);
        assert_eq!(tree[1].1.rest_id, "a");
    }

    #[test]
    fn build_reply_tree_nested() {
        let replies = vec![
            {
                let mut t = make_tweet("a", "reply to root");
                t.in_reply_to_tweet_id = Some("root".into());
                t.created_at = Utc::now();
                t
            },
            {
                let mut t = make_tweet("b", "reply to a");
                t.in_reply_to_tweet_id = Some("a".into());
                t.created_at = Utc::now();
                t
            },
        ];
        let tree = build_reply_tree("root", &replies);
        assert_eq!(tree.len(), 2);
        assert_eq!(tree[0].1.rest_id, "a");
        assert_eq!(tree[0].0, 0);
        assert_eq!(tree[1].1.rest_id, "b");
        assert_eq!(tree[1].0, 1);
    }

    #[test]
    fn build_reply_tree_empty() {
        let tree = build_reply_tree("root", &[]);
        assert!(tree.is_empty());
    }
}
