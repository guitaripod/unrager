use crate::cli::common;
use crate::config::{self, AppConfig};
use crate::error::Result;
use crate::gql::GqlClient;
use crate::model::Tweet;
use crate::parse::timeline::TimelinePage;
use crate::tui::command::{self, Command};
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
    pub translations: HashMap<String, String>,
    pub translation_inflight: HashSet<String>,
    pub reply_sort: ReplySortOrder,
    pub app_config: AppConfig,
    pub(super) client: Arc<GqlClient>,
    pub(super) tx: EventTx,
    pub(super) pending_thread: Option<RequestId>,
    pub(super) pending_open: Option<RequestId>,
    pub(super) fetch_baseline: Option<usize>,
}

pub const SPINNER_FRAMES: &[&str] = &["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];

impl App {
    pub async fn new(tx: EventTx, is_dark: bool) -> Result<Self> {
        let client = Arc::new(common::build_gql_client().await?);

        let cache_dir = config::cache_dir()?;
        let config_dir = config::config_dir()?;
        let seen = SeenStore::open(&cache_dir.join("seen.db"))?;
        let session_path = config_dir.join("session.json");

        let app_config = AppConfig::load(&config_dir);

        let (filter_cfg, filter_cache, filter_classifier) =
            init_filter_stack(&config_dir, &cache_dir);
        let filter_classifier = match filter_classifier {
            Some(c) => match c.health_check().await {
                Ok(()) => Some(c),
                Err(e) => {
                    tracing::warn!("ollama unreachable: {e} — filter disabled");
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
            translations: HashMap::new(),
            translation_inflight: HashSet::new(),
            app_config,
            client,
            tx,
            pending_thread: None,
            pending_open: None,
            fetch_baseline: None,
        })
    }

    pub fn set_status(&mut self, msg: impl Into<String>) {
        self.status = msg.into();
        self.status_until = Some(Instant::now() + Duration::from_secs(3));
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
            self.remove_tweet_by_id(&rest_id);
        }
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
            self.source.list_state.select(None);
            return;
        }
        if let Some(sel) = self.source.list_state.selected() {
            let new_sel = if idx < sel {
                sel - 1
            } else {
                sel.min(self.source.tweets.len() - 1)
            };
            self.source.list_state.select(Some(new_sel));
        }
    }

    fn mark_current_seen(&mut self) {
        if let Some(t) = self.source.tweets.get(self.source.selected()) {
            self.seen.mark_seen(&t.rest_id);
        }
    }

    fn jump_next_unread(&mut self) {
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

    fn maybe_load_more(&mut self) {
        if self.source.loading || self.source.exhausted || self.source.cursor.is_none() {
            return;
        }
        if self.source.near_bottom() {
            self.fetch_source(true);
        }
    }

    fn mark_all_seen_in_source(&mut self) {
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

    pub fn load_initial(&mut self) {
        self.fetch_source(false);
    }

    pub fn is_split(&self) -> bool {
        !self.focus_stack.is_empty()
    }

    pub fn top_detail(&self) -> Option<&TweetDetail> {
        self.focus_stack.last().map(|entry| match entry {
            FocusEntry::Tweet(d) => d,
        })
    }

    pub fn is_any_loading(&self) -> bool {
        self.source.loading
            || self.pending_thread.is_some()
            || self.pending_open.is_some()
            || self.focus_stack.last().is_some_and(|e| match e {
                FocusEntry::Tweet(d) => d.loading,
            })
    }

    pub fn handle_event(&mut self, event: Event, terminal: &mut DefaultTerminal) -> Result<()> {
        match event {
            Event::Render => {
                terminal.draw(|frame| ui::draw(frame, self))?;
                ui::emit_media_placements(self, terminal.size()?.width);
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
                terminal.draw(|frame| ui::draw(frame, self))?;
                ui::emit_media_placements(self, terminal.size()?.width);
            }
            Event::TimelineLoaded {
                kind,
                result,
                append,
            } => self.handle_timeline_loaded(kind, result, append),
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
            Event::MediaLoaded {
                url,
                id,
                id_expanded,
            } => {
                self.media.mark_ready(&url, id, id_expanded);
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
            Event::Quit => self.running = false,
            Event::FocusGained | Event::FocusLost => {}
        }
        Ok(())
    }

    fn handle_key(&mut self, key: KeyEvent) {
        if matches!(self.mode, InputMode::Command) {
            self.handle_key_command(key);
            return;
        }
        if matches!(self.mode, InputMode::Help) {
            self.mode = InputMode::Normal;
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
            }
            (KeyCode::Char('t'), KeyModifiers::NONE) => {
                self.timestamps = match self.timestamps {
                    TimestampStyle::Relative => TimestampStyle::Absolute,
                    TimestampStyle::Absolute => TimestampStyle::Relative,
                };
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
                if self.active == ActivePane::Source {
                    if let Some(tweet) = self.source.tweets.get(self.source.selected()).cloned() {
                        self.mark_current_seen();
                        self.push_tweet(tweet);
                    }
                }
                self.toggle_inline_thread();
            }
            (KeyCode::Char('p'), KeyModifiers::NONE) => self.open_profile(),
            (KeyCode::Char('P'), _) => self.open_own_profile_in_browser(),
            (KeyCode::Char('T'), _) => self.translate_selected(),
            (KeyCode::Char('c'), KeyModifiers::NONE) => self.toggle_filter(),
            (KeyCode::Char('y'), KeyModifiers::NONE) => self.yank_url(),
            (KeyCode::Char('Y'), _) => self.yank_json(),
            (KeyCode::Char('R'), _) => self.toggle_user_replies(),
            (KeyCode::Char('o'), KeyModifiers::NONE) => self.open_tweet_in_browser(),
            (KeyCode::Char('O'), _) => self.open_author_in_browser(),
            (KeyCode::Char('m'), KeyModifiers::NONE) => self.open_media_external(),
            (KeyCode::Char('q'), KeyModifiers::NONE) => self.pop_or_quit(),
            (KeyCode::Esc, _) => self.pop_or_quit(),
            (KeyCode::Char(']'), _) => self.history_forward(),
            (KeyCode::Char('['), _) => self.history_back(),
            _ => match self.active {
                ActivePane::Source => self.handle_key_source(key),
                ActivePane::Detail => self.handle_key_detail(key),
            },
        }
    }

    fn toggle_expand_selected(&mut self) {
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
        if self.media_auto_expand {
            self.queue_thread_media(&replies_snapshot);
        }
    }

    fn selected_tweet(&self) -> Option<&Tweet> {
        match self.active {
            ActivePane::Source => self.source.tweets.get(self.source.selected()),
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
                let _ = child.wait();
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
                self.source.select_next();
                self.mark_current_seen();
                self.maybe_load_more();
            }
            (KeyCode::Char('k'), KeyModifiers::NONE) | (KeyCode::Up, _) => {
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
                if let Some(tweet) = self.source.tweets.get(self.source.selected()).cloned() {
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
                if let Some(FocusEntry::Tweet(d)) = self.focus_stack.last_mut() {
                    d.select_next();
                }
            }
            (KeyCode::Char('k'), KeyModifiers::NONE) | (KeyCode::Up, _) => {
                if let Some(FocusEntry::Tweet(d)) = self.focus_stack.last_mut() {
                    d.select_prev();
                }
            }
            (KeyCode::Char('g'), KeyModifiers::NONE) => {
                if let Some(FocusEntry::Tweet(d)) = self.focus_stack.last_mut() {
                    d.jump_top();
                }
            }
            (KeyCode::Char('G'), KeyModifiers::NONE | KeyModifiers::SHIFT) => {
                if let Some(FocusEntry::Tweet(d)) = self.focus_stack.last_mut() {
                    d.jump_bottom();
                }
            }
            (KeyCode::Char('d'), KeyModifiers::CONTROL) => {
                if let Some(FocusEntry::Tweet(d)) = self.focus_stack.last_mut() {
                    d.advance(10);
                }
            }
            (KeyCode::Char('u'), KeyModifiers::CONTROL) => {
                if let Some(FocusEntry::Tweet(d)) = self.focus_stack.last_mut() {
                    d.advance(-10);
                }
            }
            (KeyCode::Char('h'), KeyModifiers::NONE) | (KeyCode::Left, _) => {
                self.active = ActivePane::Source;
            }
            (KeyCode::Char('s'), KeyModifiers::NONE) => self.cycle_reply_sort(),
            (KeyCode::Enter, _) | (KeyCode::Char('l'), KeyModifiers::NONE) => {
                if let Some(reply) = self.top_detail().and_then(|d| d.selected_reply()).cloned() {
                    self.push_tweet(reply);
                }
            }
            _ => {}
        }
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
        self.source = Source::new(kind);
        self.error = None;
        self.focus_stack.clear();
        self.active = ActivePane::Source;
        self.expanded_bodies.clear();
        self.inline_threads.clear();
        self.filter_verdicts.clear();
        self.filter_inflight.clear();
        self.filter_hidden_count = 0;
        self.translations.clear();
        self.translation_inflight.clear();
        self.fetch_source(false);
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

    fn pop_or_quit(&mut self) {
        if self.focus_stack.pop().is_some() {
            self.pending_thread = None;
            if self.focus_stack.is_empty() {
                self.active = ActivePane::Source;
            }
        } else {
            self.running = false;
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
        let replies_snapshot: Vec<Tweet> = match result {
            Ok(page) => {
                detail.apply_page(page);
                detail.sort_replies(self.reply_sort);
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
        self.source.cursor = None;
        self.source.exhausted = false;
        self.fetch_source(false);
    }

    fn fetch_source(&mut self, append: bool) {
        let Some(kind) = self.source.kind.clone() else {
            return;
        };
        if self.source.loading {
            return;
        }
        self.source.loading = true;
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
            });
        });
    }

    fn handle_timeline_loaded(
        &mut self,
        kind: SourceKind,
        result: Result<TimelinePage>,
        append: bool,
    ) {
        if self.source.kind.as_ref() != Some(&kind) {
            return;
        }
        self.source.loading = false;
        match result {
            Ok(mut page) => {
                if matches!(kind, SourceKind::Home { following: false }) {
                    let unseen: Vec<_> = page
                        .tweets
                        .iter()
                        .filter(|t| !self.seen.is_seen(&t.rest_id))
                        .cloned()
                        .collect();
                    if !unseen.is_empty() {
                        page.tweets = unseen;
                    }
                }
                if matches!(self.feed_mode, FeedMode::Originals)
                    && matches!(kind, SourceKind::Home { .. })
                {
                    page.tweets.retain(|t| {
                        t.in_reply_to_tweet_id.is_none()
                            && t.quoted_tweet.is_none()
                            && !t.text.starts_with("RT @")
                    });
                }
                if matches!(self.filter_mode, FilterMode::On) && self.filter_classifier.is_some() {
                    if let Some(cache) = &self.filter_cache {
                        let before = page.tweets.len();
                        page.tweets.retain(|t| {
                            !matches!(cache.get(&t.rest_id), Some(FilterDecision::Hide))
                        });
                        self.filter_hidden_count += before - page.tweets.len();
                    }
                }
                let old_len = self.source.tweets.len();
                if append {
                    self.source.append(page);
                } else {
                    self.source.reset_with(page);
                }
                let baseline = self.fetch_baseline.unwrap_or(0);
                if self.source.tweets.len() < baseline + 10
                    && self.source.cursor.is_some()
                    && matches!(kind, SourceKind::Home { .. })
                {
                    self.source.exhausted = false;
                    self.fetch_source(true);
                    return;
                }
                self.fetch_baseline = None;
                self.error = None;
                self.clear_status();
                let new_tweets: Vec<Tweet> = if append {
                    self.source.tweets[old_len..].to_vec()
                } else {
                    self.source.tweets.clone()
                };
                self.queue_source_media(&new_tweets);
                self.queue_filter_classification(new_tweets);
            }
            Err(e) => {
                self.error = Some(e.to_string());
                self.clear_status();
            }
        }
    }

    fn queue_source_media(&mut self, tweets: &[Tweet]) {
        if !self.media.supported || !self.media_auto_expand {
            return;
        }
        for t in tweets {
            self.media.ensure_tweet_media(t, &self.tx);
        }
    }

    fn queue_thread_media(&mut self, replies: &[Tweet]) {
        if !self.media.supported {
            return;
        }
        for t in replies {
            self.media.ensure_tweet_media(t, &self.tx);
        }
    }
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
