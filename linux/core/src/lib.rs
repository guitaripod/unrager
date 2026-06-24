//! Headless core for the unrager GTK desktop client.
//!
//! Mirrors the Swift `UnragerKit` package: it holds the typed API client
//! (HTTP + SSE) over the byte-exact `unrager-model` wire types, the serve
//! supervisor that launches a local `unrager serve`, client settings, a
//! file logger, and the formatting helpers the UI renders with. It links no
//! GTK and is fully testable headless (`cargo test -p unrager-gtk-core`).

pub mod client;
pub mod format;
pub mod logger;
pub mod models;
pub mod serve;
pub mod settings;

pub use client::{ApiClient, ApiError, ServerErrorKind};
pub use models::{
    ComposeMedia, EngageResult, FilterConfig, LikersPage, MarkSeenResult, OllamaConfig, SeenCheck,
    ServerError, ServerHealth, Whoami,
};
pub use serve::{ServeError, ServeManager, ServeOutcome};
pub use settings::{AppSettings, AppearanceMode, FontScale, MediaSize};

pub use unrager_model as model;
