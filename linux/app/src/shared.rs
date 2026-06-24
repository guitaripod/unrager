//! Cross-component shared context and routing messages.

use crate::image::ImagePipeline;
use adw::prelude::*;
use std::cell::Cell;
use std::rc::Rc;
use std::sync::Arc;
use unrager_gtk_core::model::AskPreset;
use unrager_gtk_core::{ApiClient, MediaSize};

/// A centered spinner for the in-flight state of a data screen. Uses
/// `gtk::Spinner` (not `adw::Spinner`) so the client still builds against
/// libadwaita 1.5 — the version on Ubuntu 24.04 LTS, Debian stable and CI.
pub fn loading_state() -> gtk::Spinner {
    let spinner = gtk::Spinner::new();
    spinner.start();
    spinner.set_size_request(32, 32);
    spinner.set_halign(gtk::Align::Center);
    spinner.set_valign(gtk::Align::Center);
    spinner.set_vexpand(true);
    spinner.set_margin_top(64);
    spinner.set_margin_bottom(64);
    spinner
}

/// An `adw::StatusPage` for a genuinely-empty screen (icon + title), the
/// platform-consistent replacement for a bare dim label.
pub fn empty_state(icon: &str, title: &str) -> adw::StatusPage {
    let page = adw::StatusPage::new();
    page.set_icon_name(Some(icon));
    page.set_title(title);
    page.set_vexpand(true);
    page.add_css_class("compact");
    page
}

/// An `adw::StatusPage` for a failed load: an error icon, the message, and a
/// "Try Again" pill wired to `retry`.
pub fn error_state<F: Fn() + 'static>(message: &str, retry: F) -> adw::StatusPage {
    let page = adw::StatusPage::new();
    page.set_icon_name(Some("network-error-symbolic"));
    page.set_title("Something went wrong");
    page.set_description(Some(message));
    page.set_vexpand(true);
    page.add_css_class("compact");
    let button = gtk::Button::with_label("Try Again");
    button.add_css_class("pill");
    button.add_css_class("suggested-action");
    button.set_halign(gtk::Align::Center);
    button.connect_clicked(move |_| retry());
    page.set_child(Some(&button));
    page
}

/// The handles every screen needs: the API client, the image cache, and the
/// live media-size preference. `media_size` is a shared cell so a settings
/// change is seen by every card built afterwards (the visible feed is reloaded
/// to pick it up immediately) without rebuilding the `Ctx`.
#[derive(Clone)]
pub struct Ctx {
    pub api: Arc<ApiClient>,
    pub images: ImagePipeline,
    pub media_size: Rc<Cell<MediaSize>>,
}

/// One viewable attachment passed to the media viewer: its index within the
/// tweet's media and whether it's a video/GIF (played with `gtk::Video`) rather
/// than a still photo.
#[derive(Debug, Clone, Copy)]
pub struct MediaRef {
    pub index: usize,
    pub video: bool,
}

/// Navigation / action requests a screen raises to the app shell.
#[derive(Debug, Clone)]
pub enum Route {
    Thread(String),
    Profile(String),
    Toast(String),
    ComposeNew,
    Reply(String),
    Ask {
        tweet_id: String,
        preset: AskPreset,
    },
    Brief(String),
    Translate(String),
    Media {
        tweet_id: String,
        items: Vec<MediaRef>,
        start: usize,
    },
}
