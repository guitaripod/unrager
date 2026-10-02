use crate::error::Error;
use axum::Json;
use axum::http::{HeaderValue, StatusCode, header};
use axum::response::{IntoResponse, Response};
use serde_json::json;

/// An error answer, always JSON: `{"error": string, "kind": string}`, plus
/// `retry_after_secs` (and a `Retry-After` header) on a 429 and `reason` on a
/// 410. Clients branch on `kind` and status, never on the message.
#[derive(Debug)]
pub struct ApiError {
    pub status: StatusCode,
    pub kind: &'static str,
    pub message: String,
    pub retry_after_secs: Option<u64>,
    pub reason: Option<String>,
}

impl ApiError {
    pub fn new(status: StatusCode, kind: &'static str, message: impl Into<String>) -> Self {
        Self {
            status,
            kind,
            message: message.into(),
            retry_after_secs: None,
            reason: None,
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

    /// 410 `unavailable`: X knows the account or post but won't show it.
    pub fn unavailable(reason: impl Into<String>, msg: impl Into<String>) -> Self {
        Self {
            reason: Some(reason.into()),
            ..Self::new(StatusCode::GONE, "unavailable", msg)
        }
    }

    pub fn rate_limited(retry_after_secs: u64, msg: impl Into<String>) -> Self {
        Self {
            retry_after_secs: Some(retry_after_secs),
            ..Self::new(StatusCode::TOO_MANY_REQUESTS, "rate_limited", msg)
        }
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let mut body = json!({
            "error": self.message,
            "kind": self.kind,
        });
        if let Some(secs) = self.retry_after_secs {
            body["retry_after_secs"] = json!(secs);
        }
        if let Some(reason) = &self.reason {
            body["reason"] = json!(reason);
        }
        let mut response = (self.status, Json(body)).into_response();
        if let Some(secs) = self.retry_after_secs {
            response
                .headers_mut()
                .insert(header::RETRY_AFTER, HeaderValue::from(secs));
        }
        response
    }
}

impl From<Error> for ApiError {
    fn from(e: Error) -> Self {
        let message = e.to_string();
        match &e {
            Error::Config(_) | Error::BadTweetRef(_) => {
                ApiError::new(StatusCode::BAD_REQUEST, "config", message)
            }
            Error::CookieStoreMissing
            | Error::NotLoggedIn
            | Error::Keyring(_)
            | Error::PostingNotAuthorized(_) => {
                ApiError::new(StatusCode::UNAUTHORIZED, "auth", message)
            }
            Error::CreditsDepleted(_) => {
                ApiError::new(StatusCode::PAYMENT_REQUIRED, "credits", message)
            }
            Error::NotFound(_) => ApiError::not_found(message),
            Error::Unavailable { reason } => ApiError::unavailable(reason.clone(), message),
            Error::RateLimited { remaining_secs } => {
                ApiError::rate_limited(*remaining_secs, message)
            }
            Error::Offline => ApiError::new(StatusCode::SERVICE_UNAVAILABLE, "offline", message),
            Error::MissingQueryId { .. } => ApiError::new(
                StatusCode::SERVICE_UNAVAILABLE,
                "unavailable_upstream",
                message,
            ),
            Error::Http(_)
            | Error::GraphqlStatus { .. }
            | Error::GraphqlApi { .. }
            | Error::GraphqlShape(_) => ApiError::new(StatusCode::BAD_GATEWAY, "upstream", message),
            Error::CookieDecrypt(_) | Error::Sqlite(_) | Error::Io(_) | Error::Json(_) => {
                ApiError::new(StatusCode::INTERNAL_SERVER_ERROR, "internal", message)
            }
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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    async fn render(error: impl Into<ApiError>) -> (StatusCode, axum::http::HeaderMap, Value) {
        let response = error.into().into_response();
        let status = response.status();
        let headers = response.headers().clone();
        let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        (status, headers, serde_json::from_slice(&bytes).unwrap())
    }

    #[tokio::test]
    async fn a_rate_limit_says_when_to_retry() {
        let (status, headers, body) = render(Error::RateLimited {
            remaining_secs: 840,
        })
        .await;
        assert_eq!(status, StatusCode::TOO_MANY_REQUESTS);
        assert_eq!(body["kind"], "rate_limited");
        assert_eq!(body["retry_after_secs"], 840);
        assert!(body["error"].is_string());
        assert_eq!(headers[header::RETRY_AFTER], "840");
        assert!(body.get("reason").is_none());
    }

    #[tokio::test]
    async fn an_unavailable_account_carries_its_reason() {
        let (status, headers, body) = render(Error::Unavailable {
            reason: "suspended".into(),
        })
        .await;
        assert_eq!(status, StatusCode::GONE);
        assert_eq!(body["kind"], "unavailable");
        assert_eq!(body["reason"], "suspended");
        assert!(body.get("retry_after_secs").is_none());
        assert!(headers.get(header::RETRY_AFTER).is_none());
    }

    #[tokio::test]
    async fn statuses_and_kinds_for_each_error() {
        let cases = [
            (
                Error::NotFound("user @nobody".into()),
                StatusCode::NOT_FOUND,
                "not_found",
            ),
            (Error::Offline, StatusCode::SERVICE_UNAVAILABLE, "offline"),
            (
                Error::MissingQueryId {
                    operation: "Followers",
                },
                StatusCode::SERVICE_UNAVAILABLE,
                "unavailable_upstream",
            ),
            (
                Error::CreditsDepleted("402: credits depleted".into()),
                StatusCode::PAYMENT_REQUIRED,
                "credits",
            ),
            (
                Error::PostingNotAuthorized("401: access token rejected".into()),
                StatusCode::UNAUTHORIZED,
                "auth",
            ),
            (Error::NotLoggedIn, StatusCode::UNAUTHORIZED, "auth"),
            (
                Error::Config("bad".into()),
                StatusCode::BAD_REQUEST,
                "config",
            ),
            (
                Error::GraphqlShape("odd".into()),
                StatusCode::BAD_GATEWAY,
                "upstream",
            ),
        ];
        for (error, status, kind) in cases {
            let (got_status, _, body) = render(error).await;
            assert_eq!(got_status, status, "{kind}");
            assert_eq!(body["kind"], kind);
            assert!(body["error"].as_str().is_some_and(|m| !m.is_empty()));
            assert_eq!(body.as_object().unwrap().len(), 2, "{body}");
        }
    }
}
