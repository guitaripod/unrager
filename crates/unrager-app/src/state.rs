use serde::{Deserialize, Serialize};
use std::collections::VecDeque;
use unrager_model::{FeedMode, SessionState};

#[cfg(target_arch = "wasm32")]
const STORAGE_KEY: &str = "unrager.state.v1";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppState {
    pub server_url: String,
    pub feed_mode: FeedMode,
    pub filter_enabled: bool,
    pub metrics_visible: bool,
    pub absolute_time: bool,
    pub theme: Theme,
    #[serde(skip)]
    pub toasts: VecDeque<Toast>,
    pub session: SessionState,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Theme {
    Auto,
    Light,
    Dark,
}

#[derive(Debug, Clone)]
pub struct Toast {
    pub id: u64,
    pub message: String,
    pub kind: ToastKind,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ToastKind {
    /// Low-priority informational toast. Reserved for future use (e.g. filter
    /// progress, undo hints); kept in the enum so callers don't rely on
    /// Success/Error as a binary.
    #[allow(dead_code)]
    Info,
    Success,
    Error,
}

impl Default for AppState {
    fn default() -> Self {
        Self {
            server_url: default_server_url(),
            feed_mode: FeedMode::All,
            filter_enabled: true,
            metrics_visible: true,
            absolute_time: false,
            theme: Theme::Auto,
            toasts: VecDeque::new(),
            session: SessionState::default(),
        }
    }
}

const TOAST_LIMIT: usize = 4;

impl AppState {
    pub fn load() -> Self {
        #[cfg(target_arch = "wasm32")]
        {
            use gloo_storage::{LocalStorage, Storage};
            LocalStorage::get::<Self>(STORAGE_KEY).unwrap_or_default()
        }
        #[cfg(not(target_arch = "wasm32"))]
        {
            Self::default()
        }
    }

    pub fn save(&self) {
        #[cfg(target_arch = "wasm32")]
        {
            use gloo_storage::{LocalStorage, Storage};
            let _ = LocalStorage::set(STORAGE_KEY, self);
        }
    }

    pub fn show_toast(&mut self, message: impl Into<String>, kind: ToastKind) {
        let id = next_toast_id();
        let message = message.into();
        if let Some(last) = self.toasts.back()
            && last.message == message
            && last.kind == kind
        {
            return;
        }
        self.toasts.push_back(Toast { id, message, kind });
        while self.toasts.len() > TOAST_LIMIT {
            self.toasts.pop_front();
        }
    }

    pub fn remove_toast(&mut self, id: u64) {
        self.toasts.retain(|t| t.id != id);
    }
}

fn next_toast_id() -> u64 {
    #[cfg(target_arch = "wasm32")]
    {
        js_sys::Date::now() as u64
    }
    #[cfg(not(target_arch = "wasm32"))]
    {
        use std::time::{SystemTime, UNIX_EPOCH};
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0)
    }
}

fn default_server_url() -> String {
    #[cfg(target_arch = "wasm32")]
    {
        if let Some(window) = web_sys::window()
            && let Ok(origin) = window.location().origin()
        {
            return origin;
        }
        "http://localhost:7777".into()
    }
    #[cfg(not(target_arch = "wasm32"))]
    {
        std::env::var("UNRAGER_SERVER_URL").unwrap_or_else(|_| "http://localhost:7777".into())
    }
}
