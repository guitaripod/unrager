//! Cross-component shared context and routing messages.

use crate::image::ImagePipeline;
use adw::prelude::*;
use std::cell::Cell;
use std::rc::Rc;
use std::sync::Arc;
use unrager_gtk_core::model::AskPreset;
use unrager_gtk_core::{ApiClient, MediaSize};
use url::Url;

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
/// live display preferences. The preferences are shared cells so a settings
/// change is seen by every card built afterwards (the visible feed is rebuilt
/// to pick it up immediately) without rebuilding the `Ctx`.
///
/// The image pipeline and the "Load images" switch are private: every inline
/// load goes through the gated `load_*` methods below, so a call site cannot
/// bypass the switch.
#[derive(Clone)]
pub struct Ctx {
    pub api: Arc<ApiClient>,
    images: ImagePipeline,
    pub media_size: Rc<Cell<MediaSize>>,
    images_enabled: Rc<Cell<bool>>,
    /// Whether scrolled-past tweets are reported to the server's seen store —
    /// the "Track seen tweets" switch, mirroring iOS `markSeenEnabled`.
    pub track_seen: Rc<Cell<bool>>,
}

impl Ctx {
    pub fn new(
        api: Arc<ApiClient>,
        media_size: MediaSize,
        images_enabled: bool,
        track_seen: bool,
    ) -> Self {
        Self {
            api,
            images: ImagePipeline::new(),
            media_size: Rc::new(Cell::new(media_size)),
            images_enabled: Rc::new(Cell::new(images_enabled)),
            track_seen: Rc::new(Cell::new(track_seen)),
        }
    }

    /// Whether inline avatars/media download at all — the "Load images"
    /// switch, mirroring the Apple apps' `AppSettings.imagesEnabled` gate.
    /// Read it only for layout decisions (e.g. whether a thumbnail slot
    /// exists); the loaders below already enforce it for network fetches.
    pub fn images_enabled(&self) -> bool {
        self.images_enabled.get()
    }

    pub fn set_images_enabled(&self, enabled: bool) {
        self.images_enabled.set(enabled);
    }

    /// Loads a user's avatar URL into an `adw::Avatar`, honoring the "Load
    /// images" switch; a missing or unparseable URL leaves the initials
    /// placeholder.
    pub fn load_avatar(&self, avatar: &adw::Avatar, url: Option<&str>) {
        if !self.images_enabled.get() {
            return;
        }
        if let Some(url) = url.and_then(|u| Url::parse(u).ok()) {
            self.images.load_avatar(avatar, self.api.clone(), url);
        }
    }

    /// Loads inline media into a `gtk::Picture`, honoring the "Load images"
    /// switch.
    pub fn load_picture(&self, picture: &gtk::Picture, url: Url) {
        if self.images_enabled.get() {
            self.images.load(picture, self.api.clone(), url);
        }
    }

    /// Loads a small fixed thumbnail into a `gtk::Image`, honoring the "Load
    /// images" switch.
    pub fn load_thumbnail(&self, image: &gtk::Image, url: Url) {
        if self.images_enabled.get() {
            self.images.load_image(image, self.api.clone(), url);
        }
    }

    /// Loads a full-size image the user explicitly asked to view (the media
    /// viewer). Deliberately not gated: the switch controls inline downloads,
    /// not user-initiated viewing.
    pub fn load_media_view(&self, picture: &gtk::Picture, url: Url) {
        self.images.load(picture, self.api.clone(), url);
    }
}

/// A monotonic staleness token for in-flight fetches: `bump()` before spawning
/// a fetch that supersedes everything in flight, stamp the spawned command with
/// `current()`, and drop results whose stamp fails `is_current()` — so a page
/// from before a reload/mode-toggle can't mix into the newer content.
#[derive(Debug, Default)]
pub struct FetchGeneration(u64);

impl FetchGeneration {
    /// Invalidates every fetch in flight and returns the new generation.
    pub fn bump(&mut self) -> u64 {
        self.0 += 1;
        self.0
    }

    /// The stamp to attach to a fetch spawned now.
    pub fn current(&self) -> u64 {
        self.0
    }

    /// Whether a result stamped with `stamp` is still the latest fetch.
    pub fn is_current(&self, stamp: u64) -> bool {
        self.0 == stamp
    }
}

/// One viewable attachment passed to the media viewer: its index within the
/// tweet's media and whether it's a video/GIF (played with `gtk::Video`) rather
/// than a still photo.
#[derive(Debug, Clone, Copy)]
pub struct MediaRef {
    pub index: usize,
    pub video: bool,
}

#[cfg(test)]
mod tests {
    use super::FetchGeneration;

    #[test]
    fn a_fresh_stamp_is_current_until_the_next_bump() {
        let mut generation = FetchGeneration::default();
        let stamp = generation.bump();
        assert_eq!(stamp, generation.current());
        assert!(generation.is_current(stamp));
        generation.bump();
        assert!(!generation.is_current(stamp));
    }

    #[test]
    fn bump_supersedes_a_stamp_taken_from_current() {
        let mut generation = FetchGeneration::default();
        generation.bump();
        let in_flight = generation.current();
        let newer = generation.bump();
        assert!(!generation.is_current(in_flight));
        assert!(generation.is_current(newer));
    }
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
