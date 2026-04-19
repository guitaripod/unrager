use crate::state::AppState;
use dioxus::prelude::*;
use serde::{Serialize, de::DeserializeOwned};
use std::fmt;
use unrager_model::{
    NotificationsPage, ProfileView, SessionState, ThreadView, TimelinePage, Tweet, User,
};

#[derive(Debug, Clone)]
pub struct ApiError(pub String);

impl fmt::Display for ApiError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for ApiError {}

impl From<String> for ApiError {
    fn from(s: String) -> Self {
        Self(s)
    }
}

impl From<&str> for ApiError {
    fn from(s: &str) -> Self {
        Self(s.into())
    }
}

#[derive(Clone)]
pub struct Client {
    pub base_url: String,
}

pub fn use_client() -> Client {
    let state = use_context::<Signal<AppState>>();
    Client {
        base_url: state.read().server_url.clone(),
    }
}

/// Methods in this impl that are not currently called from the UI are still
/// part of the public API surface: they pair 1:1 with server routes and are
/// exposed so future pages can use them without extending this file.
#[allow(dead_code)]
impl Client {
    pub fn url(&self, path: &str) -> String {
        format!("{}{}", self.base_url.trim_end_matches('/'), path)
    }

    pub async fn get_json<T: DeserializeOwned + 'static>(&self, path: &str) -> Result<T, ApiError> {
        get_impl(&self.url(path)).await
    }

    pub async fn post_json<B: Serialize + ?Sized, T: DeserializeOwned + 'static>(
        &self,
        path: &str,
        body: &B,
    ) -> Result<T, ApiError> {
        post_impl(&self.url(path), body).await
    }

    pub async fn post_no_body<T: DeserializeOwned + 'static>(
        &self,
        path: &str,
    ) -> Result<T, ApiError> {
        post_empty_impl(&self.url(path)).await
    }

    pub async fn whoami(&self) -> Result<User, ApiError> {
        self.get_json("/api/whoami").await
    }

    pub async fn home(
        &self,
        following: bool,
        cursor: Option<&str>,
    ) -> Result<TimelinePage, ApiError> {
        let mut path = format!("/api/sources/home?following={following}");
        if let Some(c) = cursor {
            path.push_str("&cursor=");
            path.push_str(&urlencoding::encode(c));
        }
        self.get_json(&path).await
    }

    pub async fn user_tweets(
        &self,
        handle: &str,
        cursor: Option<&str>,
    ) -> Result<TimelinePage, ApiError> {
        let mut path = format!("/api/sources/user/{}", urlencoding::encode(handle));
        if let Some(c) = cursor {
            path.push_str("?cursor=");
            path.push_str(&urlencoding::encode(c));
        }
        self.get_json(&path).await
    }

    pub async fn search(
        &self,
        q: &str,
        product: &str,
        cursor: Option<&str>,
    ) -> Result<TimelinePage, ApiError> {
        let mut path = format!(
            "/api/sources/search?q={}&product={product}",
            urlencoding::encode(q)
        );
        if let Some(c) = cursor {
            path.push_str("&cursor=");
            path.push_str(&urlencoding::encode(c));
        }
        self.get_json(&path).await
    }

    pub async fn mentions(&self, cursor: Option<&str>) -> Result<TimelinePage, ApiError> {
        let mut path = String::from("/api/sources/mentions");
        if let Some(c) = cursor {
            path.push_str("?cursor=");
            path.push_str(&urlencoding::encode(c));
        }
        self.get_json(&path).await
    }

    pub async fn bookmarks(&self, q: &str, cursor: Option<&str>) -> Result<TimelinePage, ApiError> {
        let mut path = format!("/api/sources/bookmarks?q={}", urlencoding::encode(q));
        if let Some(c) = cursor {
            path.push_str("&cursor=");
            path.push_str(&urlencoding::encode(c));
        }
        self.get_json(&path).await
    }

    pub async fn notifications(&self, cursor: Option<&str>) -> Result<NotificationsPage, ApiError> {
        let mut path = String::from("/api/sources/notifications");
        if let Some(c) = cursor {
            path.push_str("?cursor=");
            path.push_str(&urlencoding::encode(c));
        }
        self.get_json(&path).await
    }

    pub async fn tweet(&self, id: &str) -> Result<Tweet, ApiError> {
        self.get_json(&format!("/api/tweet/{id}")).await
    }

    pub async fn thread(&self, id: &str) -> Result<ThreadView, ApiError> {
        self.get_json(&format!("/api/thread/{id}")).await
    }

    pub async fn profile(
        &self,
        handle: &str,
        include_replies: bool,
    ) -> Result<ProfileView, ApiError> {
        let mut path = format!("/api/profile/{}", urlencoding::encode(handle));
        if include_replies {
            path.push_str("?include_replies=true");
        }
        self.get_json(&path).await
    }

    pub async fn likers(
        &self,
        tweet_id: &str,
        cursor: Option<&str>,
    ) -> Result<LikersPage, ApiError> {
        let mut path = format!("/api/likers/{tweet_id}");
        if let Some(c) = cursor {
            path.push_str("?cursor=");
            path.push_str(&urlencoding::encode(c));
        }
        self.get_json(&path).await
    }

    pub async fn like(&self, tweet_id: &str) -> Result<serde_json::Value, ApiError> {
        self.post_no_body(&format!("/api/engage/{tweet_id}/like"))
            .await
    }

    pub async fn unlike(&self, tweet_id: &str) -> Result<serde_json::Value, ApiError> {
        self.post_no_body(&format!("/api/engage/{tweet_id}/unlike"))
            .await
    }

    pub async fn session(&self) -> Result<SessionState, ApiError> {
        self.get_json("/api/session").await
    }

    pub async fn update_session(
        &self,
        patch: &serde_json::Value,
    ) -> Result<SessionState, ApiError> {
        self.post_json_with_method("/api/session", patch, "PATCH")
            .await
    }

    pub async fn mark_seen(&self, ids: &[String]) -> Result<serde_json::Value, ApiError> {
        self.post_json("/api/seen", &serde_json::json!({ "ids": ids }))
            .await
    }

    pub async fn post_json_with_method<B: Serialize + ?Sized, T: DeserializeOwned + 'static>(
        &self,
        path: &str,
        body: &B,
        method: &str,
    ) -> Result<T, ApiError> {
        post_with_method_impl(&self.url(path), body, method).await
    }
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct LikersPage {
    #[serde(default)]
    pub users: Vec<User>,
    pub cursor: Option<String>,
}

// ---------- platform-specific fetch impls ----------

#[cfg(target_arch = "wasm32")]
async fn get_impl<T: DeserializeOwned + 'static>(url: &str) -> Result<T, ApiError> {
    use gloo_net::http::Request;
    let resp = Request::get(url)
        .send()
        .await
        .map_err(|e| ApiError(e.to_string()))?;
    if !resp.ok() {
        return Err(ApiError(format!(
            "{} {}",
            resp.status(),
            resp.status_text()
        )));
    }
    resp.json::<T>().await.map_err(|e| ApiError(e.to_string()))
}

#[cfg(target_arch = "wasm32")]
async fn post_impl<B: Serialize + ?Sized, T: DeserializeOwned + 'static>(
    url: &str,
    body: &B,
) -> Result<T, ApiError> {
    post_with_method_impl(url, body, "POST").await
}

#[cfg(target_arch = "wasm32")]
async fn post_empty_impl<T: DeserializeOwned + 'static>(url: &str) -> Result<T, ApiError> {
    use gloo_net::http::Request;
    let resp = Request::post(url)
        .send()
        .await
        .map_err(|e| ApiError(e.to_string()))?;
    if !resp.ok() {
        return Err(ApiError(format!(
            "{} {}",
            resp.status(),
            resp.status_text()
        )));
    }
    if resp.headers().get("content-length").as_deref() == Some("0") {
        return serde_json::from_value(serde_json::json!({})).map_err(|e| ApiError(e.to_string()));
    }
    resp.json::<T>().await.map_err(|e| ApiError(e.to_string()))
}

#[cfg(target_arch = "wasm32")]
async fn post_with_method_impl<B: Serialize + ?Sized, T: DeserializeOwned + 'static>(
    url: &str,
    body: &B,
    method: &str,
) -> Result<T, ApiError> {
    use gloo_net::http::Request;
    let builder = match method.to_ascii_uppercase().as_str() {
        "PATCH" => Request::patch(url),
        "PUT" => Request::put(url),
        "DELETE" => Request::delete(url),
        _ => Request::post(url),
    };
    let resp = builder
        .header("content-type", "application/json")
        .body(serde_json::to_string(body).map_err(|e| ApiError(e.to_string()))?)
        .map_err(|e| ApiError(e.to_string()))?
        .send()
        .await
        .map_err(|e| ApiError(e.to_string()))?;
    if !resp.ok() {
        return Err(ApiError(format!(
            "{} {}",
            resp.status(),
            resp.status_text()
        )));
    }
    resp.json::<T>().await.map_err(|e| ApiError(e.to_string()))
}

// ---------- native ----------

#[cfg(not(target_arch = "wasm32"))]
async fn get_impl<T: DeserializeOwned + 'static>(url: &str) -> Result<T, ApiError> {
    let resp = reqwest::get(url)
        .await
        .map_err(|e| ApiError(e.to_string()))?;
    if !resp.status().is_success() {
        return Err(ApiError(format!("HTTP {}", resp.status())));
    }
    resp.json::<T>().await.map_err(|e| ApiError(e.to_string()))
}

#[cfg(not(target_arch = "wasm32"))]
async fn post_impl<B: Serialize + ?Sized, T: DeserializeOwned + 'static>(
    url: &str,
    body: &B,
) -> Result<T, ApiError> {
    post_with_method_impl(url, body, "POST").await
}

#[cfg(not(target_arch = "wasm32"))]
async fn post_empty_impl<T: DeserializeOwned + 'static>(url: &str) -> Result<T, ApiError> {
    let resp = reqwest::Client::new()
        .post(url)
        .send()
        .await
        .map_err(|e| ApiError(e.to_string()))?;
    if !resp.status().is_success() {
        return Err(ApiError(format!("HTTP {}", resp.status())));
    }
    let bytes = resp.bytes().await.map_err(|e| ApiError(e.to_string()))?;
    if bytes.is_empty() {
        return serde_json::from_value(serde_json::json!({})).map_err(|e| ApiError(e.to_string()));
    }
    serde_json::from_slice(&bytes).map_err(|e| ApiError(e.to_string()))
}

#[cfg(not(target_arch = "wasm32"))]
async fn post_with_method_impl<B: Serialize + ?Sized, T: DeserializeOwned + 'static>(
    url: &str,
    body: &B,
    method: &str,
) -> Result<T, ApiError> {
    let method =
        reqwest::Method::from_bytes(method.as_bytes()).map_err(|e| ApiError(e.to_string()))?;
    let resp = reqwest::Client::new()
        .request(method, url)
        .json(body)
        .send()
        .await
        .map_err(|e| ApiError(e.to_string()))?;
    if !resp.status().is_success() {
        return Err(ApiError(format!("HTTP {}", resp.status())));
    }
    resp.json::<T>().await.map_err(|e| ApiError(e.to_string()))
}
