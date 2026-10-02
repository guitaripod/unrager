use crate::auth::XSession;
use crate::error::{Error, Result};
use crate::gql::query_ids::{Operation, QueryId, QueryIdStore};
use crate::gql::scraper;
use crate::gql::transaction::TransactionKeyMaterial;
use reqwest::header::{HeaderMap, HeaderName, HeaderValue};
use serde_json::Value;
use std::collections::HashMap;
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
    /// When each [`Bucket`] may be called again after a 429. X budgets every
    /// operation on its own, so a search 429 must never freeze likes or the
    /// Home feed, and the reverse.
    cooldowns: Mutex<HashMap<Bucket, std::time::Instant>>,
    transaction_key: Mutex<Option<TransactionKeyMaterial>>,
    /// Set for `unrager demo`: every request fails with [`Error::Offline`]
    /// before anything is sent, so a demo never reaches X or reads the
    /// browser's login.
    offline: bool,
}

/// One rate-limit budget. Each GraphQL operation and each legacy REST path
/// has its own; background ingest polls share `Ingest`, so a 429 caused by
/// the feed worker never freezes an interactive request, while a background
/// call still respects its operation's interactive cooldown.
#[derive(Clone, Debug, Eq, Hash, PartialEq)]
enum Bucket {
    Op(Operation),
    Rest(String),
    Ingest,
}

impl Bucket {
    /// Whether this budget belongs to an account action (like, repost,
    /// bookmark, delete, follow) rather than a read.
    fn is_write(&self) -> bool {
        match self {
            Bucket::Op(op) => is_write_operation(*op),
            Bucket::Rest(_) => true,
            Bucket::Ingest => false,
        }
    }

    /// Whether this budget counts toward the TUI's "X cooldown on reads"
    /// banner. About and notification lookups are side channels: their
    /// cooldowns must not read as the main feed being frozen.
    fn is_interactive_read(&self) -> bool {
        match self {
            Bucket::Op(op) => {
                !is_write_operation(*op)
                    && !matches!(
                        op,
                        Operation::AboutAccountQuery | Operation::NotificationsTimeline
                    )
            }
            Bucket::Rest(_) | Bucket::Ingest => false,
        }
    }
}

fn is_write_operation(op: Operation) -> bool {
    matches!(
        op,
        Operation::FavoriteTweet
            | Operation::UnfavoriteTweet
            | Operation::CreateRetweet
            | Operation::DeleteRetweet
            | Operation::DeleteTweet
            | Operation::CreateBookmark
            | Operation::DeleteBookmark
    )
}

enum Method {
    Get,
    Post,
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
            cooldowns: Mutex::new(HashMap::new()),
            transaction_key: Mutex::new(None),
            offline: false,
        })
    }

    /// A client that never contacts X, for `unrager demo`'s bundled feed.
    pub fn offline(store: QueryIdStore, cache_path: PathBuf) -> Result<Self> {
        Ok(Self {
            offline: true,
            ..Self::new(XSession::default(), store, cache_path)?
        })
    }

    fn ensure_online(&self) -> Result<()> {
        if self.offline {
            Err(Error::Offline)
        } else {
            Ok(())
        }
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
    /// 429s land in that path's own bucket; a 401/403 triggers the same
    /// browser session re-extraction and single retry as GraphQL calls.
    pub async fn post_form_1_1(&self, path: &str, form: &[(&str, &str)]) -> Result<Value> {
        self.ensure_online()?;
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
        let bucket = Bucket::Rest(path.to_string());
        if let Some(remaining) = self.cooldown_remaining(&bucket) {
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
            self.record_cooldown(bucket, cooldown);
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
        self.ensure_online()?;
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
        if let Some(remaining) = self.precheck_cooldown(op, background) {
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
        let has_transaction = self
            .transaction_key
            .lock()
            .is_ok_and(|material| material.is_some());
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
        self.parse(res, op, background).await
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
        self.ensure_online()?;
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

    /// The signed-in account's numeric id, when a session is loaded.
    pub fn self_user_id(&self) -> Option<String> {
        self.session
            .read()
            .unwrap_or_else(PoisonError::into_inner)
            .session
            .user_id()
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
        if self.offline {
            return;
        }
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

    /// The session to scrape the signed-in shell with, if this client has
    /// one (a filter-only server runs with an empty session).
    fn scrape_session(&self) -> Option<XSession> {
        let (session, _) = self.session_snapshot();
        (!session.auth_token.is_empty()).then_some(session)
    }

    async fn try_warm_transaction_key(&self) -> bool {
        match scraper::scrape(&self.http, self.scrape_session().as_ref()).await {
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
        let result = scraper::scrape(&self.http, self.scrape_session().as_ref()).await?;
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
        if is_write_operation(op) {
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
            let bucket = if background {
                Bucket::Ingest
            } else {
                Bucket::Op(op)
            };
            self.record_cooldown(bucket, cooldown);
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
            self.record_cooldown(Bucket::Op(op), cooldown);
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
    fn cooldown_remaining(&self, bucket: &Bucket) -> Option<Duration> {
        let until = *self.cooldowns.lock().ok()?.get(bucket)?;
        until
            .checked_duration_since(std::time::Instant::now())
            .filter(|remaining| !remaining.is_zero())
    }

    /// The longest live cooldown among the buckets `include` selects.
    fn longest_cooldown(&self, include: impl Fn(&Bucket) -> bool) -> Option<Duration> {
        let now = std::time::Instant::now();
        let guard = self.cooldowns.lock().ok()?;
        guard
            .iter()
            .filter(|(bucket, _)| include(bucket))
            .filter_map(|(_, until)| until.checked_duration_since(now))
            .filter(|remaining| !remaining.is_zero())
            .max()
    }

    fn record_cooldown(&self, bucket: Bucket, remaining: Duration) {
        let Ok(mut guard) = self.cooldowns.lock() else {
            return;
        };
        let now = std::time::Instant::now();
        guard.retain(|_, until| *until > now);
        tracing::info!(
            bucket = ?bucket,
            cooldown_secs = remaining.as_secs(),
            "rate limited; cooling this budget down"
        );
        guard.insert(bucket, now + remaining);
    }

    /// The longest cooldown on any interactive read (Home, threads, search,
    /// profiles).
    pub fn read_rate_limit_remaining(&self) -> Option<Duration> {
        self.longest_cooldown(Bucket::is_interactive_read)
    }

    /// The longest cooldown on any account action (like, repost, bookmark,
    /// delete, follow).
    pub fn write_rate_limit_remaining(&self) -> Option<Duration> {
        self.longest_cooldown(Bucket::is_write)
    }

    pub fn rate_limit_remaining(&self) -> Option<Duration> {
        self.longest_cooldown(|bucket| bucket.is_write() || bucket.is_interactive_read())
    }

    pub fn about_rate_limit_remaining(&self) -> Option<Duration> {
        self.cooldown_remaining(&Bucket::Op(Operation::AboutAccountQuery))
    }

    pub fn notifications_rate_limit_remaining(&self) -> Option<Duration> {
        self.cooldown_remaining(&Bucket::Op(Operation::NotificationsTimeline))
    }

    pub fn ingest_rate_limit_remaining(&self) -> Option<Duration> {
        self.cooldown_remaining(&Bucket::Ingest)
    }

    /// Cooldown a call must respect before firing. Interactive calls see only
    /// their operation's bucket; background calls additionally respect the
    /// ingest bucket, so a background 429 pauses background work without
    /// ever touching the interactive path.
    fn precheck_cooldown(&self, op: Operation, background: bool) -> Option<Duration> {
        let interactive = self.cooldown_remaining(&Bucket::Op(op));
        if !background {
            return interactive;
        }
        interactive.max(self.ingest_rate_limit_remaining())
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
    use super::{
        Bucket, Error, GqlClient, Instant, is_auth_failure, needs_query_id_refresh, truncate,
    };
    use crate::auth::XSession;
    use crate::gql::query_ids::{Operation, QueryIdStore};

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

    #[tokio::test]
    async fn an_offline_client_never_sends_a_request() {
        let client = GqlClient::offline(
            QueryIdStore::with_fallbacks(),
            std::env::temp_dir().join("unrager-offline-test-query-ids.json"),
        )
        .unwrap();
        let empty = serde_json::json!({});
        let quick = std::time::Duration::from_millis(200);

        let read = tokio::time::timeout(
            quick,
            client.get(Operation::AboutAccountQuery, &empty, &empty),
        )
        .await
        .expect("an offline read returns without waiting on the network");
        assert!(matches!(read, Err(Error::Offline)));
        let write = tokio::time::timeout(
            quick,
            client.post_form_1_1("/i/api/1.1/friendships/create.json", &[]),
        )
        .await
        .expect("an offline write returns without waiting on the network");
        assert!(matches!(write, Err(Error::Offline)));
        let upload = tokio::time::timeout(
            quick,
            client.upload_media_session(b"img", "image/png", "tweet_image"),
        )
        .await
        .expect("an offline upload returns without waiting on the network");
        assert!(matches!(upload, Err(Error::Offline)));
        tokio::time::timeout(quick, client.warm_transaction_key())
            .await
            .expect("an offline client doesn't scrape x.com for a signing key");
    }

    #[tokio::test]
    async fn a_notifications_cooldown_blocks_only_notifications() {
        let client = test_client();
        client.record_cooldown(
            Bucket::Op(Operation::NotificationsTimeline),
            std::time::Duration::from_secs(300),
        );
        let empty = serde_json::json!({});

        let notifications = client
            .get(Operation::NotificationsTimeline, &empty, &empty)
            .await;
        assert!(matches!(notifications, Err(Error::RateLimited { .. })));
        assert!(
            client.rate_limit_remaining().is_none(),
            "the shared read bucket stays open for Home, threads and profiles"
        );
        assert!(client.about_rate_limit_remaining().is_none());
        assert!(client.ingest_rate_limit_remaining().is_none());
    }

    #[tokio::test]
    async fn a_search_cooldown_leaves_likes_and_home_open() {
        let client = test_client();
        client.record_cooldown(
            Bucket::Op(Operation::SearchTimeline),
            std::time::Duration::from_secs(300),
        );
        let empty = serde_json::json!({});

        let search = client.post(Operation::SearchTimeline, &empty, &empty).await;
        assert!(matches!(search, Err(Error::RateLimited { .. })));
        assert!(
            client
                .precheck_cooldown(Operation::FavoriteTweet, false)
                .is_none()
        );
        assert!(
            client
                .precheck_cooldown(Operation::HomeTimeline, false)
                .is_none()
        );
        assert!(client.write_rate_limit_remaining().is_none());
        assert!(client.read_rate_limit_remaining().is_some());
    }

    #[test]
    fn a_follow_cooldown_is_its_own_write_budget() {
        let client = test_client();
        client.record_cooldown(
            Bucket::Rest("/i/api/1.1/friendships/create.json".into()),
            std::time::Duration::from_secs(300),
        );
        assert!(client.write_rate_limit_remaining().is_some());
        assert!(client.read_rate_limit_remaining().is_none());
        assert!(
            client
                .precheck_cooldown(Operation::FavoriteTweet, false)
                .is_none()
        );
        assert!(
            client
                .cooldown_remaining(&Bucket::Rest("/i/api/1.1/friendships/destroy.json".into()))
                .is_none()
        );
    }

    #[test]
    fn a_background_cooldown_pauses_only_background_calls() {
        let client = test_client();
        client.record_cooldown(Bucket::Ingest, std::time::Duration::from_secs(300));
        assert!(
            client
                .precheck_cooldown(Operation::HomeTimeline, false)
                .is_none()
        );
        assert!(
            client
                .precheck_cooldown(Operation::HomeTimeline, true)
                .is_some()
        );
        assert!(client.rate_limit_remaining().is_none());
    }

    #[test]
    fn an_interactive_cooldown_also_pauses_background_calls() {
        let client = test_client();
        client.record_cooldown(
            Bucket::Op(Operation::HomeLatestTimeline),
            std::time::Duration::from_secs(300),
        );
        assert!(
            client
                .precheck_cooldown(Operation::HomeLatestTimeline, true)
                .is_some()
        );
    }

    #[test]
    fn a_cooldown_expires() {
        let client = test_client();
        client.record_cooldown(
            Bucket::Op(Operation::FavoriteTweet),
            std::time::Duration::ZERO,
        );
        assert!(
            client
                .precheck_cooldown(Operation::FavoriteTweet, false)
                .is_none()
        );
        assert!(client.write_rate_limit_remaining().is_none());
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
