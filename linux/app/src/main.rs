mod app;
mod card;
mod compose;
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

const APP_ID: &str = "ml.rawdog.unrager";

fn main() {
    logger::init();
    tracing::info!(target: "ui", "starting unrager-gtk");
    let settings = AppSettings::load();
    let app = RelmApp::new(APP_ID);
    app.run::<App>(settings);
}
