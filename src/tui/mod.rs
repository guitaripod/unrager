pub mod app;
pub mod ask;
pub mod command;
pub mod event;
pub mod filter;
pub mod focus;
pub mod media;
pub mod seen;
pub mod session;
pub mod source;
pub mod ui;
pub mod whisper;

use crate::error::Result;
use app::App;
use crossterm::event::{DisableFocusChange, EnableFocusChange};
use crossterm::execute;
use event::EventLoop;
use std::io::stdout;
use std::time::Duration;

pub async fn run() -> Result<()> {
    let is_dark = detect_is_dark();
    let mut terminal = ratatui::init();
    let _ = execute!(stdout(), EnableFocusChange);
    let result = run_inner(&mut terminal, is_dark).await;
    let _ = execute!(stdout(), DisableFocusChange);
    media::cleanup_all();
    ratatui::restore();
    result
}

fn detect_is_dark() -> bool {
    match termbg::theme(Duration::from_millis(100)) {
        Ok(termbg::Theme::Dark) => true,
        Ok(termbg::Theme::Light) => false,
        Err(_) => true,
    }
}

async fn run_inner(terminal: &mut ratatui::DefaultTerminal, is_dark: bool) -> Result<()> {
    let mut events = EventLoop::new();
    let tx = events.sender();
    let mut app = App::new(tx, is_dark).await?;
    events.start();
    app.load_initial();

    while app.running {
        let Some(event) = events.next().await else {
            break;
        };
        app.handle_event(event, terminal)?;
    }

    app.save_session();
    Ok(())
}
