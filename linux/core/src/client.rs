//! Typed HTTP/SSE client for the unrager server API.
//!
//! A faithful Rust port of `UnragerKit/Networking/APIClient.swift`: every
//! request method maps to a `/api/*` route, decodes into the `unrager-model`
//! wire types (or the gap structs in [`crate::models`]), and surfaces a typed
//! [`ApiError`]. The base URL lives behind a lock so Settings / the serve
//! supervisor can repoint the client at a different server at runtime.

mod error;
mod multipart;
mod sse;

pub use crate::models::ServerErrorKind;
pub use error::ApiError;

use crate::models::{
    AboutView, AskPreset, ComposeMedia, ComposeResult, EngageResult, FeedStatusResponse,
    FilterConfig, FilterVerdictEvent, LikersPage, MarkSeenResult, NotificationsPage, ProfileView,
    SearchProduct, SeenCheck, ServerError, ServerHealth, SessionState, ThreadView, TimelinePage,
    TokenEvent, Tweet, Whoami,
};
use futures::{Stream, StreamExt};
use reqwest::Client;
use serde::de::DeserializeOwned;
use std::sync::{Arc, RwLock};
use std::time::Duration;
use url::Url;

type Query<'a> = [(&'a str, String)];

#[derive(Clone)]
pub struct ApiClient {
    http: Client,
    sse_http: Client,
    base: Arc<RwLock<Url>>,
}

impl ApiClient {
    pub fn new(base: Url) -> Self {
        let http = Client::builder()
            .connect_timeout(Duration::from_secs(20))
            .timeout(Duration::from_secs(20))
            .build()
            .expect("failed to build reqwest client");
        let sse_http = Client::builder()
            .connect_timeout(Duration::from_secs(20))
            .build()
            .expect("failed to build reqwest sse client");
        Self {
            http,
            sse_http,
            base: Arc::new(RwLock::new(base)),
        }
    }

    pub fn base_url(&self) -> Url {
        self.base.read().expect("base url lock").clone()
    }

    pub fn set_base_url(&self, url: Url) {
        *self.base.write().expect("base url lock") = url;
    }

    // MARK: - Health / Whoami

    pub async fn health(&self) -> Result<ServerHealth, ApiError> {
        self.get(self.build(&["api", "health"], &[])?).await
    }

    pub async fn whoami(&self) -> Result<Whoami, ApiError> {
        self.get(self.build(&["api", "whoami"], &[])?).await
    }

    // MARK: - Timelines / Sources

    pub async fn home(
        &self,
        following: bool,
        originals: bool,
        cursor: Option<&str>,
        count: Option<u32>,
    ) -> Result<TimelinePage, ApiError> {
        let mut query = vec![("following", bool_str(following))];
        if originals {
            query.push(("mode", "originals".to_string()));
        }
        append_page(&mut query, cursor, count);
        self.get(self.build(&["api", "sources", "home"], &query)?)
            .await
    }

    pub async fn user_timeline(
        &self,
        handle: &str,
        cursor: Option<&str>,
        count: Option<u32>,
    ) -> Result<TimelinePage, ApiError> {
        let mut query = vec![];
        append_page(&mut query, cursor, count);
        self.get(self.build(&["api", "sources", "user", handle], &query)?)
            .await
    }

    pub async fn search(
        &self,
        q: &str,
        product: SearchProduct,
        cursor: Option<&str>,
        count: Option<u32>,
    ) -> Result<TimelinePage, ApiError> {
        let mut query = vec![
            ("q", q.to_string()),
            ("product", product.as_api().to_string()),
        ];
        append_page(&mut query, cursor, count);
        self.get(self.build(&["api", "sources", "search"], &query)?)
            .await
    }

    pub async fn mentions(
        &self,
        cursor: Option<&str>,
        count: Option<u32>,
    ) -> Result<TimelinePage, ApiError> {
        let mut query = vec![];
        append_page(&mut query, cursor, count);
        self.get(self.build(&["api", "sources", "mentions"], &query)?)
            .await
    }

    pub async fn bookmarks(
        &self,
        q: &str,
        cursor: Option<&str>,
        count: Option<u32>,
    ) -> Result<TimelinePage, ApiError> {
        let mut query = vec![("q", q.to_string())];
        append_page(&mut query, cursor, count);
        self.get(self.build(&["api", "sources", "bookmarks"], &query)?)
            .await
    }

    pub async fn notifications(&self, cursor: Option<&str>) -> Result<NotificationsPage, ApiError> {
        let mut query = vec![];
        if let Some(c) = cursor {
            query.push(("cursor", c.to_string()));
        }
        self.get(self.build(&["api", "sources", "notifications"], &query)?)
            .await
    }

    /// Freshness of the materialized Home buffer (per variant), for the
    /// "updated Nm ago" indicator.
    pub async fn feed_status(&self) -> Result<FeedStatusResponse, ApiError> {
        self.get(self.build(&["api", "feed", "status"], &[])?).await
    }

    // MARK: - Tweets / Threads

    pub async fn tweet(&self, id: &str) -> Result<Tweet, ApiError> {
        self.get(self.build(&["api", "tweet", id], &[])?).await
    }

    pub async fn thread(&self, id: &str, cursor: Option<&str>) -> Result<ThreadView, ApiError> {
        let mut query = vec![];
        if let Some(c) = cursor {
            query.push(("cursor", c.to_string()));
        }
        self.get(self.build(&["api", "thread", id], &query)?).await
    }

    // MARK: - Profiles / Likers

    pub async fn profile(
        &self,
        handle: &str,
        include_replies: bool,
    ) -> Result<ProfileView, ApiError> {
        let mut query = vec![];
        if include_replies {
            query.push(("include_replies", "true".to_string()));
        }
        self.get(self.build(&["api", "profile", handle], &query)?)
            .await
    }

    pub async fn likers(
        &self,
        tweet_id: &str,
        cursor: Option<&str>,
    ) -> Result<LikersPage, ApiError> {
        let mut query = vec![];
        if let Some(c) = cursor {
            query.push(("cursor", c.to_string()));
        }
        self.get(self.build(&["api", "likers", tweet_id], &query)?)
            .await
    }

    /// A user's about-account block with the server-derived country flag.
    /// `status` distinguishes a usable answer (`resolved`/`none`, cacheable
    /// for the session) from `deferred` (rate-limited upstream — retry later,
    /// never cache).
    pub async fn about(&self, rest_id: &str, screen_name: &str) -> Result<AboutView, ApiError> {
        self.get(self.build(
            &["api", "about", rest_id],
            &[("screen_name", screen_name.to_string())],
        )?)
        .await
    }

    // MARK: - Engage

    pub async fn like(&self, tweet_id: &str) -> Result<EngageResult, ApiError> {
        self.post_empty(self.build(&["api", "engage", tweet_id, "like"], &[])?)
            .await
    }

    pub async fn unlike(&self, tweet_id: &str) -> Result<EngageResult, ApiError> {
        self.post_empty(self.build(&["api", "engage", tweet_id, "unlike"], &[])?)
            .await
    }

    // MARK: - Compose

    pub async fn compose(
        &self,
        text: &str,
        media: &[ComposeMedia],
    ) -> Result<ComposeResult, ApiError> {
        let url = self.build(&["api", "compose"], &[])?;
        let form = multipart::build_form(text, media)
            .map_err(|e| ApiError::InvalidRequest(e.to_string()))?;
        let resp = self
            .http
            .post(url)
            .multipart(form)
            .send()
            .await
            .map_err(|e| ApiError::from_reqwest(&e))?;
        Self::decode(resp).await
    }

    pub async fn reply(
        &self,
        to: &str,
        text: &str,
        media: &[ComposeMedia],
    ) -> Result<ComposeResult, ApiError> {
        let url = self.build(&["api", "reply", to], &[])?;
        let form = multipart::build_form(text, media)
            .map_err(|e| ApiError::InvalidRequest(e.to_string()))?;
        let resp = self
            .http
            .post(url)
            .multipart(form)
            .send()
            .await
            .map_err(|e| ApiError::from_reqwest(&e))?;
        Self::decode(resp).await
    }

    // MARK: - Seen

    pub async fn mark_seen(&self, ids: &[String]) -> Result<MarkSeenResult, ApiError> {
        let url = self.build(&["api", "seen"], &[])?;
        let resp = self
            .http
            .post(url)
            .json(&serde_json::json!({ "ids": ids }))
            .send()
            .await
            .map_err(|e| ApiError::from_reqwest(&e))?;
        Self::decode(resp).await
    }

    pub async fn check_seen(&self, id: &str) -> Result<bool, ApiError> {
        let check: SeenCheck = self.get(self.build(&["api", "seen", id], &[])?).await?;
        Ok(check.seen)
    }

    // MARK: - Session

    pub async fn session(&self) -> Result<SessionState, ApiError> {
        self.get(self.build(&["api", "session"], &[])?).await
    }

    pub async fn patch_session(&self, patch: serde_json::Value) -> Result<SessionState, ApiError> {
        let url = self.build(&["api", "session"], &[])?;
        let resp = self
            .http
            .patch(url)
            .json(&patch)
            .send()
            .await
            .map_err(|e| ApiError::from_reqwest(&e))?;
        Self::decode(resp).await
    }

    /// Convenience for the rage-filter toggle: patches just `filter_enabled`.
    pub async fn set_filter_enabled(&self, enabled: bool) -> Result<SessionState, ApiError> {
        self.patch_session(serde_json::json!({ "filter_enabled": enabled }))
            .await
    }

    // MARK: - Filter config

    pub async fn filter_config(&self) -> Result<FilterConfig, ApiError> {
        self.get(self.build(&["api", "config", "filter"], &[])?)
            .await
    }

    pub async fn patch_filter_config(
        &self,
        drop_topics: Option<Vec<String>>,
        extra_guidance: Option<String>,
    ) -> Result<FilterConfig, ApiError> {
        let mut body = serde_json::Map::new();
        if let Some(topics) = drop_topics {
            body.insert("drop_topics".to_string(), serde_json::json!(topics));
        }
        if let Some(guidance) = extra_guidance {
            body.insert("extra_guidance".to_string(), serde_json::json!(guidance));
        }
        let url = self.build(&["api", "config", "filter"], &[])?;
        let resp = self
            .http
            .patch(url)
            .json(&serde_json::Value::Object(body))
            .send()
            .await
            .map_err(|e| ApiError::from_reqwest(&e))?;
        Self::decode(resp).await
    }

    // MARK: - Media

    /// The proxy URL for a tweet's media at `index`. Stream bytes from here to
    /// display an image/video (the server forwards X CDN bytes with a real
    /// content-type and a 7-day cache header).
    pub fn media_url(&self, tweet_id: &str, index: usize) -> Url {
        self.build(&["api", "media", tweet_id, &index.to_string()], &[])
            .unwrap_or_else(|_| self.base_url())
    }

    /// Fetches the raw bytes at an arbitrary URL (avatar from the X CDN, or a
    /// tweet's media via [`Self::media_url`]). Used by the image pipeline.
    pub async fn fetch_bytes(&self, url: Url) -> Result<Vec<u8>, ApiError> {
        let resp = self
            .http
            .get(url)
            .send()
            .await
            .map_err(|e| ApiError::from_reqwest(&e))?;
        let status = resp.status();
        let bytes = resp.bytes().await.map_err(|e| ApiError::from_reqwest(&e))?;
        if !status.is_success() {
            return Err(ApiError::from_status(status.as_u16(), None));
        }
        Ok(bytes.to_vec())
    }

    // MARK: - SSE / LLM streams

    pub fn filter_stream(
        &self,
        ids: &[String],
    ) -> impl Stream<Item = Result<FilterVerdictEvent, ApiError>> + use<> {
        self.sse(&["api", "sse", "filter"], vec![("ids", ids.join(","))])
    }

    pub fn ask_stream(
        &self,
        tweet_id: &str,
        preset: AskPreset,
    ) -> impl Stream<Item = Result<TokenEvent, ApiError>> + use<> {
        self.sse(
            &["api", "sse", "ask"],
            vec![
                ("tweet_id", tweet_id.to_string()),
                ("preset", preset.as_str().to_string()),
            ],
        )
    }

    pub fn brief_stream(
        &self,
        handle: &str,
    ) -> impl Stream<Item = Result<TokenEvent, ApiError>> + use<> {
        self.sse(
            &["api", "sse", "brief"],
            vec![("handle", handle.to_string())],
        )
    }

    pub fn translate_stream(
        &self,
        tweet_id: &str,
    ) -> impl Stream<Item = Result<TokenEvent, ApiError>> + use<> {
        self.sse(
            &["api", "sse", "translate"],
            vec![("tweet_id", tweet_id.to_string())],
        )
    }

    // MARK: - Request plumbing

    fn build(&self, segments: &[&str], query: &Query) -> Result<Url, ApiError> {
        let mut url = self.base_url();
        {
            let mut seg = url
                .path_segments_mut()
                .map_err(|_| ApiError::InvalidRequest("server URL cannot be a base".to_string()))?;
            seg.pop_if_empty();
            seg.extend(segments);
        }
        if !query.is_empty() {
            let mut pairs = url.query_pairs_mut();
            for (key, value) in query {
                pairs.append_pair(key, value);
            }
        }
        Ok(url)
    }

    async fn get<T: DeserializeOwned>(&self, url: Url) -> Result<T, ApiError> {
        let resp = self
            .http
            .get(url)
            .send()
            .await
            .map_err(|e| ApiError::from_reqwest(&e))?;
        Self::decode(resp).await
    }

    async fn post_empty<T: DeserializeOwned>(&self, url: Url) -> Result<T, ApiError> {
        let resp = self
            .http
            .post(url)
            .send()
            .await
            .map_err(|e| ApiError::from_reqwest(&e))?;
        Self::decode(resp).await
    }

    async fn decode<T: DeserializeOwned>(resp: reqwest::Response) -> Result<T, ApiError> {
        let status = resp.status();
        let bytes = resp.bytes().await.map_err(|e| ApiError::from_reqwest(&e))?;
        if !status.is_success() {
            let server_err = serde_json::from_slice::<ServerError>(&bytes).ok();
            return Err(ApiError::from_status(status.as_u16(), server_err));
        }
        serde_json::from_slice::<T>(&bytes).map_err(|e| ApiError::Decoding(e.to_string()))
    }

    fn sse<T>(
        &self,
        segments: &[&str],
        query: Vec<(&str, String)>,
    ) -> impl Stream<Item = Result<T, ApiError>> + use<T>
    where
        T: DeserializeOwned + 'static,
    {
        let built = self.build(segments, &query);
        let client = self.sse_http.clone();
        async_stream::stream! {
            match built {
                Ok(url) => {
                    let inner = sse::sse_stream::<T>(client, url);
                    futures::pin_mut!(inner);
                    while let Some(item) = inner.next().await {
                        yield item;
                    }
                }
                Err(e) => yield Err(e),
            }
        }
    }
}

fn bool_str(value: bool) -> String {
    if value { "true" } else { "false" }.to_string()
}

fn append_page(query: &mut Vec<(&str, String)>, cursor: Option<&str>, count: Option<u32>) {
    if let Some(c) = cursor {
        query.push(("cursor", c.to_string()));
    }
    if let Some(n) = count {
        query.push(("count", n.to_string()));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use wiremock::matchers::{method, path, query_param};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    fn client(server: &MockServer) -> ApiClient {
        ApiClient::new(Url::parse(&server.uri()).unwrap())
    }

    #[tokio::test]
    async fn home_decodes_timeline_page() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/api/sources/home"))
            .and(query_param("following", "false"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "tweets": [],
                "cursor": "abc"
            })))
            .mount(&server)
            .await;

        let page = client(&server)
            .home(false, false, None, None)
            .await
            .unwrap();
        assert!(page.tweets.is_empty());
        assert_eq!(page.cursor.as_deref(), Some("abc"));
    }

    #[tokio::test]
    async fn originals_mode_sets_query_param() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/api/sources/home"))
            .and(query_param("mode", "originals"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "tweets": [], "cursor": null
            })))
            .mount(&server)
            .await;

        let page = client(&server).home(true, true, None, None).await.unwrap();
        assert!(page.cursor.is_none());
    }

    #[tokio::test]
    async fn percent_encodes_path_segments() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/api/profile/elon%20musk"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "user": {"rest_id":"1","handle":"a","name":"A","verified":false,"followers":0,"following":0},
                "pinned": null,
                "recent": [],
                "cursor": null
            })))
            .mount(&server)
            .await;

        let view = client(&server).profile("elon musk", false).await.unwrap();
        assert_eq!(view.user.handle, "a");
    }

    #[tokio::test]
    async fn maps_404_to_not_found() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/api/tweet/123"))
            .respond_with(ResponseTemplate::new(404).set_body_json(serde_json::json!({
                "error": "no such tweet",
                "kind": "not_found"
            })))
            .mount(&server)
            .await;

        let err = client(&server).tweet("123").await.unwrap_err();
        assert_eq!(err, ApiError::NotFound("no such tweet".to_string()));
    }

    #[tokio::test]
    async fn about_sends_screen_name_and_decodes_resolved() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/api/about/44196397"))
            .and(query_param("screen_name", "elonmusk"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "status": "resolved",
                "profile": {
                    "rest_id": "44196397",
                    "handle": "elonmusk",
                    "name": "Elon Musk",
                    "account_based_in": "United States"
                },
                "alpha2": "US",
                "flag": "🇺🇸"
            })))
            .mount(&server)
            .await;

        let view = client(&server).about("44196397", "elonmusk").await.unwrap();
        assert_eq!(view.status, crate::models::AboutStatus::Resolved);
        assert_eq!(
            view.profile.unwrap().account_based_in.as_deref(),
            Some("United States")
        );
        assert_eq!(view.alpha2.as_deref(), Some("US"));
        assert_eq!(view.flag.as_deref(), Some("🇺🇸"));
    }

    #[tokio::test]
    async fn check_seen_unwraps_bool() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/api/seen/55"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "id": "55", "seen": true
            })))
            .mount(&server)
            .await;

        assert!(client(&server).check_seen("55").await.unwrap());
    }

    #[tokio::test]
    async fn ask_stream_parses_sse_tokens_until_done() {
        let server = MockServer::start().await;
        let body = "data: {\"token\":\"Hel\",\"done\":false}\n\
                    data: {\"token\":\"lo\",\"done\":false}\n\
                    :keepalive\n\
                    data: [DONE]\n";
        Mock::given(method("GET"))
            .and(path("/api/sse/ask"))
            .respond_with(
                ResponseTemplate::new(200)
                    .insert_header("content-type", "text/event-stream")
                    .set_body_string(body),
            )
            .mount(&server)
            .await;

        let stream = client(&server).ask_stream("9", AskPreset::Explain);
        futures::pin_mut!(stream);
        let mut tokens = String::new();
        while let Some(item) = stream.next().await {
            tokens.push_str(&item.unwrap().token);
        }
        assert_eq!(tokens, "Hello");
    }
}
