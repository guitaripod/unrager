//! Cross-component shared context and routing messages.

use crate::image::ImagePipeline;
use gtk::prelude::*;
use std::sync::Arc;
use unrager_gtk_core::ApiClient;
use unrager_gtk_core::model::AskPreset;

/// A dimmed centered label used as a `ListBox` placeholder for empty feeds.
pub fn empty_placeholder(text: &str) -> gtk::Label {
    let label = gtk::Label::new(Some(text));
    label.add_css_class("dim-label");
    label.set_margin_top(64);
    label.set_margin_bottom(64);
    label
}

/// The handles every screen needs: the API client and the image cache.
#[derive(Clone)]
pub struct Ctx {
    pub api: Arc<ApiClient>,
    pub images: ImagePipeline,
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
        indices: Vec<usize>,
        start: usize,
    },
}
