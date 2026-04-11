use crate::cli::common;
use crate::config;
use crate::error::Result;
use crate::gql::GqlClient;
use crate::model::Tweet;
use crate::parse::timeline::TimelinePage;
use crate::tui::command::{self, Command};
use crate::tui::event::{self, Event, EventTx, RequestId};
use crate::tui::focus::{self, FocusEntry, TweetDetail};
use crate::tui::seen::SeenStore;
use crate::tui::session::{self, SessionState};
use crate::tui::source::{self, Source, SourceKind};
use crate::tui::ui;
use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::DefaultTerminal;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Instant;

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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TimestampStyle {
    Absolute,
    Relative,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MetricsStyle {
    Visible,
    Hidden,
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
    pub error: Option<String>,
    pub last_tick: Instant,
    pub seen: SeenStore,
    pub session_path: PathBuf,
    pub timestamps: TimestampStyle,
    pub metrics: MetricsStyle,
    pub(super) client: Arc<GqlClient>,
    pub(super) tx: EventTx,
    pub(super) pending_thread: Option<RequestId>,
    pub(super) pending_open: Option<RequestId>,
}

impl App {
    pub async fn new(tx: EventTx) -> Result<Self> {
        let client = Arc::new(common::build_gql_client().await?);

        let cache_dir = config::cache_dir()?;
        let config_dir = config::config_dir()?;
        let seen = SeenStore::open(&cache_dir.join("seen.db"))?;
        let session_path = config_dir.join("session.json");

        let (initial_kind, initial_selected) = session::load(&session_path)
            .map(|s| (s.source_kind, s.selected))
            .unwrap_or_else(|| (SourceKind::Home { following: false }, 0));

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
            status: "press ? for help, : for command, q to quit".into(),
            error: None,
            last_tick: Instant::now(),
            seen,
            session_path,
            timestamps: TimestampStyle::Relative,
            metrics: MetricsStyle::Visible,
            client,
            tx,
            pending_thread: None,
            pending_open: None,
        })
    }

    pub fn save_session(&self) {
        let Some(kind) = self.source.kind.clone() else {
            return;
        };
        let state = SessionState {
            source_kind: kind,
            selected: self.source.selected(),
        };
        if let Err(e) = session::save(&self.session_path, &state) {
            tracing::warn!("failed to save session: {e}");
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
        self.status = "no more unread tweets in this source".into();
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
        self.status = format!("marked {n} tweets as read");
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

    pub fn handle_event(&mut self, event: Event, terminal: &mut DefaultTerminal) -> Result<()> {
        match event {
            Event::Render => {
                terminal.draw(|frame| ui::draw(frame, self))?;
            }
            Event::Tick => {
                self.last_tick = Instant::now();
            }
            Event::Key(key) => self.handle_key(key),
            Event::Resize(_, _) => {
                terminal.draw(|frame| ui::draw(frame, self))?;
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
            (KeyCode::Char('F'), _) => self.toggle_home_mode(),
            (KeyCode::Char('M'), _) => {
                self.metrics = match self.metrics {
                    MetricsStyle::Visible => MetricsStyle::Hidden,
                    MetricsStyle::Hidden => MetricsStyle::Visible,
                };
                self.status = match self.metrics {
                    MetricsStyle::Visible => "metrics on".into(),
                    MetricsStyle::Hidden => "metrics off".into(),
                };
            }
            (KeyCode::Char('y'), KeyModifiers::NONE) => self.yank_url(),
            (KeyCode::Char('Y'), _) => self.yank_json(),
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

    fn selected_tweet(&self) -> Option<&Tweet> {
        match self.active {
            ActivePane::Source => self.source.tweets.get(self.source.selected()),
            ActivePane::Detail => {
                let detail = self.top_detail()?;
                if detail.replies.is_empty() {
                    Some(&detail.tweet)
                } else {
                    detail
                        .replies
                        .get(detail.selected())
                        .or(Some(&detail.tweet))
                }
            }
        }
    }

    fn yank_url(&mut self) {
        let Some(tweet) = self.selected_tweet() else {
            return;
        };
        let text = tweet.url.clone();
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
        match arboard::Clipboard::new().and_then(|mut c| c.set_text(text)) {
            Ok(()) => self.status = note.to_string(),
            Err(e) => self.error = Some(format!("clipboard failed: {e}")),
        }
    }

    fn toggle_home_mode(&mut self) {
        let current_following =
            matches!(self.source.kind, Some(SourceKind::Home { following: true }));
        let current_is_home = matches!(self.source.kind, Some(SourceKind::Home { .. }));
        if !current_is_home {
            self.status = "F only toggles on home source; use :user etc for others".into();
            return;
        }
        self.switch_source(SourceKind::Home {
            following: !current_following,
        });
    }

    fn open_media_external(&mut self) {
        let Some(tweet) = self.selected_tweet() else {
            return;
        };
        let Some(media) = tweet.media.first() else {
            self.status = "no media on selected tweet".into();
            return;
        };
        let url = media.url.clone();
        let result = std::process::Command::new("xdg-open")
            .arg(&url)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn();
        match result {
            Ok(_) => self.status = format!("opened {url}"),
            Err(e) => self.error = Some(format!("xdg-open failed: {e}")),
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
            (KeyCode::Char('h'), KeyModifiers::NONE) | (KeyCode::Left, _) => {
                self.active = ActivePane::Source;
            }
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
        match result {
            Ok(page) => detail.apply_page(page),
            Err(e) => {
                detail.loading = false;
                detail.error = Some(e.to_string());
            }
        }
    }

    fn reload_source(&mut self) {
        self.source.cursor = None;
        self.source.exhausted = false;
        self.fetch_source(false);
    }

    fn maybe_load_more(&mut self) {
        if self.source.loading
            || self.source.exhausted
            || self.source.cursor.is_none()
            || !self.source.near_bottom()
        {
            return;
        }
        self.fetch_source(true);
    }

    fn fetch_source(&mut self, append: bool) {
        let Some(kind) = self.source.kind.clone() else {
            return;
        };
        if self.source.loading {
            return;
        }
        self.source.loading = true;
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
            Ok(page) => {
                if append {
                    self.source.append(page);
                } else {
                    self.source.reset_with(page);
                }
                self.error = None;
            }
            Err(e) => {
                self.error = Some(e.to_string());
            }
        }
    }
}
