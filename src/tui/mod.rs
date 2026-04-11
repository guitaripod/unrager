pub mod app;
pub mod command;
pub mod event;
pub mod focus;
pub mod source;
pub mod ui;

use crate::error::Result;
use app::App;
use event::EventLoop;

pub async fn run() -> Result<()> {
    let mut terminal = ratatui::init();
    let result = run_inner(&mut terminal).await;
    ratatui::restore();
    result
}

async fn run_inner(terminal: &mut ratatui::DefaultTerminal) -> Result<()> {
    let mut events = EventLoop::new();
    let tx = events.sender();
    let mut app = App::new(tx).await?;
    events.start();
    app.load_initial();

    while app.running {
        let Some(event) = events.next().await else {
            break;
        };
        app.handle_event(event, terminal)?;
    }
    Ok(())
}
