use crate::error::Error;
use axum::Json;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use serde_json::json;

#[derive(Debug)]
pub struct ApiError {
    pub status: StatusCode,
    pub kind: &'static str,
    pub message: String,
}

impl ApiError {
    pub fn new(status: StatusCode, kind: &'static str, message: impl Into<String>) -> Self {
        Self {
            status,
            kind,
            message: message.into(),
        }
    }

    pub fn bad_request(msg: impl Into<String>) -> Self {
        Self::new(StatusCode::BAD_REQUEST, "bad_request", msg)
    }

    pub fn internal(msg: impl Into<String>) -> Self {
        Self::new(StatusCode::INTERNAL_SERVER_ERROR, "internal", msg)
    }

    pub fn not_found(msg: impl Into<String>) -> Self {
        Self::new(StatusCode::NOT_FOUND, "not_found", msg)
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let body = Json(json!({
            "error": self.message,
            "kind": self.kind,
        }));
        (self.status, body).into_response()
    }
}

impl From<Error> for ApiError {
    fn from(e: Error) -> Self {
        let message = e.to_string();
        match &e {
            Error::Config(_) | Error::BadTweetRef(_) => {
                ApiError::new(StatusCode::BAD_REQUEST, "config", message)
            }
            Error::CookieStoreMissing | Error::NotLoggedIn | Error::Keyring(_) => {
                ApiError::new(StatusCode::UNAUTHORIZED, "auth", message)
            }
            Error::RateLimited { .. } => {
                ApiError::new(StatusCode::TOO_MANY_REQUESTS, "rate_limited", message)
            }
            Error::Http(_) | Error::GraphqlStatus { .. } | Error::GraphqlShape(_) => {
                ApiError::new(StatusCode::BAD_GATEWAY, "upstream", message)
            }
            _ => ApiError::new(StatusCode::INTERNAL_SERVER_ERROR, "internal", message),
        }
    }
}

impl From<std::io::Error> for ApiError {
    fn from(e: std::io::Error) -> Self {
        ApiError::internal(e.to_string())
    }
}

impl From<serde_json::Error> for ApiError {
    fn from(e: serde_json::Error) -> Self {
        ApiError::internal(e.to_string())
    }
}
