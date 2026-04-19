use crate::cli::common;
use crate::config::{self, AppConfig};
use crate::error::Result;
use crate::gql::GqlClient;
use crate::model::Tweet;
use crate::tui::ask;
use crate::tui::background::Background;
use crate::tui::brief::BriefView;
use crate::tui::event::{Event, EventTx};
use crate::tui::filter::{Classifier, FilterCache, FilterConfig, FilterMode, FilterState};
use crate::tui::focus::{FocusEntry, TweetDetail};
use crate::tui::media::MediaRegistry;
use crate::tui::seen::SeenStore;
use crate::tui::session::{self, SessionState};
use crate::tui::source::{Source, SourceKind};
use crate::tui::ui;
use crate::tui::whisper::{self, WhisperEntry, WhisperState};
use crate::tui::youtube::YoutubeRegistry;
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
    Leader,
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
    /// The host terminal's background brightness, captured once at startup
    /// via termbg's OSC 11 query. Frozen for the lifetime of the process —
    /// re-running termbg inside the TUI would fight crossterm's
    /// `EventStream` for stdin, so mid-session system light↔dark toggles
    /// are not auto-detected. Users whose system theme changes can work
    /// around this with `:theme x-light` / `:theme x-dark` (which flips
    /// `is_dark` and so toggles the other half of the Mordor AND gate), or
    /// restart the app to re-detect.
    pub terminal_is_dark: bool,
    pub theme_name: String,
    pub expanded_bodies: HashSet<String>,
    pub inline_threads: HashMap<String, InlineThread>,
    pub media: MediaRegistry,
    pub background: Background,
    pub(super) sound: Option<crate::tui::sound::Player>,
    pub(super) last_mordor_active: bool,
    pub youtube: YoutubeRegistry,
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
    pub filter_counted_ids: HashSet<String>,
    pub pending_classification: Vec<Tweet>,
    pub translations: HashMap<String, String>,
    pub translation_inflight: HashSet<String>,
    pub engage_inflight: HashSet<String>,
    pub liked_tweet_ids: HashSet<String>,
    pub brief_cache: HashMap<String, BriefView>,
    pub reply_sort: ReplySortOrder,
    pub app_config: AppConfig,
    pub help_scroll: u16,
    pub whisper: WhisperState,
    pub notif_seen: SeenStore,
    pub notif_unread_badge: usize,
    pub(super) client: Arc<GqlClient>,
    pub(super) tx: EventTx,
    pub(super) pending_thread: Option<crate::tui::event::RequestId>,
    pub(super) pending_open: Option<crate::tui::event::RequestId>,
    pub(super) pending_notif_scroll: Option<String>,
    pub(super) fetch_baseline: Option<usize>,
    pub update_available: Option<String>,
    pub changelog: Option<Vec<crate::update::ReleaseEntry>>,
    pub changelog_scroll: u16,
    pub changelog_loading: bool,
}

pub const SPINNER_FRAMES: &[&str] = &["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];

pub(super) const FETCH_TARGET_TWEETS: usize = 50;

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
            super::app_llm::init_filter_stack(&config_dir, &cache_dir);
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

        let theme_name = loaded
            .as_ref()
            .and_then(|s| s.theme.clone())
            .unwrap_or_else(|| app_config.theme.name.clone());
        let theme = crate::tui::theme::Theme::by_name(&theme_name, is_dark)
            .unwrap_or_else(|| crate::tui::theme::Theme::for_mode(is_dark));
        let theme_is_dark = theme.is_dark;
        crate::tui::theme::set_active(theme);

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
        super::app_fetch::spawn_update_check(tx.clone());

        let warm_client = client.clone();
        tokio::spawn(async move { warm_client.warm_transaction_key().await });

        let media = MediaRegistry::new();
        let background = Background::new();
        let sound = super::sound::Player::init(&cache_dir, &config_dir, &app_config.sound);
        if media.is_kitty() {
            // Kitty caches images across program invocations by id, so a
            // wallpaper placement from a prior dark-terminal run would
            // otherwise remain visible in a subsequent light-terminal session
            // until another program displaces it. Delete up-front; we prime
            // lazily in `update_background` once Mordor is actually active.
            background.clear_stale();
        }

        let app = Self {
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
            is_dark: theme_is_dark,
            terminal_is_dark: is_dark,
            theme_name,
            expanded_bodies: HashSet::new(),
            inline_threads: HashMap::new(),
            media,
            background,
            sound,
            last_mordor_active: false,
            youtube: YoutubeRegistry::new(),
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
            filter_counted_ids: HashSet::new(),
            pending_classification: Vec::new(),
            translations: HashMap::new(),
            translation_inflight: HashSet::new(),
            engage_inflight: HashSet::new(),
            liked_tweet_ids: HashSet::new(),
            brief_cache: HashMap::new(),
            app_config,
            help_scroll: 0,
            whisper: whisper_state,
            notif_seen,
            notif_unread_badge: 0,
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
        };
        app.apply_effective_theme();
        Ok(app)
    }

    pub fn set_status(&mut self, msg: impl Into<String>) {
        self.status = msg.into();
        self.status_until = Some(Instant::now() + Duration::from_secs(3));
    }

    pub fn rate_limit_remaining(&self) -> Option<std::time::Duration> {
        self.client.rate_limit_remaining()
    }

    pub fn read_rate_limit_remaining(&self) -> Option<std::time::Duration> {
        self.client.read_rate_limit_remaining()
    }

    pub fn write_rate_limit_remaining(&self) -> Option<std::time::Duration> {
        self.client.write_rate_limit_remaining()
    }

    pub(super) fn block_if_read_limited(&mut self) -> bool {
        if let Some(remaining) = self.read_rate_limit_remaining() {
            self.set_status(format!(
                "X cooldown on reads · wait {}",
                ui::format_countdown(remaining)
            ));
            true
        } else {
            false
        }
    }

    pub(super) fn block_if_write_limited(&mut self) -> bool {
        if let Some(remaining) = self.write_rate_limit_remaining() {
            self.set_status(format!(
                "X cooldown on writes · wait {}",
                ui::format_countdown(remaining)
            ));
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

    /// Queues every external resource a tweet needs: image thumbnails (kitty
    /// or halfblock) and YouTube oEmbed metadata. Both registries are
    /// idempotent on repeat calls.
    pub fn ensure_tweet_resources(&mut self, tweet: &Tweet) {
        self.media.ensure_tweet_media(tweet, &self.tx);
        self.youtube.ensure_tweet(tweet, &self.tx);
    }

    pub fn is_own_profile(&self) -> bool {
        match (&self.self_handle, &self.source.kind) {
            (Some(self_handle), Some(SourceKind::User { handle })) => {
                self_handle.eq_ignore_ascii_case(handle)
            }
            _ => false,
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
            theme: Some(self.theme_name.clone()),
        };
        if let Err(e) = session::save(&self.session_path, &state) {
            tracing::warn!("failed to save session: {e}");
        }
    }

    /// Install `name` as the active theme, updating `is_dark` to match
    /// the resolved variant. Returns `Err` with a human-readable message
    /// when the name is unknown. Persists via `save_session` on the caller.
    pub fn set_theme(&mut self, name: &str) -> std::result::Result<String, String> {
        let theme = crate::tui::theme::Theme::by_name(name, self.is_dark)
            .ok_or_else(|| format!("unknown theme: {name}"))?;
        let resolved_name = theme.name.to_string();
        self.is_dark = theme.is_dark;
        self.theme_name = name.trim().to_ascii_lowercase();
        self.apply_effective_theme();
        Ok(resolved_name)
    }

    /// Reconciles the active theme with the current source. Mordor-tinted
    /// accents overlay the For You feed only when *both* the chosen theme
    /// and the host terminal are dark — a light terminal would bleed cream
    /// through transparent cells, and a light theme would clash with the
    /// fiery palette. Using both signals means a runtime `:theme` switch
    /// propagates the tint live via `is_dark`, while startup termbg still
    /// guards against session/terminal mismatches (e.g. x-dark theme saved
    /// from a prior dark-terminal run, now opened in a light terminal).
    pub fn apply_effective_theme(&self) {
        let base = crate::tui::theme::Theme::by_name(&self.theme_name, self.is_dark)
            .unwrap_or_else(|| crate::tui::theme::Theme::for_mode(self.is_dark));
        let effective = if self.mordor_active() {
            crate::tui::theme::Theme::mordor_from(&base)
        } else {
            base
        };
        crate::tui::theme::set_active(effective);
    }

    /// Whether the Mordor wallpaper + fiery accent tint should currently be
    /// visible. Centralised so the theme layer (`apply_effective_theme`)
    /// and the kitty background layer (`ui::update_background`) can't
    /// disagree. Both halves of the gate must be true: the chosen theme
    /// (`is_dark`) and the terminal background (`terminal_is_dark`). The
    /// theme half updates live on `:theme`; the terminal half is frozen at
    /// startup — see the `terminal_is_dark` field for the rationale and
    /// the user-facing workaround.
    pub fn mordor_active(&self) -> bool {
        self.is_dark
            && self.terminal_is_dark
            && matches!(
                self.source.kind,
                Some(SourceKind::Home { following: false })
            )
    }

    /// Starts the opt-in ambient loop on the false→true edge of Mordor mode
    /// and stops it on the inverse edge. Cheap — safe to call on every
    /// event tick.
    fn sync_mordor_sound(&mut self) {
        let now = self.mordor_active();
        if now != self.last_mordor_active
            && let Some(player) = &self.sound
        {
            if now {
                player.start_loop();
            } else {
                player.stop_loop();
            }
        }
        self.last_mordor_active = now;
    }

    pub fn is_split(&self) -> bool {
        !self.focus_stack.is_empty()
    }

    pub fn top_detail(&self) -> Option<&TweetDetail> {
        self.focus_stack.last().and_then(|entry| match entry {
            FocusEntry::Tweet(d) => Some(d),
            FocusEntry::Likers(_)
            | FocusEntry::Notifications(_)
            | FocusEntry::Ask(_)
            | FocusEntry::Brief(_) => None,
        })
    }

    pub fn top_is_notifications(&self) -> bool {
        matches!(self.focus_stack.last(), Some(FocusEntry::Notifications(_)))
    }

    pub fn is_any_loading(&self) -> bool {
        self.source.loading
            || self.pending_thread.is_some()
            || self.pending_open.is_some()
            || self.focus_stack.last().is_some_and(|e| match e {
                FocusEntry::Tweet(d) => {
                    d.loading || d.reply_bar.as_ref().is_some_and(|b| b.sending)
                }
                FocusEntry::Likers(l) => l.loading,
                FocusEntry::Notifications(n) => n.loading,
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
                let (tw, th) = terminal.size().map(|r| (r.width, r.height))?;
                ui::emit_media_placements(self, tw);
                terminal.draw(|frame| ui::draw(frame, self))?;
                ui::update_background(self, tw, th);
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
                let (tw, th) = terminal.size().map(|r| (r.width, r.height))?;
                ui::emit_media_placements(self, tw);
                terminal.draw(|frame| ui::draw(frame, self))?;
                ui::update_background(self, tw, th);
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
            Event::YoutubeMetaLoaded { video_id, result } => {
                self.youtube.apply_result(&video_id, result);
            }
            Event::MediaOpenResult { result } => {
                self.handle_media_open_result(result);
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
            Event::NotificationPageLoaded { result, append } => {
                self.handle_notification_page_loaded(result, append);
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
            Event::WhisperPollTick => self.handle_whisper_poll_tick(),
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
            Event::ReplyResult {
                in_reply_to,
                result,
            } => {
                self.handle_reply_result(in_reply_to, result);
            }
            Event::ThreadRefreshed { focal_id, result } => {
                self.handle_thread_refreshed(focal_id, result);
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
        self.sync_mordor_sound();
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::super::app_fetch::{build_reply_tree, filter_incoming_page};
    use super::super::test_util::{dummy_app, make_page, make_tweet};
    use super::*;
    use crate::tui::filter::{FilterCache, FilterDecision};
    use chrono::Utc;
    use tempfile::NamedTempFile;

    fn fresh_seen() -> (NamedTempFile, SeenStore) {
        let tmp = NamedTempFile::new().unwrap();
        let store = SeenStore::open(tmp.path()).unwrap();
        (tmp, store)
    }

    fn off_filter(counted: &mut HashSet<String>) -> crate::tui::app_fetch::FilterContext<'_> {
        crate::tui::app_fetch::FilterContext {
            mode: FilterMode::Off,
            has_classifier: false,
            cache: None,
            counted_ids: counted,
        }
    }

    fn on_filter<'a>(
        cache: Option<&'a FilterCache>,
        has_classifier: bool,
        counted: &'a mut HashSet<String>,
    ) -> crate::tui::app_fetch::FilterContext<'a> {
        crate::tui::app_fetch::FilterContext {
            mode: FilterMode::On,
            has_classifier,
            cache,
            counted_ids: counted,
        }
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
        let mut counted = HashSet::new();
        filter_incoming_page(
            &mut page,
            &kind,
            FeedMode::All,
            &seen,
            off_filter(&mut counted),
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
        let mut counted = HashSet::new();
        filter_incoming_page(
            &mut page,
            &kind,
            FeedMode::All,
            &seen,
            off_filter(&mut counted),
        );
        assert_eq!(page.tweets.len(), 2);
    }

    #[test]
    fn filter_seen_skipped_on_following() {
        let (_tmp, mut seen) = fresh_seen();
        seen.mark_seen("1");
        let mut page = make_page(vec![make_tweet("1", "seen"), make_tweet("2", "unseen")]);
        let kind = SourceKind::Home { following: true };
        let mut counted = HashSet::new();
        filter_incoming_page(
            &mut page,
            &kind,
            FeedMode::All,
            &seen,
            off_filter(&mut counted),
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
        let mut counted = HashSet::new();
        filter_incoming_page(
            &mut page,
            &kind,
            FeedMode::All,
            &seen,
            off_filter(&mut counted),
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
        let mut counted = HashSet::new();
        filter_incoming_page(
            &mut page,
            &kind,
            FeedMode::Originals,
            &seen,
            off_filter(&mut counted),
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
        let mut counted = HashSet::new();
        filter_incoming_page(
            &mut page,
            &kind,
            FeedMode::Originals,
            &seen,
            off_filter(&mut counted),
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
        let mut counted = HashSet::new();
        let hidden = filter_incoming_page(
            &mut page,
            &kind,
            FeedMode::All,
            &seen,
            on_filter(Some(&cache), true, &mut counted),
        );
        assert_eq!(hidden, 1);
        assert_eq!(page.tweets.len(), 2);
        assert_eq!(page.tweets[0].rest_id, "1");
        assert_eq!(page.tweets[1].rest_id, "3");
    }

    #[test]
    fn filter_cache_does_not_recount_same_id() {
        let (_tmp, seen) = fresh_seen();
        let cache_tmp = NamedTempFile::new().unwrap();
        let mut cache = FilterCache::open(cache_tmp.path(), "test_hash".to_string()).unwrap();
        cache.put("hidden1", FilterDecision::Hide);
        cache.put("hidden2", FilterDecision::Hide);
        let kind = SourceKind::Home { following: true };
        let mut counted = HashSet::new();

        let mut page = make_page(vec![
            make_tweet("hidden1", "h"),
            make_tweet("hidden2", "h"),
            make_tweet("keep", "k"),
        ]);
        let first = filter_incoming_page(
            &mut page,
            &kind,
            FeedMode::All,
            &seen,
            on_filter(Some(&cache), true, &mut counted),
        );
        assert_eq!(first, 2);
        assert_eq!(counted.len(), 2);

        let mut page2 = make_page(vec![
            make_tweet("hidden1", "h"),
            make_tweet("hidden2", "h"),
            make_tweet("hidden3", "h"),
        ]);
        cache.put("hidden3", FilterDecision::Hide);
        let second = filter_incoming_page(
            &mut page2,
            &kind,
            FeedMode::All,
            &seen,
            on_filter(Some(&cache), true, &mut counted),
        );
        assert_eq!(second, 1, "already-counted ids must not increment again");
        assert_eq!(counted.len(), 3);
        assert!(page2.tweets.is_empty());
    }

    #[test]
    fn filter_cache_skipped_when_filter_off() {
        let (_tmp, seen) = fresh_seen();
        let cache_tmp = NamedTempFile::new().unwrap();
        let mut cache = FilterCache::open(cache_tmp.path(), "test_hash".to_string()).unwrap();
        cache.put("1", FilterDecision::Hide);

        let mut page = make_page(vec![make_tweet("1", "should stay")]);
        let kind = SourceKind::Home { following: false };
        let mut counted = HashSet::new();
        let hidden = filter_incoming_page(
            &mut page,
            &kind,
            FeedMode::All,
            &seen,
            crate::tui::app_fetch::FilterContext {
                mode: FilterMode::Off,
                has_classifier: true,
                cache: Some(&cache),
                counted_ids: &mut counted,
            },
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
        let mut counted = HashSet::new();
        let hidden = filter_incoming_page(
            &mut page,
            &kind,
            FeedMode::All,
            &seen,
            on_filter(Some(&cache), false, &mut counted),
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
        let mut counted = HashSet::new();
        let hidden = filter_incoming_page(
            &mut page,
            &kind,
            FeedMode::Originals,
            &seen,
            on_filter(Some(&cache), true, &mut counted),
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

    #[tokio::test]
    async fn switch_source_resets_state() {
        let (mut app, _rx, _tmp) = dummy_app();
        app.source.tweets = vec![make_tweet("1", "old")];
        app.error = Some("stale error".into());
        app.filter_hidden_count = 5;
        app.expanded_bodies.insert("1".into());

        app.switch_source(SourceKind::User {
            handle: "someone".into(),
        });

        assert!(app.source.tweets.is_empty());
        assert!(app.error.is_none());
        assert_eq!(app.filter_hidden_count, 0);
        assert!(app.expanded_bodies.is_empty());
        assert_eq!(app.active, ActivePane::Source);
        assert!(app.focus_stack.is_empty());
    }

    #[tokio::test]
    async fn switch_source_noop_when_same() {
        let (mut app, _rx, _tmp) = dummy_app();
        app.source = Source::new(SourceKind::Home { following: true });
        app.source.tweets = vec![make_tweet("1", "keep me")];

        app.switch_source(SourceKind::Home { following: true });

        assert_eq!(app.source.tweets.len(), 1);
    }

    #[tokio::test]
    async fn switch_source_pushes_history() {
        let (mut app, _rx, _tmp) = dummy_app();
        assert_eq!(app.history.len(), 1);

        app.switch_source(SourceKind::User {
            handle: "alice".into(),
        });
        assert_eq!(app.history.len(), 2);
        assert_eq!(app.history_cursor, 1);

        app.switch_source(SourceKind::User {
            handle: "bob".into(),
        });
        assert_eq!(app.history.len(), 3);
        assert_eq!(app.history_cursor, 2);
    }

    #[tokio::test]
    async fn history_back_and_forward() {
        let (mut app, _rx, _tmp) = dummy_app();
        app.switch_source(SourceKind::User {
            handle: "alice".into(),
        });
        app.switch_source(SourceKind::User {
            handle: "bob".into(),
        });
        assert_eq!(app.history_cursor, 2);

        app.history_back();
        assert_eq!(app.history_cursor, 1);
        assert!(matches!(
            app.source.kind,
            Some(SourceKind::User { ref handle }) if handle == "alice"
        ));

        app.history_forward();
        assert_eq!(app.history_cursor, 2);
        assert!(matches!(
            app.source.kind,
            Some(SourceKind::User { ref handle }) if handle == "bob"
        ));
    }

    #[tokio::test]
    async fn back_out_pops_focus_stack() {
        let (mut app, _rx, _tmp) = dummy_app();
        let tweet = make_tweet("1", "focal");
        app.push_tweet(tweet);
        assert_eq!(app.focus_stack.len(), 1);
        assert_eq!(app.active, ActivePane::Detail);

        app.back_out(false);
        assert!(app.focus_stack.is_empty());
        assert_eq!(app.active, ActivePane::Source);
    }

    #[tokio::test]
    async fn back_out_navigates_history_when_stack_empty() {
        let (mut app, _rx, _tmp) = dummy_app();
        app.switch_source(SourceKind::User {
            handle: "bob".into(),
        });
        assert!(app.focus_stack.is_empty());

        app.back_out(false);
        assert!(matches!(
            app.source.kind,
            Some(SourceKind::Home { following: true })
        ));
    }

    #[tokio::test]
    async fn handle_timeline_loaded_appends() {
        let (mut app, _rx, _tmp) = dummy_app();
        app.source = Source::new(SourceKind::Home { following: true });
        app.source.tweets = vec![make_tweet("1", "existing")];

        let page = make_page(vec![make_tweet("2", "new"), make_tweet("3", "also new")]);
        app.handle_timeline_loaded(SourceKind::Home { following: true }, Ok(page), true, false);

        assert_eq!(app.source.tweets.len(), 3);
        assert!(app.error.is_none());
    }

    #[tokio::test]
    async fn handle_timeline_loaded_replaces_on_non_append() {
        let (mut app, _rx, _tmp) = dummy_app();
        app.source = Source::new(SourceKind::Home { following: true });
        app.source.tweets = vec![make_tweet("old", "stale")];

        let page = make_page(vec![make_tweet("new", "fresh")]);
        app.handle_timeline_loaded(SourceKind::Home { following: true }, Ok(page), false, false);

        assert_eq!(app.source.tweets.len(), 1);
        assert_eq!(app.source.tweets[0].rest_id, "new");
    }

    #[tokio::test]
    async fn handle_timeline_loaded_error_sets_error() {
        let (mut app, _rx, _tmp) = dummy_app();
        app.source = Source::new(SourceKind::Home { following: true });

        app.handle_timeline_loaded(
            SourceKind::Home { following: true },
            Err(crate::error::Error::GraphqlShape("test error".into())),
            false,
            false,
        );

        assert!(app.error.is_some());
        assert!(app.error.as_ref().unwrap().contains("test error"));
    }

    #[tokio::test]
    async fn handle_timeline_loaded_ignores_stale_source() {
        let (mut app, _rx, _tmp) = dummy_app();
        app.source = Source::new(SourceKind::User {
            handle: "stranger".into(),
        });

        let page = make_page(vec![make_tweet("1", "from wrong source")]);
        app.handle_timeline_loaded(SourceKind::Home { following: true }, Ok(page), false, false);

        assert!(app.source.tweets.is_empty());
    }

    #[test]
    fn selected_tweet_from_source() {
        let (mut app, _rx, _tmp) = dummy_app();
        app.source.tweets = vec![
            make_tweet("1", "first"),
            make_tweet("2", "second"),
            make_tweet("3", "third"),
        ];
        app.source.set_selected(1);

        let selected = app.selected_tweet().unwrap();
        assert_eq!(selected.rest_id, "2");
    }

    #[test]
    fn mark_current_seen_tracks() {
        let (mut app, _rx, _tmp) = dummy_app();
        app.source.tweets = vec![make_tweet("42", "read me")];
        app.source.set_selected(0);
        assert!(!app.seen.is_seen("42"));

        app.mark_current_seen();
        assert!(app.seen.is_seen("42"));
    }

    #[tokio::test]
    async fn engage_toggles_like() {
        use crate::tui::engage::EngageAction;

        let (mut app, _rx, _tmp) = dummy_app();
        let mut tweet = make_tweet("1", "like me");
        tweet.like_count = 5;
        app.source.tweets = vec![tweet];
        app.source.set_selected(0);

        app.engage(EngageAction::Like);

        assert!(app.source.tweets[0].favorited);
        assert_eq!(app.source.tweets[0].like_count, 6);
        assert!(app.liked_tweet_ids.contains("1"));
        assert!(app.engage_inflight.contains("1"));
    }

    #[tokio::test]
    async fn toggle_feed_mode_cycles() {
        let (mut app, _rx, _tmp) = dummy_app();
        assert!(matches!(app.feed_mode, FeedMode::All));

        app.toggle_feed_mode();
        assert!(matches!(app.feed_mode, FeedMode::Originals));

        app.toggle_feed_mode();
        assert!(matches!(app.feed_mode, FeedMode::All));
    }

    #[tokio::test]
    async fn push_tweet_opens_detail() {
        let (mut app, _rx, _tmp) = dummy_app();
        assert!(app.focus_stack.is_empty());

        app.push_tweet(make_tweet("1", "focus on me"));

        assert_eq!(app.focus_stack.len(), 1);
        assert_eq!(app.active, ActivePane::Detail);
        assert!(matches!(app.focus_stack.last(), Some(FocusEntry::Tweet(_))));
    }

    #[tokio::test]
    async fn switch_source_clears_all_transient_state() {
        let (mut app, _rx, _tmp) = dummy_app();
        app.filter_verdicts
            .insert("1".into(), crate::tui::filter::FilterState::Unclassified);
        app.filter_inflight.insert("1".into());
        app.filter_counted_ids.insert("1".into());
        app.translations.insert("1".into(), "hello".into());
        app.translation_inflight.insert("1".into());
        app.engage_inflight.insert("1".into());
        app.inline_threads.insert(
            "1".into(),
            InlineThread {
                loading: false,
                replies: vec![],
                error: None,
            },
        );

        app.switch_source(SourceKind::User {
            handle: "someone".into(),
        });

        assert!(app.filter_verdicts.is_empty());
        assert!(app.filter_inflight.is_empty());
        assert!(app.filter_counted_ids.is_empty());
        assert!(app.translations.is_empty());
        assert!(app.translation_inflight.is_empty());
        assert!(app.engage_inflight.is_empty());
        assert!(app.inline_threads.is_empty());
    }

    #[tokio::test]
    async fn history_truncates_forward_on_branch() {
        let (mut app, _rx, _tmp) = dummy_app();
        app.switch_source(SourceKind::User {
            handle: "alice".into(),
        });
        app.switch_source(SourceKind::User {
            handle: "carol".into(),
        });
        assert_eq!(app.history.len(), 3);

        app.history_back();
        assert_eq!(app.history_cursor, 1);

        app.switch_source(SourceKind::User {
            handle: "bob".into(),
        });
        assert_eq!(app.history.len(), 3);
        assert_eq!(app.history_cursor, 2);
        assert!(matches!(
            app.source.kind,
            Some(SourceKind::User { ref handle }) if handle == "bob"
        ));
    }

    #[tokio::test]
    async fn back_out_quits_on_home_with_can_quit() {
        let (mut app, _rx, _tmp) = dummy_app();
        assert!(app.running);

        app.back_out(true);
        assert!(!app.running);
    }

    #[tokio::test]
    async fn back_out_preserves_remaining_stack() {
        let (mut app, _rx, _tmp) = dummy_app();
        app.push_tweet(make_tweet("1", "first"));
        app.push_tweet(make_tweet("2", "second"));
        assert_eq!(app.focus_stack.len(), 2);

        app.back_out(false);
        assert_eq!(app.focus_stack.len(), 1);
        assert_eq!(app.active, ActivePane::Detail);
    }

    #[tokio::test]
    async fn handle_timeline_loaded_clears_loading_flag() {
        let (mut app, _rx, _tmp) = dummy_app();
        app.source = Source::new(SourceKind::Home { following: true });
        app.source.loading = true;

        let page = make_page(vec![make_tweet("1", "loaded")]);
        app.handle_timeline_loaded(SourceKind::Home { following: true }, Ok(page), false, false);

        assert!(!app.source.loading);
    }

    #[tokio::test]
    async fn toggle_feed_mode_noop_on_non_home() {
        let (mut app, _rx, _tmp) = dummy_app();
        app.source = Source::new(SourceKind::User {
            handle: "someone".into(),
        });
        app.source.kind = Some(SourceKind::User {
            handle: "someone".into(),
        });
        app.feed_mode = FeedMode::All;

        app.toggle_feed_mode();

        assert!(matches!(app.feed_mode, FeedMode::All));
    }

    #[tokio::test]
    async fn engage_noop_when_already_inflight() {
        use crate::tui::engage::EngageAction;

        let (mut app, _rx, _tmp) = dummy_app();
        let mut tweet = make_tweet("1", "already liking");
        tweet.like_count = 5;
        app.source.tweets = vec![tweet];
        app.source.set_selected(0);
        app.engage_inflight.insert("1".into());

        app.engage(EngageAction::Like);

        assert!(!app.source.tweets[0].favorited);
        assert_eq!(app.source.tweets[0].like_count, 5);
    }

    #[tokio::test]
    async fn selected_tweet_from_detail_pane() {
        let (mut app, _rx, _tmp) = dummy_app();
        app.push_tweet(make_tweet("focal", "the focal tweet"));

        if let Some(FocusEntry::Tweet(detail)) = app.focus_stack.last_mut() {
            detail.replies = vec![make_tweet("r1", "reply 1"), make_tweet("r2", "reply 2")];
            detail.state.selected = 2;
        }

        let selected = app.selected_tweet().unwrap();
        assert_eq!(selected.rest_id, "r2");
    }

    #[tokio::test]
    async fn open_notifications_pushes_focus_entry() {
        let (mut app, _rx, _tmp) = dummy_app();
        assert!(app.focus_stack.is_empty());

        app.open_notifications();

        assert_eq!(app.focus_stack.len(), 1);
        assert!(matches!(
            app.focus_stack.last(),
            Some(FocusEntry::Notifications(_))
        ));
        assert_eq!(app.active, ActivePane::Detail);
    }

    #[tokio::test]
    async fn open_notifications_is_idempotent() {
        let (mut app, _rx, _tmp) = dummy_app();
        app.open_notifications();
        app.open_notifications();
        assert_eq!(app.focus_stack.len(), 1);
    }

    #[tokio::test]
    async fn space_enters_leader_mode() {
        use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
        let (mut app, _rx, _tmp) = dummy_app();
        assert_eq!(app.mode, InputMode::Normal);
        app.handle_key(KeyEvent::new(KeyCode::Char(' '), KeyModifiers::NONE));
        assert_eq!(app.mode, InputMode::Leader);
    }

    #[tokio::test]
    async fn leader_o_toggles_feed_mode_and_exits() {
        use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
        let (mut app, _rx, _tmp) = dummy_app();
        app.source = Source::new(SourceKind::Home { following: false });
        assert!(matches!(app.feed_mode, FeedMode::All));

        app.mode = InputMode::Leader;
        app.handle_key(KeyEvent::new(KeyCode::Char('o'), KeyModifiers::NONE));

        assert!(matches!(app.feed_mode, FeedMode::Originals));
        assert_eq!(app.mode, InputMode::Normal);
    }

    #[tokio::test]
    async fn leader_unmapped_key_cancels_silently() {
        use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
        let (mut app, _rx, _tmp) = dummy_app();
        app.mode = InputMode::Leader;
        let feed_before = app.feed_mode;

        app.handle_key(KeyEvent::new(KeyCode::Char('z'), KeyModifiers::NONE));

        assert_eq!(app.mode, InputMode::Normal);
        assert_eq!(app.feed_mode, feed_before);
    }
}
