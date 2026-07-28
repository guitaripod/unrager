use crate::auth::XSession;
use crate::error::{Error, Result};
use crate::gql::query_ids::{Operation, QueryId, QueryIdStore};
use crate::gql::scraper;
use crate::gql::transaction::TransactionKeyMaterial;
use reqwest::header::{HeaderMap, HeaderName, HeaderValue};
use serde_json::Value;
use std::path::PathBuf;
use std::sync::{Mutex, PoisonError, RwLock};
use std::time::Duration;
use tokio::sync::Mutex as AsyncMutex;
use tokio::time::{Instant, sleep_until};

const WEB_BEARER: &str = "AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA";

const GQL_BASE: &str = "https://x.com/i/api/graphql";
const MIN_INTERVAL_LOW_MS: u64 = 300;
const MIN_INTERVAL_HIGH_MS: u64 = 700;
/// The browser this client claims to be. Shared with the bundle scraper so
/// the anonymous fetch that supplies the request-signing key can never drift
/// from the authenticated calls that use it.
pub const USER_AGENT: &str =
    "Mozilla/5.0 (X11; Linux x86_64; rv:153.0) Gecko/20100101 Firefox/153.0";
const SESSION_REFRESH_COOLDOWN: Duration = Duration::from_secs(5 * 60);

/// The live session plus a generation counter bumped on every rotation, so a
/// request can prove which session its headers were signed with and the retry
/// decision after a 401/403 can compare against what is current *now*.
struct SessionSlot {
    session: XSession,
    generation: u64,
}

/// An error from a single request attempt, tagged with the session generation
/// the request's headers were built from. `call` needs the tag to decide
/// whether a concurrent session rotation already fixed the failure.
struct SignedError {
    error: Error,
    generation: u64,
}

pub struct GqlClient {
    http: reqwest::Client,
    session: RwLock<SessionSlot>,
    /// Serializes browser re-extraction after an auth failure so concurrent
    /// 401s don't stampede the cookie store, and memoizes the instant of the
    /// last failed/no-op attempt so a persistent non-cookie 403 doesn't
    /// re-copy and re-decrypt the cookie DB on every poll.
    session_refresh: AsyncMutex<Option<Instant>>,
    store: Mutex<QueryIdStore>,
    cache_path: PathBuf,
    next_allowed: AsyncMutex<Instant>,
    client_uuid: String,
    read_rate_limit_until: Mutex<Option<std::time::Instant>>,
    write_rate_limit_until: Mutex<Option<std::time::Instant>>,
    /// Dedicated bucket for `AboutAccountQuery`. X enforces this endpoint's
    /// budget independently, and a 429 here must NOT spill into the shared
    /// `read_rate_limit_until` — otherwise a flag-fetch failure would
    /// freeze the main feed and surface a misleading "X cooldown" banner.
    about_rate_limit_until: Mutex<Option<std::time::Instant>>,
    /// Dedicated bucket for background ingest polls. A 429 triggered by the
    /// feed-materialization worker lands here and NEVER in the shared
    /// read/write buckets, so interactive requests (open a thread, like a
    /// tweet) are never frozen by background work. Interactive calls ignore
    /// this bucket; background calls respect both this and the interactive
    /// bucket for their method, so a genuine account-wide limit still pauses
    /// them.
    ingest_rate_limit_until: Mutex<Option<std::time::Instant>>,
    transaction_key: Mutex<Option<TransactionKeyMaterial>>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum RateLimitKind {
    Read,
    Write,
}

enum Method {
    Get,
    Post,
}

impl Method {
    fn kind(&self) -> RateLimitKind {
        match self {
            Method::Get => RateLimitKind::Read,
            Method::Post => RateLimitKind::Write,
        }
    }
}

impl GqlClient {
    pub fn new(session: XSession, store: QueryIdStore, cache_path: PathBuf) -> Result<Self> {
        let http = reqwest::Client::builder()
            .user_agent(USER_AGENT)
            .connect_timeout(Duration::from_secs(10))
            .timeout(Duration::from_secs(30))
            .build()?;
        let client_uuid = random_uuid_v4();
        Ok(Self {
            http,
            session: RwLock::new(SessionSlot {
                session,
                generation: 0,
            }),
            session_refresh: AsyncMutex::new(None),
            store: Mutex::new(store),
            cache_path,
            next_allowed: AsyncMutex::new(Instant::now()),
            client_uuid,
            read_rate_limit_until: Mutex::new(None),
            write_rate_limit_until: Mutex::new(None),
            about_rate_limit_until: Mutex::new(None),
            ingest_rate_limit_until: Mutex::new(None),
            transaction_key: Mutex::new(None),
        })
    }

    pub async fn get(&self, op: Operation, variables: &Value, features: &Value) -> Result<Value> {
        self.call(Method::Get, op, variables, features, false).await
    }

    pub async fn post(&self, op: Operation, variables: &Value, features: &Value) -> Result<Value> {
        self.call(Method::Post, op, variables, features, false)
            .await
    }

    /// A POST issued by the background ingest worker. Its 429s are isolated to
    /// the ingest rate-limit bucket so they never freeze interactive requests.
    pub async fn post_background(
        &self,
        op: Operation,
        variables: &Value,
        features: &Value,
    ) -> Result<Value> {
        self.call(Method::Post, op, variables, features, true).await
    }

    /// Form-encoded POST to a legacy `x.com/i/api/1.1` REST endpoint (e.g.
    /// `friendships/create.json`), signed with the same cookie/bearer/csrf
    /// headers as GraphQL calls. `path` must start with `/i/api/1.1/`.
    /// 429s land in the shared write bucket; a 401/403 triggers the same
    /// browser session re-extraction and single retry as GraphQL calls.
    pub async fn post_form_1_1(&self, path: &str, form: &[(&str, &str)]) -> Result<Value> {
        match self.post_form_once(path, form).await {
            Ok(v) => Ok(v),
            Err(signed) if is_auth_failure(&signed.error) => {
                tracing::warn!(
                    "{path}: {} — re-extracting browser session and retrying",
                    signed.error
                );
                if self.try_refresh_session(signed.generation).await {
                    self.post_form_once(path, form)
                        .await
                        .map_err(|retry| retry.error)
                } else {
                    Err(signed.error)
                }
            }
            Err(signed) => Err(signed.error),
        }
    }

    async fn post_form_once(
        &self,
        path: &str,
        form: &[(&str, &str)],
    ) -> std::result::Result<Value, SignedError> {
        let (session, generation) = self.session_snapshot();
        self.post_form_signed(&session, path, form)
            .await
            .map_err(|error| SignedError { error, generation })
    }

    async fn post_form_signed(
        &self,
        session: &XSession,
        path: &str,
        form: &[(&str, &str)],
    ) -> Result<Value> {
        if let Some(remaining) = self.rate_limit_remaining_for(RateLimitKind::Write) {
            return Err(Error::RateLimited {
                remaining_secs: remaining.as_secs().max(1),
            });
        }
        self.throttle().await;
        let url = format!("https://x.com{path}");
        tracing::debug!(path, "rest form request");
        let mut headers = self.headers(session, "POST", path)?;
        headers.insert(
            reqwest::header::CONTENT_TYPE,
            HeaderValue::from_static("application/x-www-form-urlencoded"),
        );
        let res = self
            .http
            .post(&url)
            .headers(headers)
            .form(form)
            .send()
            .await?;

        let status = res.status();
        if status.as_u16() == 429 {
            let reset_hdr = res
                .headers()
                .get("x-rate-limit-reset")
                .and_then(|v| v.to_str().ok())
                .and_then(|s| s.parse::<u64>().ok());
            let cooldown = compute_rate_limit_remaining(reset_hdr);
            self.record_rate_limit(RateLimitKind::Write, cooldown);
            return Err(Error::RateLimited {
                remaining_secs: cooldown.as_secs().max(1),
            });
        }
        let body = res.text().await?;
        if !status.is_success() {
            return Err(Error::GraphqlStatus {
                status: status.as_u16(),
                body: truncate(&body, 400),
            });
        }
        serde_json::from_str(&body).map_err(|e| {
            Error::GraphqlShape(format!(
                "rest response was not valid json ({e}); body preview: {}",
                truncate(&body, 400)
            ))
        })
    }

    async fn call(
        &self,
        method: Method,
        op: Operation,
        variables: &Value,
        features: &Value,
        background: bool,
    ) -> Result<Value> {
        match self
            .call_once(&method, op, variables, features, background)
            .await
        {
            Ok(v) => Ok(v),
            Err(signed) if needs_query_id_refresh(&signed.error) => {
                tracing::warn!(
                    "{}: {} — refreshing query ids and retrying",
                    op.name(),
                    signed.error
                );
                match self.refresh_query_ids().await {
                    Ok(()) => self
                        .call_once(&method, op, variables, features, background)
                        .await
                        .map_err(|retry| retry.error),
                    Err(refresh_err) => {
                        tracing::warn!("query id refresh failed: {refresh_err}");
                        Err(signed.error)
                    }
                }
            }
            Err(signed) if is_auth_failure(&signed.error) => {
                tracing::warn!(
                    "{}: {} — re-extracting browser session and retrying",
                    op.name(),
                    signed.error
                );
                if self.try_refresh_session(signed.generation).await {
                    self.call_once(&method, op, variables, features, background)
                        .await
                        .map_err(|retry| retry.error)
                } else {
                    Err(signed.error)
                }
            }
            Err(signed) => Err(signed.error),
        }
    }

    async fn call_once(
        &self,
        method: &Method,
        op: Operation,
        variables: &Value,
        features: &Value,
        background: bool,
    ) -> std::result::Result<Value, SignedError> {
        let (session, generation) = self.session_snapshot();
        self.call_signed(&session, method, op, variables, features, background)
            .await
            .map_err(|error| SignedError { error, generation })
    }

    async fn call_signed(
        &self,
        session: &XSession,
        method: &Method,
        op: Operation,
        variables: &Value,
        features: &Value,
        background: bool,
    ) -> Result<Value> {
        if matches!(op, Operation::AboutAccountQuery) {
            if let Some(remaining) = self.about_rate_limit_remaining() {
                return Err(Error::RateLimited {
                    remaining_secs: remaining.as_secs().max(1),
                });
            }
        } else if let Some(remaining) = self.precheck_cooldown(method.kind(), background) {
            return Err(Error::RateLimited {
                remaining_secs: remaining.as_secs().max(1),
            });
        }
        let qid = self.lookup_qid(op).ok_or(Error::MissingQueryId {
            operation: op.name(),
        })?;
        let url = format!("{GQL_BASE}/{}/{}", qid.id, op.name());

        self.throttle().await;

        let method_str = match method {
            Method::Get => "GET",
            Method::Post => "POST",
        };
        let path = format!("/i/api/graphql/{}/{}", qid.id, op.name());
        let has_transaction = self.generate_transaction_id(method_str, &path).is_some();
        tracing::debug!(
            op = op.name(),
            method = method_str,
            qid = %qid.id,
            has_transaction,
            "gql request"
        );

        let req = match method {
            Method::Get => {
                let vars_json = serde_json::to_string(variables)?;
                let features_json = serde_json::to_string(features)?;
                let query = [
                    ("variables", vars_json.as_str()),
                    ("features", features_json.as_str()),
                ];
                self.http
                    .get(&url)
                    .headers(self.headers(session, method_str, &path)?)
                    .query(&query)
            }
            Method::Post => {
                let body = Self::post_body(variables, features, &qid.id);
                self.http
                    .post(&url)
                    .headers(self.headers(session, method_str, &path)?)
                    .json(&body)
            }
        };

        let res = req.send().await?;
        self.parse(res, method.kind(), op, background).await
    }

    /// The POST body for a persisted GraphQL operation. Feature-less
    /// mutations omit the `features` key entirely — X's own client never
    /// sends one there, and at least `CreateBookmark` hard-404s a request
    /// that carries even an empty `features` object.
    fn post_body(variables: &Value, features: &Value, query_id: &str) -> Value {
        let mut body = serde_json::json!({
            "variables": variables,
            "queryId": query_id,
        });
        let empty = features.as_object().map(|m| m.is_empty()).unwrap_or(false);
        if !empty {
            body["features"] = features.clone();
        }
        body
    }

    /// Upload media through X's session-authenticated chunked upload
    /// (`upload.x.com/i/media/upload.json`) — the path the web client itself
    /// uses. Serves accounts with no OAuth2 developer credentials; the
    /// returned media id is usable in compose calls for the same account.
    pub async fn upload_media_session(
        &self,
        bytes: &[u8],
        mime: &str,
        media_category: &str,
    ) -> Result<String> {
        const UPLOAD_URL: &str = "https://upload.x.com/i/media/upload.json";
        const CHUNK_SIZE: usize = 4 * 1024 * 1024;
        let (session, _) = self.session_snapshot();

        let init = reqwest::multipart::Form::new()
            .text("command", "INIT")
            .text("total_bytes", bytes.len().to_string())
            .text("media_type", mime.to_string())
            .text("media_category", media_category.to_string());
        let value = self
            .send_upload(UPLOAD_URL, &session, init)
            .await?
            .ok_or_else(|| Error::GraphqlShape("upload INIT returned an empty body".into()))?;
        let media_id = value
            .get("media_id_string")
            .and_then(Value::as_str)
            .map(str::to_string)
            .ok_or_else(|| {
                Error::GraphqlShape(format!("upload INIT response missing media id: {value}"))
            })?;
        tracing::debug!(media_id, size = bytes.len(), "session upload INIT");

        for (segment_index, chunk) in bytes.chunks(CHUNK_SIZE).enumerate() {
            let part = reqwest::multipart::Part::bytes(chunk.to_vec())
                .file_name("chunk")
                .mime_str("application/octet-stream")
                .map_err(|e| Error::GraphqlShape(format!("bad chunk mime: {e}")))?;
            let append = reqwest::multipart::Form::new()
                .text("command", "APPEND")
                .text("media_id", media_id.clone())
                .text("segment_index", segment_index.to_string())
                .part("media", part);
            self.send_upload(UPLOAD_URL, &session, append).await?;
        }

        let finalize = reqwest::multipart::Form::new()
            .text("command", "FINALIZE")
            .text("media_id", media_id.clone());
        let finalized = self.send_upload(UPLOAD_URL, &session, finalize).await?;
        if let Some(info) = finalized.as_ref().and_then(|v| v.get("processing_info")) {
            self.poll_upload_status(UPLOAD_URL, &session, &media_id, info)
                .await?;
        }
        Ok(media_id)
    }

    async fn send_upload(
        &self,
        url: &str,
        session: &XSession,
        form: reqwest::multipart::Form,
    ) -> Result<Option<Value>> {
        let res = self
            .http
            .post(url)
            .headers(self.upload_headers(session, "POST")?)
            .multipart(form)
            .send()
            .await?;
        let status = res.status();
        let body = res.text().await?;
        if !status.is_success() {
            return Err(Error::GraphqlStatus {
                status: status.as_u16(),
                body: truncate(&body, 400),
            });
        }
        if body.is_empty() {
            return Ok(None);
        }
        serde_json::from_str(&body)
            .map(Some)
            .map_err(|e| Error::GraphqlShape(format!("upload response was not valid json ({e})")))
    }

    async fn poll_upload_status(
        &self,
        url: &str,
        session: &XSession,
        media_id: &str,
        initial_info: &Value,
    ) -> Result<()> {
        const MAX_ATTEMPTS: u32 = 30;
        let mut wait_secs = initial_info
            .get("check_after_secs")
            .and_then(Value::as_u64)
            .unwrap_or(1);
        for _ in 0..MAX_ATTEMPTS {
            tokio::time::sleep(Duration::from_secs(wait_secs.max(1))).await;
            let res = self
                .http
                .get(url)
                .headers(self.upload_headers(session, "GET")?)
                .query(&[("command", "STATUS"), ("media_id", media_id)])
                .send()
                .await?;
            let value: Value = res.json().await?;
            let Some(info) = value.get("processing_info") else {
                return Ok(());
            };
            match info.get("state").and_then(Value::as_str).unwrap_or("") {
                "succeeded" => return Ok(()),
                "failed" => {
                    let reason = info
                        .pointer("/error/message")
                        .and_then(Value::as_str)
                        .unwrap_or("(no reason reported)");
                    return Err(Error::GraphqlShape(format!(
                        "media processing failed: {reason}"
                    )));
                }
                _ => {
                    wait_secs = info
                        .get("check_after_secs")
                        .and_then(Value::as_u64)
                        .unwrap_or(2);
                }
            }
        }
        Err(Error::GraphqlShape(
            "media processing did not complete after status polling".into(),
        ))
    }

    /// Session-signed headers for `upload.x.com`, without a content type —
    /// reqwest's multipart builder must set its own boundary header, and
    /// `RequestBuilder::form`/`multipart` never *replace* an existing
    /// content-type.
    fn upload_headers(&self, session: &XSession, method: &str) -> Result<HeaderMap> {
        let mut h = self.headers(session, method, "/i/media/upload.json")?;
        h.remove(reqwest::header::CONTENT_TYPE);
        Ok(h)
    }

    fn lookup_qid(&self, op: Operation) -> Option<QueryId> {
        self.store.lock().ok()?.get(op).cloned()
    }

    fn session_snapshot(&self) -> (XSession, u64) {
        let slot = self.session.read().unwrap_or_else(PoisonError::into_inner);
        (slot.session.clone(), slot.generation)
    }

    fn replace_session(&self, fresh: XSession) {
        let mut slot = self.session.write().unwrap_or_else(PoisonError::into_inner);
        slot.session = fresh;
        slot.generation += 1;
    }

    /// After a 401/403, re-extract cookies from the browser and swap them in
    /// for a single retry. Returns whether the request should be retried —
    /// true only when the live session differs from the one the failing
    /// request was actually signed with (`request_generation`), either because
    /// a concurrent racer already rotated it or because re-extraction here
    /// produced fresh cookies; unchanged cookies never cause a doomed second
    /// request. Failed and no-op attempts are memoized for
    /// [`SESSION_REFRESH_COOLDOWN`] so a persistent non-cookie 403 doesn't
    /// re-copy and re-decrypt the browser's cookie DB on every call.
    async fn try_refresh_session(&self, request_generation: u64) -> bool {
        if std::env::var_os("UNRAGER_DEMO").is_some() {
            return false;
        }
        let mut last_failed_attempt = self.session_refresh.lock().await;
        let (stale, generation) = self.session_snapshot();
        if generation != request_generation {
            return true;
        }
        if let Some(failed_at) = *last_failed_attempt {
            let elapsed = failed_at.elapsed();
            if elapsed < SESSION_REFRESH_COOLDOWN {
                tracing::warn!(
                    elapsed_secs = elapsed.as_secs(),
                    cooldown_secs = SESSION_REFRESH_COOLDOWN.as_secs(),
                    "browser re-extraction recently failed; cooling down instead of retrying"
                );
                return false;
            }
        }
        match crate::auth::chromium::refresh_session().await {
            Ok(fresh) if fresh != stale => {
                tracing::info!("browser session re-extracted after auth failure");
                *last_failed_attempt = None;
                self.replace_session(fresh);
                true
            }
            Ok(_) => {
                tracing::warn!("browser cookies unchanged after auth failure; not retrying");
                *last_failed_attempt = Some(Instant::now());
                false
            }
            Err(e) => {
                tracing::warn!("browser session re-extraction after auth failure failed: {e}");
                *last_failed_attempt = Some(Instant::now());
                false
            }
        }
    }

    /// Warms the x-client-transaction-id key material, retrying with backoff
    /// until it succeeds. Transaction-strict mutations (CreateBookmark,
    /// CreateRetweet) 404 without it, so a single transient startup scrape
    /// failure must not leave the key unavailable for the whole process life.
    pub async fn warm_transaction_key(&self) {
        const BACKOFFS: [u64; 5] = [5, 15, 30, 60, 120];
        for (attempt, delay) in std::iter::once(0)
            .chain(BACKOFFS.iter().copied())
            .enumerate()
        {
            if delay > 0 {
                tokio::time::sleep(Duration::from_secs(delay)).await;
            }
            if self.try_warm_transaction_key().await {
                if attempt > 0 {
                    tracing::info!("transaction key warmed after {attempt} retries");
                }
                return;
            }
        }
        tracing::warn!(
            "transaction key still unavailable after retries; strict mutations may fail"
        );
    }

    async fn try_warm_transaction_key(&self) -> bool {
        match scraper::scrape(&self.http).await {
            Ok(result) => {
                {
                    let mut guard = match self.store.lock() {
                        Ok(g) => g,
                        Err(_) => return false,
                    };
                    guard.merge_iter(result.query_ids);
                    let _ = guard.save_cached(&self.cache_path);
                }
                if let Some(material) = result.transaction_material {
                    if let Ok(mut guard) = self.transaction_key.lock() {
                        tracing::info!("transaction key material loaded");
                        *guard = Some(material);
                    }
                    true
                } else {
                    tracing::warn!("scraper succeeded but transaction key material unavailable");
                    false
                }
            }
            Err(e) => {
                tracing::warn!("startup scrape failed (transaction key unavailable): {e}");
                false
            }
        }
    }

    async fn refresh_query_ids(&self) -> Result<()> {
        let result = scraper::scrape(&self.http).await?;
        let snapshot = {
            let mut guard = self
                .store
                .lock()
                .map_err(|_| Error::Config("query id store poisoned".into()))?;
            guard.merge_iter(result.query_ids);
            guard.clone()
        };
        if let Err(e) = snapshot.save_cached(&self.cache_path) {
            tracing::warn!("failed to persist query id cache: {e}");
        }
        if let Some(material) = result.transaction_material {
            if let Ok(mut guard) = self.transaction_key.lock() {
                *guard = Some(material);
            }
        }
        Ok(())
    }

    async fn throttle(&self) {
        let wait_until = {
            let mut guard = self.next_allowed.lock().await;
            let now = Instant::now();
            let target = if *guard > now { *guard } else { now };
            *guard = target + jittered_interval();
            target
        };
        sleep_until(wait_until).await;
    }

    fn headers(&self, session: &XSession, method: &str, path: &str) -> Result<HeaderMap> {
        let mut h = HeaderMap::new();
        let cookie = format!(
            "auth_token={}; ct0={}; twid={}",
            session.auth_token, session.ct0, session.twid
        );
        h.insert(
            reqwest::header::AUTHORIZATION,
            HeaderValue::from_str(&format!("Bearer {WEB_BEARER}"))
                .map_err(|e| Error::GraphqlShape(e.to_string()))?,
        );
        h.insert(
            reqwest::header::COOKIE,
            HeaderValue::from_str(&cookie).map_err(|e| Error::GraphqlShape(e.to_string()))?,
        );
        h.insert(
            HeaderName::from_static("x-csrf-token"),
            HeaderValue::from_str(&session.ct0).map_err(|e| Error::GraphqlShape(e.to_string()))?,
        );
        h.insert(
            HeaderName::from_static("x-twitter-auth-type"),
            HeaderValue::from_static("OAuth2Session"),
        );
        h.insert(
            HeaderName::from_static("x-twitter-active-user"),
            HeaderValue::from_static("yes"),
        );
        h.insert(
            HeaderName::from_static("x-twitter-client-language"),
            HeaderValue::from_static("en"),
        );
        h.insert(
            HeaderName::from_static("x-client-uuid"),
            HeaderValue::from_str(&self.client_uuid)
                .map_err(|e| Error::GraphqlShape(e.to_string()))?,
        );
        h.insert(
            reqwest::header::CONTENT_TYPE,
            HeaderValue::from_static("application/json"),
        );
        h.insert(reqwest::header::ACCEPT, HeaderValue::from_static("*/*"));
        h.insert(
            reqwest::header::ACCEPT_LANGUAGE,
            HeaderValue::from_static("en-US,en;q=0.5"),
        );
        h.insert(
            HeaderName::from_static("referer"),
            HeaderValue::from_static("https://x.com/"),
        );
        // A same-origin GET is basic-tainted and carries no Origin; sending
        // one anyway is a small inconsistency with the browser we claim to be.
        if method != "GET" {
            h.insert(
                HeaderName::from_static("origin"),
                HeaderValue::from_static("https://x.com"),
            );
        }
        if let Some(tid) = self.generate_transaction_id(method, path) {
            tracing::debug!(tid_len = tid.len(), "x-client-transaction-id generated");
            if let Ok(val) = HeaderValue::from_str(&tid) {
                h.insert(HeaderName::from_static("x-client-transaction-id"), val);
            }
        }
        Ok(h)
    }

    fn generate_transaction_id(&self, method: &str, path: &str) -> Option<String> {
        let guard = self.transaction_key.lock().ok()?;
        let material = guard.as_ref()?;
        crate::gql::transaction::generate_id(material, method, path)
    }

    async fn parse(
        &self,
        res: reqwest::Response,
        kind: RateLimitKind,
        op: Operation,
        background: bool,
    ) -> Result<Value> {
        let status = res.status();
        let reset_hdr = res
            .headers()
            .get("x-rate-limit-reset")
            .and_then(|v| v.to_str().ok())
            .and_then(|s| s.parse::<u64>().ok());
        let remaining_hdr = res
            .headers()
            .get("x-rate-limit-remaining")
            .and_then(|v| v.to_str().ok())
            .and_then(|s| s.parse::<u64>().ok());
        let is_about = matches!(op, Operation::AboutAccountQuery);

        // X's write budgets on this surface are undocumented. Recording what
        // it actually reports is the only way to learn where the ceiling is
        // before a tool walks into it.
        if kind == RateLimitKind::Write {
            tracing::info!(
                op = op.name(),
                remaining = remaining_hdr,
                reset = reset_hdr,
                status = status.as_u16(),
                "write rate-limit headers"
            );
        }

        if status.as_u16() == 429 {
            let cooldown = compute_rate_limit_remaining(reset_hdr);
            if is_about {
                self.record_about_cooldown(cooldown);
            } else if background {
                self.record_ingest_cooldown(cooldown);
            } else {
                self.record_rate_limit(kind, cooldown);
            }
            return Err(Error::RateLimited {
                remaining_secs: cooldown.as_secs().max(1),
            });
        }

        // Proactive throttle: when AboutAccountQuery's budget is nearly
        // exhausted, sleep the bucket until reset so the next caller bails
        // before triggering a real 429. The headers are advisory so we
        // leave the main feed buckets alone — they're allowed to keep
        // firing until the server actually slams the door.
        if is_about
            && let (Some(rem), Some(reset)) = (remaining_hdr, reset_hdr)
            && rem <= 2
        {
            let cooldown = compute_rate_limit_remaining(Some(reset));
            tracing::info!(
                rem,
                cooldown_secs = cooldown.as_secs(),
                "AboutAccountQuery budget low, parking until reset"
            );
            self.record_about_cooldown(cooldown);
        }

        let body = res.text().await?;
        if !status.is_success() {
            return Err(classify_api_error(Some(status.as_u16()), &body).unwrap_or(
                Error::GraphqlStatus {
                    status: status.as_u16(),
                    body: truncate(&body, 400),
                },
            ));
        }
        let value: Value = serde_json::from_str(&body).map_err(|e| {
            Error::GraphqlShape(format!(
                "response was not valid json ({e}); body preview: {}",
                truncate(&body, 400)
            ))
        })?;
        if let Some(errors) = value.get("errors").and_then(Value::as_array)
            && !errors.is_empty()
        {
            return Err(
                classify_api_error(None, &body).unwrap_or(Error::GraphqlShape(format!(
                    "graphql errors: {}",
                    truncate(&errors[0].to_string(), 400)
                ))),
            );
        }
        Ok(value)
    }
}

/// Lifts X's own `errors` array into a typed error, keeping the numeric
/// code. X answers an automation block with a 200 and an `errors` array as
/// readily as with a 403, so both paths come through here — and the code is
/// what lets a caller tell a block it must stop for from a post that was
/// already gone.
fn classify_api_error(status: Option<u16>, body: &str) -> Option<Error> {
    let value: Value = serde_json::from_str(body).ok()?;
    let first = value.get("errors")?.as_array()?.first()?;
    let code = first
        .get("code")
        .and_then(Value::as_i64)
        .or_else(|| first.pointer("/extensions/code").and_then(Value::as_i64));
    let message = first
        .get("message")
        .and_then(Value::as_str)
        .map(str::to_string)
        .unwrap_or_else(|| truncate(&first.to_string(), 300));
    Some(Error::GraphqlApi {
        status,
        code,
        message,
    })
}

impl GqlClient {
    fn rate_limit_remaining_for(&self, kind: RateLimitKind) -> Option<Duration> {
        let slot = match kind {
            RateLimitKind::Read => &self.read_rate_limit_until,
            RateLimitKind::Write => &self.write_rate_limit_until,
        };
        let until = *slot.lock().ok()?;
        let until = until?;
        let now = std::time::Instant::now();
        if until > now { Some(until - now) } else { None }
    }

    pub fn read_rate_limit_remaining(&self) -> Option<Duration> {
        self.rate_limit_remaining_for(RateLimitKind::Read)
    }

    pub fn write_rate_limit_remaining(&self) -> Option<Duration> {
        self.rate_limit_remaining_for(RateLimitKind::Write)
    }

    pub fn rate_limit_remaining(&self) -> Option<Duration> {
        match (
            self.read_rate_limit_remaining(),
            self.write_rate_limit_remaining(),
        ) {
            (Some(r), Some(w)) => Some(r.max(w)),
            (Some(r), None) => Some(r),
            (None, Some(w)) => Some(w),
            (None, None) => None,
        }
    }

    fn record_rate_limit(&self, kind: RateLimitKind, remaining: Duration) {
        let slot = match kind {
            RateLimitKind::Read => &self.read_rate_limit_until,
            RateLimitKind::Write => &self.write_rate_limit_until,
        };
        if let Ok(mut guard) = slot.lock() {
            *guard = Some(std::time::Instant::now() + remaining);
        }
    }

    fn record_about_cooldown(&self, remaining: Duration) {
        if let Ok(mut guard) = self.about_rate_limit_until.lock() {
            *guard = Some(std::time::Instant::now() + remaining);
        }
    }

    pub fn about_rate_limit_remaining(&self) -> Option<Duration> {
        let until = *self.about_rate_limit_until.lock().ok()?;
        let until = until?;
        let now = std::time::Instant::now();
        if until > now { Some(until - now) } else { None }
    }

    fn record_ingest_cooldown(&self, remaining: Duration) {
        if let Ok(mut guard) = self.ingest_rate_limit_until.lock() {
            *guard = Some(std::time::Instant::now() + remaining);
        }
    }

    pub fn ingest_rate_limit_remaining(&self) -> Option<Duration> {
        let until = *self.ingest_rate_limit_until.lock().ok()?;
        let until = until?;
        let now = std::time::Instant::now();
        if until > now { Some(until - now) } else { None }
    }

    /// Cooldown a call must respect before firing. Interactive calls see only
    /// their method's bucket; background calls additionally respect the ingest
    /// bucket, so a background 429 pauses background work without ever touching
    /// the interactive path.
    fn precheck_cooldown(&self, kind: RateLimitKind, background: bool) -> Option<Duration> {
        let interactive = self.rate_limit_remaining_for(kind);
        if !background {
            return interactive;
        }
        match (interactive, self.ingest_rate_limit_remaining()) {
            (Some(a), Some(b)) => Some(a.max(b)),
            (Some(a), None) => Some(a),
            (None, Some(b)) => Some(b),
            (None, None) => None,
        }
    }
}

fn needs_query_id_refresh(e: &Error) -> bool {
    matches!(
        e,
        Error::MissingQueryId { .. }
            | Error::GraphqlStatus {
                status: 400 | 404,
                ..
            }
    )
}

/// Whether a failure is worth re-extracting the browser session for. An
/// automation block also arrives as a 403, but re-reading the cookie store
/// and immediately retrying is the worst possible response to one — it adds
/// a write to an account X has just told us to leave alone — so blocks are
/// excluded here and left for the caller to stop on.
fn is_auth_failure(e: &Error) -> bool {
    if e.is_automation_block() {
        return false;
    }
    matches!(
        e,
        Error::GraphqlStatus {
            status: 401 | 403,
            ..
        } | Error::GraphqlApi {
            status: Some(401 | 403),
            ..
        }
    )
}

fn compute_rate_limit_remaining(reset_epoch: Option<u64>) -> Duration {
    const DEFAULT_WINDOW: Duration = Duration::from_secs(15 * 60);
    const MIN_WINDOW: Duration = Duration::from_secs(60);
    let Some(reset) = reset_epoch else {
        return DEFAULT_WINDOW;
    };
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    if reset <= now {
        return MIN_WINDOW;
    }
    Duration::from_secs((reset - now).clamp(MIN_WINDOW.as_secs(), 60 * 60))
}

fn random_uuid_v4() -> String {
    use rand::RngCore;
    let mut bytes = [0u8; 16];
    rand::rng().fill_bytes(&mut bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    format!(
        "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        bytes[0],
        bytes[1],
        bytes[2],
        bytes[3],
        bytes[4],
        bytes[5],
        bytes[6],
        bytes[7],
        bytes[8],
        bytes[9],
        bytes[10],
        bytes[11],
        bytes[12],
        bytes[13],
        bytes[14],
        bytes[15],
    )
}

fn jittered_interval() -> Duration {
    use rand::Rng;
    Duration::from_millis(rand::rng().random_range(MIN_INTERVAL_LOW_MS..=MIN_INTERVAL_HIGH_MS))
}

fn truncate(s: &str, max_bytes: usize) -> String {
    if s.len() <= max_bytes {
        return s.to_string();
    }
    let mut end = max_bytes;
    while end > 0 && !s.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}…", &s[..end])
}

#[cfg(test)]
mod tests {
    use super::{Error, GqlClient, Instant, is_auth_failure, needs_query_id_refresh, truncate};
    use crate::auth::XSession;
    use crate::gql::query_ids::QueryIdStore;

    fn status_err(status: u16) -> Error {
        Error::GraphqlStatus {
            status,
            body: String::new(),
        }
    }

    fn session(tag: &str) -> XSession {
        XSession {
            auth_token: format!("auth-{tag}"),
            ct0: format!("ct0-{tag}"),
            twid: format!("twid-{tag}"),
        }
    }

    fn test_client() -> GqlClient {
        GqlClient::new(
            session("initial"),
            QueryIdStore::with_fallbacks(),
            std::env::temp_dir().join("unrager-client-test-query-ids.json"),
        )
        .unwrap()
    }

    #[test]
    fn replace_session_bumps_generation() {
        let client = test_client();
        let (_, before) = client.session_snapshot();
        client.replace_session(session("rotated"));
        let (current, after) = client.session_snapshot();
        assert_eq!(after, before + 1);
        assert_eq!(current, session("rotated"));
    }

    #[tokio::test]
    async fn refresh_retries_when_session_rotated_since_request_was_signed() {
        let client = test_client();
        let (_, signed_with) = client.session_snapshot();
        client.replace_session(session("racer"));
        assert!(client.try_refresh_session(signed_with).await);
    }

    #[tokio::test]
    async fn refresh_backs_off_after_a_recent_failed_attempt() {
        let client = test_client();
        *client.session_refresh.lock().await = Some(Instant::now());
        let (_, generation) = client.session_snapshot();
        assert!(!client.try_refresh_session(generation).await);
    }

    #[tokio::test]
    async fn refresh_cooldown_does_not_block_a_rotated_session_retry() {
        let client = test_client();
        *client.session_refresh.lock().await = Some(Instant::now());
        let (_, signed_with) = client.session_snapshot();
        client.replace_session(session("racer"));
        assert!(client.try_refresh_session(signed_with).await);
    }

    #[test]
    fn missing_query_id_triggers_refresh() {
        assert!(needs_query_id_refresh(&Error::MissingQueryId {
            operation: "BookmarkSearchTimeline",
        }));
    }

    #[test]
    fn stale_query_id_statuses_trigger_refresh() {
        assert!(needs_query_id_refresh(&status_err(400)));
        assert!(needs_query_id_refresh(&status_err(404)));
        assert!(!needs_query_id_refresh(&status_err(401)));
        assert!(!needs_query_id_refresh(&status_err(500)));
    }

    #[test]
    fn auth_failure_matches_401_and_403_only() {
        assert!(is_auth_failure(&status_err(401)));
        assert!(is_auth_failure(&status_err(403)));
        assert!(!is_auth_failure(&status_err(400)));
        assert!(!is_auth_failure(&status_err(404)));
        assert!(!is_auth_failure(&status_err(429)));
        assert!(!is_auth_failure(&Error::MissingQueryId {
            operation: "Viewer",
        }));
    }

    #[test]
    fn truncate_ascii_short() {
        assert_eq!(truncate("hello", 10), "hello");
    }

    #[test]
    fn truncate_ascii_long() {
        assert_eq!(truncate("0123456789abcdef", 8), "01234567…");
    }

    #[test]
    fn truncate_never_splits_multibyte() {
        let s = "aaaa🦀bbbb";
        for cap in 0..=s.len() {
            let out = truncate(s, cap);
            assert!(out.is_char_boundary(out.trim_end_matches('…').len()));
        }
    }

    #[test]
    fn truncate_at_codepoint_boundary() {
        let s = "a🦀b";
        assert_eq!(truncate(s, 1), "a…");
        assert_eq!(truncate(s, 2), "a…");
        assert_eq!(truncate(s, 3), "a…");
        assert_eq!(truncate(s, 5), "a🦀…");
    }
}
