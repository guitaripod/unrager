use crate::cli::common;
use crate::error::Result;
use crate::gql::GqlClient;
use crate::tui::event::{Event, EventTx};
use crate::tui::source::{self, Source, SourceKind};
use crate::tui::ui;
use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::DefaultTerminal;
use std::sync::Arc;
use std::time::Instant;

pub struct App {
    pub running: bool,
    pub source: Source,
    pub status: String,
    pub error: Option<String>,
    pub last_tick: Instant,
    pub(super) client: Arc<GqlClient>,
    pub(super) tx: EventTx,
}

impl App {
    pub async fn new(tx: EventTx) -> Result<Self> {
        let client = Arc::new(common::build_gql_client().await?);
        Ok(Self {
            running: true,
            source: Source::new(SourceKind::Home { following: false }),
            status: "press ? for help, q to quit".into(),
            error: None,
            last_tick: Instant::now(),
            client,
            tx,
        })
    }

    pub fn load_initial(&mut self) {
        self.fetch(false);
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
            Event::Quit => self.running = false,
            Event::FocusGained | Event::FocusLost => {}
        }
        Ok(())
    }

    fn handle_key(&mut self, key: KeyEvent) {
        match (key.code, key.modifiers) {
            (KeyCode::Char('q'), KeyModifiers::NONE) | (KeyCode::Esc, _) => self.running = false,
            (KeyCode::Char('c'), KeyModifiers::CONTROL) => self.running = false,
            (KeyCode::Char('j'), KeyModifiers::NONE) | (KeyCode::Down, _) => {
                self.source.select_next();
                self.maybe_load_more();
            }
            (KeyCode::Char('k'), KeyModifiers::NONE) | (KeyCode::Up, _) => {
                self.source.select_prev();
            }
            (KeyCode::Char('g'), KeyModifiers::NONE) => self.source.jump_top(),
            (KeyCode::Char('G'), KeyModifiers::NONE | KeyModifiers::SHIFT) => {
                self.source.jump_bottom();
                self.maybe_load_more();
            }
            (KeyCode::Char('r'), KeyModifiers::NONE) => self.reload(),
            _ => {}
        }
    }

    fn handle_timeline_loaded(
        &mut self,
        kind: SourceKind,
        result: Result<crate::parse::timeline::TimelinePage>,
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

    fn reload(&mut self) {
        self.source.cursor = None;
        self.source.exhausted = false;
        self.fetch(false);
    }

    fn maybe_load_more(&mut self) {
        if self.source.loading
            || self.source.exhausted
            || self.source.cursor.is_none()
            || !self.source.near_bottom()
        {
            return;
        }
        self.fetch(true);
    }

    fn fetch(&mut self, append: bool) {
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
}
