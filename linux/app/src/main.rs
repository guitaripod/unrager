mod app;
mod aspect;
mod card;
mod compose;
mod desktop;
mod feed;
mod image;
mod media_viewer;
mod notifications;
mod profile;
mod settings_page;
mod shared;
mod stream_sheet;
mod thread;

use app::App;
use relm4::prelude::*;
use unrager_gtk_core::{AppSettings, logger};

fn main() {
    logger::init();
    tracing::info!(target: "ui", "starting unrager-gtk");
    if let Some(path) = logger::log_file_path() {
        tracing::info!(target: "ui", "log file: {}", path.display());
    }
    desktop::install();
    let settings = AppSettings::load();
    let app = RelmApp::new(desktop::APP_ID);
    app.run::<App>(settings);
}
