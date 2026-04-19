pub mod app;
mod app_fetch;
mod app_keys;
mod app_llm;
mod app_nav;
pub mod ask;
pub mod background;
pub mod brief;
pub mod clock;
pub mod command;
pub mod compose;
pub mod editor;
pub mod engage;
pub mod event;
pub mod external;
pub mod filter;
pub mod focus;
pub mod media;
pub mod seen;
pub mod session;
pub mod sound;
pub mod source;
#[cfg(test)]
pub(crate) mod test_util;
pub mod theme;
pub mod ui;
pub mod whisper;
pub mod youtube;

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

    if let Some(ollama) = app.filter_cfg.as_ref().map(|c| c.ollama.clone()) {
        ask::unload_blocking(&ollama).await;
    }
    app.save_session();
    Ok(())
}
