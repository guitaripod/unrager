use crate::auth::XSession;
use crate::error::{Error, Result};
use crate::gql::query_ids::{Operation, QueryId, QueryIdStore};
use crate::gql::scraper;
use reqwest::header::{HeaderMap, HeaderName, HeaderValue};
use serde_json::Value;
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::Duration;
use tokio::sync::Mutex as AsyncMutex;
use tokio::time::{Instant, sleep_until};

const WEB_BEARER: &str = "AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA";

const GQL_BASE: &str = "https://x.com/i/api/graphql";
const MIN_INTERVAL: Duration = Duration::from_millis(400);
const USER_AGENT: &str = "Mozilla/5.0 (X11; Linux x86_64; rv:133.0) Gecko/20100101 Firefox/133.0";

pub struct GqlClient {
    http: reqwest::Client,
    session: XSession,
    store: Mutex<QueryIdStore>,
    cache_path: PathBuf,
    next_allowed: AsyncMutex<Instant>,
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
        Ok(Self {
            http,
            session,
            store: Mutex::new(store),
            cache_path,
            next_allowed: AsyncMutex::new(Instant::now()),
        })
    }

    pub async fn get(&self, op: Operation, variables: &Value, features: &Value) -> Result<Value> {
        self.call(Method::Get, op, variables, features).await
    }

    pub async fn post(&self, op: Operation, variables: &Value, features: &Value) -> Result<Value> {
        self.call(Method::Post, op, variables, features).await
    }

    async fn call(
        &self,
        method: Method,
        op: Operation,
        variables: &Value,
        features: &Value,
    ) -> Result<Value> {
        match self.call_once(&method, op, variables, features).await {
            Ok(v) => Ok(v),
            Err(Error::GraphqlStatus { status: 404, .. })
            | Err(Error::GraphqlStatus { status: 400, .. }) => {
                tracing::warn!("{} returned stale query id, refreshing", op.name());
                self.refresh_query_ids().await?;
                self.call_once(&method, op, variables, features).await
            }
            Err(e) => Err(e),
        }
    }

    async fn call_once(
        &self,
        method: &Method,
        op: Operation,
        variables: &Value,
        features: &Value,
    ) -> Result<Value> {
        let qid = self.lookup_qid(op).ok_or_else(|| {
            Error::GraphqlShape(format!("no query id for operation {}", op.name()))
        })?;
        let url = format!("{GQL_BASE}/{}/{}", qid.id, op.name());

        self.throttle().await;

        let req = match method {
            Method::Get => {
                let vars_json = serde_json::to_string(variables)?;
                let features_json = serde_json::to_string(features)?;
                let query = [
                    ("variables", vars_json.as_str()),
                    ("features", features_json.as_str()),
                ];
                self.http.get(&url).headers(self.headers()?).query(&query)
            }
            Method::Post => {
                let body = serde_json::json!({
                    "variables": variables,
                    "features": features,
                    "queryId": qid.id,
                });
                self.http.post(&url).headers(self.headers()?).json(&body)
            }
        };

        let res = req.send().await?;
        self.parse(res).await
    }

    pub async fn raw_get(&self, url: &str, query: &[(&str, &str)]) -> Result<Value> {
        self.throttle().await;
        let res = self
            .http
            .get(url)
            .headers(self.headers()?)
            .query(query)
            .send()
            .await?;
        self.parse(res).await
    }

    fn lookup_qid(&self, op: Operation) -> Option<QueryId> {
        self.store.lock().ok()?.get(op).cloned()
    }

    async fn refresh_query_ids(&self) -> Result<()> {
        let fresh = scraper::scrape(&self.http).await?;
        let snapshot = {
            let mut guard = self
                .store
                .lock()
                .map_err(|_| Error::Config("query id store poisoned".into()))?;
            guard.merge_iter(fresh);
            guard.clone()
        };
        if let Err(e) = snapshot.save_cached(&self.cache_path) {
            tracing::warn!("failed to persist query id cache: {e}");
        }
        Ok(())
    }

    async fn throttle(&self) {
        let wait_until = {
            let mut guard = self.next_allowed.lock().await;
            let now = Instant::now();
            let target = if *guard > now { *guard } else { now };
            *guard = target + MIN_INTERVAL;
            target
        };
        sleep_until(wait_until).await;
    }

    fn headers(&self) -> Result<HeaderMap> {
        let mut h = HeaderMap::new();
        let cookie = format!(
            "auth_token={}; ct0={}; twid={}",
            self.session.auth_token, self.session.ct0, self.session.twid
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
            HeaderValue::from_str(&self.session.ct0)
                .map_err(|e| Error::GraphqlShape(e.to_string()))?,
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
            reqwest::header::CONTENT_TYPE,
            HeaderValue::from_static("application/json"),
        );
        h.insert(reqwest::header::ACCEPT, HeaderValue::from_static("*/*"));
        h.insert(
            HeaderName::from_static("referer"),
            HeaderValue::from_static("https://x.com/"),
        );
        h.insert(
            HeaderName::from_static("origin"),
            HeaderValue::from_static("https://x.com"),
        );
        Ok(h)
    }

    async fn parse(&self, res: reqwest::Response) -> Result<Value> {
        let status = res.status();
        let body = res.text().await?;
        if !status.is_success() {
            return Err(Error::GraphqlStatus {
                status: status.as_u16(),
                body: truncate(&body, 400),
            });
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
            return Err(Error::GraphqlShape(format!(
                "graphql errors: {}",
                truncate(&errors[0].to_string(), 400)
            )));
        }
        Ok(value)
    }
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
    use super::truncate;

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
