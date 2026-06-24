//! Typed API errors, ported from `UnragerKit/Networking/APIError.swift`.
//! `user_message` returns the verbatim user-facing strings the Apple apps show.

use crate::models::ServerError;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ApiError {
    InvalidRequest(String),
    Network(String),
    Timeout,
    Cancelled,
    Unauthorized(String),
    Forbidden(String),
    NotFound(String),
    RateLimited(String),
    Upstream(String),
    Server { status: u16, message: String },
    Decoding(String),
    UnexpectedStatus(u16),
}

impl ApiError {
    /// Maps an HTTP status + decoded server body to a typed error.
    pub fn from_status(status: u16, body: Option<ServerError>) -> Self {
        let message = body
            .map(|b| b.error)
            .unwrap_or_else(|| format!("HTTP {status}"));
        match status {
            400 => Self::InvalidRequest(message),
            401 => Self::Unauthorized(message),
            403 => Self::Forbidden(message),
            404 => Self::NotFound(message),
            429 => Self::RateLimited(message),
            502 => Self::Upstream(message),
            500..=599 => Self::Server { status, message },
            _ => Self::UnexpectedStatus(status),
        }
    }

    pub fn from_reqwest(error: &reqwest::Error) -> Self {
        if error.is_timeout() {
            Self::Timeout
        } else {
            Self::Network(error.to_string())
        }
    }

    /// The user-facing toast string, byte-identical to the Apple apps.
    pub fn user_message(&self) -> String {
        match self {
            Self::InvalidRequest(m) => m.clone(),
            Self::Network(_) => "Can't reach the unrager server. Check the server address in Settings and that `unrager serve` is running.".to_string(),
            Self::Timeout => "The request timed out.".to_string(),
            Self::Cancelled => "Cancelled.".to_string(),
            Self::Unauthorized(_) => "The server isn't logged in to X (cookies missing or expired).".to_string(),
            Self::Forbidden(m) => m.clone(),
            Self::NotFound(m) => m.clone(),
            Self::RateLimited(_) => "X is rate-limiting requests. Try again shortly.".to_string(),
            Self::Upstream(m) => m.clone(),
            Self::Server { message, .. } => message.clone(),
            Self::Decoding(_) => "The server sent data this app couldn't read.".to_string(),
            Self::UnexpectedStatus(s) => format!("Unexpected response (HTTP {s})."),
        }
    }

    pub fn is_retryable(&self) -> bool {
        matches!(
            self,
            Self::Timeout
                | Self::Network(_)
                | Self::RateLimited(_)
                | Self::Upstream(_)
                | Self::Server { .. }
        )
    }
}

impl std::fmt::Display for ApiError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.user_message())
    }
}

impl std::error::Error for ApiError {}
