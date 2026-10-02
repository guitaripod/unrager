use crate::error::Error;
use axum::Json;
use axum::extract::Request;
use axum::http::{HeaderValue, StatusCode, header};
use axum::middleware::Next;
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

/// Rewrites every error answer that isn't already JSON (axum's own
/// rejections: a missing `q`, a malformed JSON body, a non-numeric path
/// segment, an oversized upload, an unknown route) into the same
/// `{"error", "kind"}` shape the handlers answer with, so a client can
/// decode every failure the same way.
pub async fn json_errors(request: Request, next: Next) -> Response {
    let response = next.run(request).await;
    let status = response.status();
    if !(status.is_client_error() || status.is_server_error()) || is_json(&response) {
        return response;
    }
    let (parts, body) = response.into_parts();
    let body = axum::body::to_bytes(body, PLAIN_ERROR_LIMIT)
        .await
        .map(|bytes| String::from_utf8_lossy(&bytes).trim().to_string())
        .unwrap_or_default();
    let mut json = plain_error(status, body).into_response();
    for (name, value) in &parts.headers {
        if name != header::CONTENT_TYPE && name != header::CONTENT_LENGTH {
            json.headers_mut().append(name.clone(), value.clone());
        }
    }
    json
}

const PLAIN_ERROR_LIMIT: usize = 64 * 1024;

fn is_json(response: &Response) -> bool {
    response
        .headers()
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .is_some_and(|ct| ct.starts_with("application/json"))
}

/// The JSON error for a plain-text one. A body axum couldn't read as the
/// handler's type (422) or sent without its content type (415) is a bad
/// request like any other, so both answer 400.
fn plain_error(status: StatusCode, message: String) -> ApiError {
    let message = if message.is_empty() {
        status
            .canonical_reason()
            .unwrap_or("request failed")
            .to_string()
    } else {
        message
    };
    match status {
        StatusCode::NOT_FOUND => ApiError::not_found(message),
        StatusCode::UNPROCESSABLE_ENTITY | StatusCode::UNSUPPORTED_MEDIA_TYPE => {
            ApiError::bad_request(message)
        }
        s if s.is_client_error() => ApiError::new(s, "bad_request", message),
        s => ApiError::new(s, "internal", message),
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

    #[derive(serde::Deserialize)]
    struct Search {
        #[allow(dead_code)]
        q: String,
    }

    #[derive(serde::Deserialize)]
    struct Body {
        #[allow(dead_code)]
        text: String,
    }

    async fn call(method: &str, uri: &str, json_body: Option<&str>) -> (StatusCode, Value) {
        use axum::routing::{get, post};
        use tower::Service;
        let mut app = axum::Router::new()
            .route(
                "/search",
                get(|_: axum::extract::Query<Search>| async { "ok" }),
            )
            .route("/post", post(|_: Json<Body>| async { "ok" }))
            .route(
                "/media/{id}/{index}",
                get(|_: axum::extract::Path<(String, usize)>| async { "ok" }),
            )
            .route("/fails", get(|| async { ApiError::not_found("gone") }))
            .layer(axum::middleware::from_fn(json_errors));
        let mut request = axum::http::Request::builder().method(method).uri(uri);
        if json_body.is_some() {
            request = request.header(header::CONTENT_TYPE, "application/json");
        }
        let body = json_body
            .map(|b| axum::body::Body::from(b.to_string()))
            .unwrap_or_else(axum::body::Body::empty);
        let response = app.call(request.body(body).unwrap()).await.unwrap();
        let status = response.status();
        let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        (
            status,
            serde_json::from_slice(&bytes).unwrap_or(Value::Null),
        )
    }

    #[tokio::test]
    async fn rejected_requests_answer_json() {
        for (method, uri, body) in [
            ("GET", "/search", None),
            ("GET", "/media/1/first", None),
            ("POST", "/post", Some("{not json")),
            ("POST", "/post", Some(r#"{"other": 1}"#)),
            ("POST", "/post", None),
        ] {
            let (status, json) = call(method, uri, body).await;
            assert_eq!(status, StatusCode::BAD_REQUEST, "{method} {uri} {body:?}");
            assert_eq!(json["kind"], "bad_request", "{method} {uri} {body:?}");
            assert!(json["error"].as_str().is_some_and(|m| !m.is_empty()));
        }
    }

    #[tokio::test]
    async fn unknown_routes_and_handler_errors_answer_json() {
        let (status, json) = call("GET", "/nowhere", None).await;
        assert_eq!(status, StatusCode::NOT_FOUND);
        assert_eq!(json["kind"], "not_found");
        let (status, json) = call("GET", "/fails", None).await;
        assert_eq!(status, StatusCode::NOT_FOUND);
        assert_eq!(json, json!({"error": "gone", "kind": "not_found"}));
        let (status, json) = call("DELETE", "/search?q=x", None).await;
        assert_eq!(status, StatusCode::METHOD_NOT_ALLOWED);
        assert_eq!(json["kind"], "bad_request");
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
