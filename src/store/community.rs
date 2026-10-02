//! Client for the X-Posed community cache, a public service where users of
//! the X-Posed browser extension share what X's "About this account" panel
//! says about an account. A country comes back in one batched request instead
//! of one `AboutAccountQuery` per author on the user's own X session, so flags
//! keep loading while X rate-limits that query.
//!
//! Opt-in (`[about] community_cache`): every lookup tells the service which
//! handles are being looked at. Nothing is ever contributed back.

use chrono::{DateTime, TimeZone, Utc};
use serde_json::Value;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::sync::oneshot;
use unrager_model::AboutProfile;

pub const DEFAULT_URL: &str = "https://x-posed-cache.xaitax.workers.dev";

/// How long a lookup waits for others to join its request.
const BATCH_DELAY: Duration = Duration::from_millis(150);
/// Handles per request, the most the service takes.
const BATCH_SIZE: usize = 100;
const TIMEOUT: Duration = Duration::from_secs(5);
/// After a failed request the service is left alone this long.
const BACKOFF: Duration = Duration::from_secs(60);
/// How long a handle the service doesn't know isn't asked about again.
const MISS_TTL: Duration = Duration::from_secs(600);
const MAX_MISSES: usize = 10_000;
/// The service drops a record 60 days after its last write; an older stamp is
/// a record it hasn't expired yet.
const MAX_AGE: i64 = 60 * 86_400;
/// Twitter launched in 2006: an earlier account creation time is bad data.
const EARLIEST_CREATED: i64 = 1_136_073_600;

/// One account as the service stores it, already checked.
#[derive(Debug, Clone)]
struct Record {
    location: Option<String>,
    device: Option<String>,
    accurate: bool,
    rest_id: String,
    created_at: Option<DateTime<Utc>>,
    username_changes: Option<u64>,
}

#[derive(Default)]
struct State {
    waiting: HashMap<String, Vec<oneshot::Sender<Option<Record>>>>,
    flush_scheduled: bool,
    backoff_until: Option<Instant>,
    misses: HashMap<String, Instant>,
}

pub struct CommunityCache {
    http: reqwest::Client,
    base_url: String,
    state: Mutex<State>,
}

impl CommunityCache {
    pub fn new(base_url: &str) -> Arc<Self> {
        let http = reqwest::Client::builder()
            .timeout(TIMEOUT)
            .user_agent(concat!("unrager/", env!("CARGO_PKG_VERSION")))
            .build()
            .unwrap_or_default();
        Arc::new(Self {
            http,
            base_url: base_url.trim_end_matches('/').to_string(),
            state: Mutex::new(State::default()),
        })
    }

    /// What the service knows about `screen_name`, as a profile for the
    /// account `rest_id`. Lookups arriving within `BATCH_DELAY` of each other
    /// share one request. None when the service doesn't know the account,
    /// answers for a different one, is unreachable or is being left alone
    /// after a failure; the caller then asks X.
    pub async fn lookup(
        self: &Arc<Self>,
        rest_id: &str,
        screen_name: &str,
    ) -> Option<AboutProfile> {
        let handle = screen_name.trim_start_matches('@').to_ascii_lowercase();
        if !is_handle(&handle) {
            return None;
        }
        let answer = {
            let mut state = self.state.lock().unwrap();
            if state
                .backoff_until
                .is_some_and(|until| Instant::now() < until)
            {
                return None;
            }
            if state
                .misses
                .get(&handle)
                .is_some_and(|at| at.elapsed() < MISS_TTL)
            {
                return None;
            }
            let (tx, rx) = oneshot::channel();
            state.waiting.entry(handle.clone()).or_default().push(tx);
            if !state.flush_scheduled {
                state.flush_scheduled = true;
                let this = Arc::clone(self);
                tokio::spawn(async move { this.flush().await });
            }
            rx
        };
        let record = answer.await.ok()??;
        record.into_profile(rest_id, screen_name)
    }

    /// Sends everything that queued up during `BATCH_DELAY`, 100 handles to a
    /// request, and hands each waiter its record.
    async fn flush(self: Arc<Self>) {
        tokio::time::sleep(BATCH_DELAY).await;
        let mut waiting = {
            let mut state = self.state.lock().unwrap();
            state.flush_scheduled = false;
            std::mem::take(&mut state.waiting)
        };
        let handles: Vec<String> = waiting.keys().cloned().collect();
        let mut failed = false;
        for chunk in handles.chunks(BATCH_SIZE) {
            let mut found = if failed {
                None
            } else {
                match self.request(chunk).await {
                    Ok(found) => Some(found),
                    Err(e) => {
                        failed = true;
                        self.state.lock().unwrap().backoff_until = Some(Instant::now() + BACKOFF);
                        tracing::warn!("community flag cache unreachable, pausing 60 s: {e}");
                        None
                    }
                }
            };
            for handle in chunk {
                let record = found.as_mut().and_then(|f| f.remove(handle));
                if found.is_some() && record.is_none() {
                    self.note_miss(handle);
                }
                for tx in waiting.remove(handle).unwrap_or_default() {
                    let _ = tx.send(record.clone());
                }
            }
        }
    }

    fn note_miss(&self, handle: &str) {
        let mut state = self.state.lock().unwrap();
        if state.misses.len() >= MAX_MISSES {
            state.misses.clear();
        }
        state.misses.insert(handle.to_string(), Instant::now());
    }

    /// One `GET /lookup?users=a,b,c`: the records the service holds, by
    /// lowercase handle.
    async fn request(&self, handles: &[String]) -> Result<HashMap<String, Record>, String> {
        let url = format!("{}/lookup?users={}", self.base_url, handles.join(","));
        let response = self.http.get(url).send().await.map_err(|e| e.to_string())?;
        if !response.status().is_success() {
            return Err(format!("HTTP {}", response.status()));
        }
        let body: Value = response.json().await.map_err(|e| e.to_string())?;
        let now = Utc::now();
        Ok(body
            .get("results")
            .and_then(Value::as_object)
            .map(|results| {
                results
                    .iter()
                    .filter_map(|(handle, value)| {
                        Record::parse(value, now).map(|r| (handle.to_ascii_lowercase(), r))
                    })
                    .collect()
            })
            .unwrap_or_default())
    }
}

/// X's handle rule: 1 to 15 letters, digits or underscores.
fn is_handle(text: &str) -> bool {
    (1..=15).contains(&text.len()) && text.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_')
}

impl Record {
    /// The record in `value`, or None when it is stale, carries nothing to
    /// show or lacks the account id the answer is checked against.
    fn parse(value: &Value, now: DateTime<Utc>) -> Option<Self> {
        let stamp = integer(value.get("t"))?;
        if stamp <= 0 || now.timestamp() - stamp > MAX_AGE {
            return None;
        }
        let rest_id = value
            .get("id")
            .and_then(Value::as_str)
            .filter(|id| (1..=20).contains(&id.len()) && id.bytes().all(|b| b.is_ascii_digit()))?
            .to_string();
        let location = text(value.get("l"));
        let device = text(value.get("d"));
        if location.is_none() && device.is_none() {
            return None;
        }
        Some(Self {
            location,
            device,
            accurate: value.get("a").and_then(Value::as_bool) != Some(false),
            rest_id,
            created_at: integer(value.get("c"))
                .filter(|&c| c >= EARLIEST_CREATED && c <= now.timestamp())
                .and_then(|c| Utc.timestamp_opt(c, 0).single()),
            username_changes: integer(value.get("uc")).and_then(|n| u64::try_from(n).ok()),
        })
    }

    /// The profile for `rest_id`, unless the record belongs to another
    /// account: the service once answered a handle with someone else's data,
    /// so a flag is only shown when the ids agree.
    fn into_profile(self, rest_id: &str, screen_name: &str) -> Option<AboutProfile> {
        if self.rest_id != rest_id {
            tracing::warn!(
                "community cache answered @{screen_name} with account {}, expected {rest_id}",
                self.rest_id
            );
            return None;
        }
        Some(AboutProfile {
            rest_id: rest_id.to_string(),
            handle: screen_name.trim_start_matches('@').to_string(),
            name: String::new(),
            account_based_in: self.location,
            location_accurate: Some(self.accurate),
            source: self.device,
            username_changes: self.username_changes,
            affiliate_username: None,
            created_at: self.created_at,
            is_blue_verified: false,
            verified: false,
            verified_since: None,
            community: true,
        })
    }
}

/// A whole number from JSON, which the service writes as an integer but may
/// one day write as a float or a string.
fn integer(value: Option<&Value>) -> Option<i64> {
    let value = value?;
    value
        .as_i64()
        .or_else(|| value.as_f64().filter(|f| f.is_finite()).map(|f| f as i64))
        .or_else(|| value.as_str().and_then(|s| s.parse().ok()))
}

/// A short printable string, trimmed; None when empty or unreasonable.
fn text(value: Option<&Value>) -> Option<String> {
    let trimmed = value?.as_str()?.trim();
    (!trimmed.is_empty() && trimmed.len() <= 100 && !trimmed.chars().any(char::is_control))
        .then(|| trimmed.to_string())
}

#[cfg(test)]
pub(crate) mod test_support {
    use super::*;
    use axum::Router;
    use axum::extract::{Query, State};
    use axum::routing::get;
    use std::sync::atomic::{AtomicUsize, Ordering};

    /// A stand-in for the community service that records the handles asked
    /// for and answers with a fixed status and body.
    #[derive(Clone)]
    pub(crate) struct Service {
        pub requests: Arc<Mutex<Vec<String>>>,
        pub status: Arc<AtomicUsize>,
        pub body: Arc<Mutex<Value>>,
    }

    async fn lookup(
        State(service): State<Service>,
        Query(query): Query<HashMap<String, String>>,
    ) -> (axum::http::StatusCode, axum::Json<Value>) {
        service
            .requests
            .lock()
            .unwrap()
            .push(query.get("users").cloned().unwrap_or_default());
        let status =
            axum::http::StatusCode::from_u16(service.status.load(Ordering::SeqCst) as u16).unwrap();
        (status, axum::Json(service.body.lock().unwrap().clone()))
    }

    pub(crate) async fn serve(body: Value) -> (Arc<CommunityCache>, Service) {
        let service = Service {
            requests: Arc::default(),
            status: Arc::new(AtomicUsize::new(200)),
            body: Arc::new(Mutex::new(body)),
        };
        let app = Router::new()
            .route("/lookup", get(lookup))
            .with_state(service.clone());
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        (CommunityCache::new(&format!("http://{addr}")), service)
    }
}

#[cfg(test)]
mod tests {
    use super::test_support::serve;
    use super::*;
    use serde_json::json;
    use std::sync::atomic::Ordering;

    fn record(id: &str) -> Value {
        json!({
            "l": "Switzerland", "d": "Switzerland App Store", "a": false,
            "t": Utc::now().timestamp() - 3600, "c": 1_269_883_297, "id": id, "uc": 2,
        })
    }

    #[tokio::test]
    async fn concurrent_lookups_share_one_request_and_map_the_record() {
        let (cache, service) = serve(json!({
            "results": { "xaitax": record("127580312"), "other": record("7") },
            "misses": [],
        }))
        .await;
        let (a, b) = tokio::join!(
            cache.lookup("127580312", "xAitax"),
            cache.lookup("7", "other")
        );
        let a = a.unwrap();
        assert_eq!(a.rest_id, "127580312");
        assert_eq!(a.handle, "xAitax");
        assert_eq!(a.account_based_in.as_deref(), Some("Switzerland"));
        assert_eq!(a.source.as_deref(), Some("Switzerland App Store"));
        assert_eq!(a.location_accurate, Some(false));
        assert_eq!(a.username_changes, Some(2));
        assert!(a.created_at.is_some());
        assert!(a.community && !a.verified && !a.is_blue_verified);
        assert!(b.is_some());
        let requests = service.requests.lock().unwrap().clone();
        assert_eq!(requests.len(), 1);
        let mut users: Vec<&str> = requests[0].split(',').collect();
        users.sort();
        assert_eq!(users, ["other", "xaitax"]);
    }

    #[tokio::test]
    async fn an_answer_for_another_account_is_refused() {
        let (cache, _) = serve(json!({ "results": { "xaitax": record("999") } })).await;
        assert!(cache.lookup("127580312", "xaitax").await.is_none());
    }

    #[tokio::test]
    async fn stale_or_id_less_records_are_ignored() {
        let mut stale = record("1");
        stale["t"] = json!(Utc::now().timestamp() - 61 * 86_400);
        let mut anonymous = record("2");
        anonymous.as_object_mut().unwrap().remove("id");
        let (cache, _) = serve(json!({ "results": { "stale": stale, "anon": anonymous } })).await;
        assert!(cache.lookup("1", "stale").await.is_none());
        assert!(cache.lookup("2", "anon").await.is_none());
    }

    #[tokio::test]
    async fn an_unknown_handle_is_not_asked_about_again() {
        let (cache, service) = serve(json!({ "results": {}, "misses": ["nobody"] })).await;
        assert!(cache.lookup("5", "nobody").await.is_none());
        assert!(cache.lookup("5", "nobody").await.is_none());
        assert_eq!(service.requests.lock().unwrap().len(), 1);
    }

    #[tokio::test]
    async fn a_failing_service_is_left_alone_for_a_while() {
        let (cache, service) = serve(json!({})).await;
        service.status.store(500, Ordering::SeqCst);
        assert!(cache.lookup("5", "someone").await.is_none());
        assert!(cache.lookup("6", "another").await.is_none());
        assert_eq!(service.requests.lock().unwrap().len(), 1);
    }

    #[tokio::test]
    async fn invalid_handles_never_reach_the_service() {
        let (cache, service) = serve(json!({ "results": {} })).await;
        assert!(cache.lookup("5", "a,b").await.is_none());
        assert!(cache.lookup("5", "").await.is_none());
        assert!(cache.lookup("5", "waytoolonghandle_xyz").await.is_none());
        assert!(service.requests.lock().unwrap().is_empty());
    }

    #[test]
    fn records_tolerate_loose_number_types_and_reject_bad_text() {
        let now = Utc::now();
        let mut loose = record("3");
        loose["t"] = json!(format!("{}", now.timestamp() - 10));
        loose["c"] = json!(1_269_883_297.0);
        let parsed = Record::parse(&loose, now).unwrap();
        assert!(parsed.created_at.is_some());

        let mut control = record("4");
        control["l"] = json!("Swit\nzerland");
        control["d"] = json!("");
        assert!(Record::parse(&control, now).is_none());

        let mut early = record("5");
        early["c"] = json!(1_000);
        assert!(Record::parse(&early, now).unwrap().created_at.is_none());
    }
}
