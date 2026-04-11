pub mod app;
pub mod event;
pub mod ui;

use crate::error::Result;
use app::App;

pub async fn run() -> Result<()> {
    let mut terminal = ratatui::init();
    let result = App::new().await?.run(&mut terminal).await;
    ratatui::restore();
    result
}
