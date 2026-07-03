//! Wire types not covered by `unrager-model`.
//!
//! The bulk of the contract (`Tweet`, `User`, `TimelinePage`, `ThreadView`,
//! `ProfileView`, `NotificationsPage`, `ComposeResult`, `SessionState`,
//! `TokenEvent`, `FilterVerdictEvent`, …) lives in `unrager-model` and is
//! re-exported here so call sites have a single `models::` namespace. Only the
//! handful of response shapes the server defines inline (and the multipart
//! upload part) are declared here, mirroring `UnragerKit/Models/Responses.swift`.

use serde::Deserialize;
use unrager_model::User;

pub use unrager_model::{
    AboutProfile, AboutStatus, AboutView, AskPreset, BriefChunk, ComposeResult, FeedMode,
    FeedStatus, FeedStatusResponse, FilterTopic, FilterVerdictEvent, Media, MediaKind,
    Notification, NotificationActor, NotificationsPage, PollOption, ProfileView, SearchProduct,
    SessionState, SourceKind, ThreadView, TimelinePage, TokenEvent, Tweet, Verdict,
};

/// `GET /api/health`. Extra `build` field is ignored.
#[derive(Debug, Clone, Deserialize)]
pub struct ServerHealth {
    pub ok: bool,
    pub name: String,
    pub version: String,
}

/// `GET /api/whoami`.
#[derive(Debug, Clone, Deserialize)]
pub struct Whoami {
    pub handle: String,
    pub rest_id: String,
    pub name: String,
}

/// `GET /api/likers/{id}`.
#[derive(Debug, Clone, Deserialize)]
pub struct LikersPage {
    #[serde(default)]
    pub users: Vec<User>,
    #[serde(default)]
    pub cursor: Option<String>,
}

/// `POST /api/engage/{id}/{like|unlike}`.
#[derive(Debug, Clone, Deserialize)]
pub struct EngageResult {
    pub ok: bool,
    #[serde(default)]
    pub idempotent: Option<bool>,
}

/// `POST /api/seen`.
#[derive(Debug, Clone, Deserialize)]
pub struct MarkSeenResult {
    pub marked: u64,
}

/// `GET /api/seen/{id}`.
#[derive(Debug, Clone, Deserialize)]
pub struct SeenCheck {
    pub id: String,
    pub seen: bool,
}

/// `GET /api/config/filter`.
#[derive(Debug, Clone, Deserialize)]
pub struct FilterConfig {
    #[serde(default)]
    pub drop_topics: Vec<String>,
    #[serde(default)]
    pub extra_guidance: String,
    #[serde(default)]
    pub ollama: Option<OllamaConfig>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct OllamaConfig {
    pub model: String,
    pub host: String,
}

/// The error JSON shape every non-2xx API response carries:
/// `{"error": "...", "kind": "..."}`.
#[derive(Debug, Clone, Deserialize)]
pub struct ServerError {
    pub error: String,
    pub kind: String,
}

impl ServerError {
    pub fn parsed_kind(&self) -> ServerErrorKind {
        ServerErrorKind::from_str(&self.kind)
    }
}

/// The machine-readable `kind` tag the server returns alongside an error body.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ServerErrorKind {
    BadRequest,
    Config,
    Auth,
    NotFound,
    RateLimited,
    Upstream,
    Internal,
    Unknown,
}

impl ServerErrorKind {
    fn from_str(raw: &str) -> Self {
        match raw {
            "bad_request" => Self::BadRequest,
            "config" => Self::Config,
            "auth" => Self::Auth,
            "not_found" => Self::NotFound,
            "rate_limited" => Self::RateLimited,
            "upstream" => Self::Upstream,
            "internal" => Self::Internal,
            _ => Self::Unknown,
        }
    }
}

/// A multipart file part for compose/reply, mirroring
/// `UnragerKit`'s `ComposeMedia`.
#[derive(Debug, Clone)]
pub struct ComposeMedia {
    pub bytes: Vec<u8>,
    pub filename: String,
    pub mime: String,
}

impl ComposeMedia {
    pub fn new(bytes: Vec<u8>, filename: impl Into<String>, mime: impl Into<String>) -> Self {
        Self {
            bytes,
            filename: filename.into(),
            mime: mime.into(),
        }
    }
}
