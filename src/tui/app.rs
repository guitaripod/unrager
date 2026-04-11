use crate::error::Result;
use crate::tui::event::{Event, EventLoop};
use crate::tui::ui;
use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::DefaultTerminal;

pub struct App {
    pub running: bool,
    pub status: String,
    pub last_tick: std::time::Instant,
}

impl App {
    pub async fn new() -> Result<Self> {
        Ok(Self {
            running: true,
            status: "unrager TUI — press q to quit, ? for help".into(),
            last_tick: std::time::Instant::now(),
        })
    }

    pub async fn run(&mut self, terminal: &mut DefaultTerminal) -> Result<()> {
        let mut events = EventLoop::new();
        events.start();

        while self.running {
            let Some(event) = events.next().await else {
                break;
            };
            self.handle_event(event, terminal)?;
        }

        Ok(())
    }

    fn handle_event(&mut self, event: Event, terminal: &mut DefaultTerminal) -> Result<()> {
        match event {
            Event::Render => {
                terminal.draw(|frame| ui::draw(frame, self))?;
            }
            Event::Tick => {
                self.last_tick = std::time::Instant::now();
            }
            Event::Key(key) => self.handle_key(key),
            Event::Resize(_, _) => {
                terminal.draw(|frame| ui::draw(frame, self))?;
            }
            Event::Quit => self.running = false,
            Event::FocusGained | Event::FocusLost => {}
        }
        Ok(())
    }

    fn handle_key(&mut self, key: KeyEvent) {
        match (key.code, key.modifiers) {
            (KeyCode::Char('q') | KeyCode::Esc, KeyModifiers::NONE) => self.running = false,
            (KeyCode::Char('c'), KeyModifiers::CONTROL) => self.running = false,
            _ => {}
        }
    }
}
