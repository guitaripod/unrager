use crate::auth::XSession;
use crate::error::{Error, Result};
use crate::gql::query_ids::{Operation, QueryIdStore};
use reqwest::header::{HeaderMap, HeaderName, HeaderValue};
use serde_json::Value;
use std::time::Duration;
use tokio::sync::Mutex;
use tokio::time::{Instant, sleep_until};

pub const WEB_BEARER: &str = "AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA";

const GQL_BASE: &str = "https://x.com/i/api/graphql";
const MIN_INTERVAL: Duration = Duration::from_millis(400);

pub struct GqlClient {
    http: reqwest::Client,
    session: XSession,
    store: QueryIdStore,
    next_allowed: Mutex<Instant>,
}

impl GqlClient {
    pub fn new(session: XSession, store: QueryIdStore) -> Result<Self> {
        let http = reqwest::Client::builder()
            .user_agent("Mozilla/5.0 (X11; Linux x86_64; rv:133.0) Gecko/20100101 Firefox/133.0")
            .connect_timeout(Duration::from_secs(10))
            .timeout(Duration::from_secs(30))
            .build()?;
        Ok(Self {
            http,
            session,
            store,
            next_allowed: Mutex::new(Instant::now()),
        })
    }

    pub fn session(&self) -> &XSession {
        &self.session
    }

    pub async fn get(
        &self,
        op: Operation,
        variables: &Value,
        features: &Value,
    ) -> Result<Value> {
        let qid = self
            .store
            .get(op)
            .ok_or_else(|| Error::GraphqlShape(format!("no query id for operation {}", op.name())))?;
        let url = format!("{GQL_BASE}/{}/{}", qid.id, op.name());

        let vars_json = serde_json::to_string(variables)?;
        let features_json = serde_json::to_string(features)?;
        let query = [
            ("variables", vars_json.as_str()),
            ("features", features_json.as_str()),
        ];

        self.throttle().await;

        let res = self
            .http
            .get(&url)
            .headers(self.headers()?)
            .query(&query)
            .send()
            .await?;

        self.parse(res).await
    }

    pub async fn post(
        &self,
        op: Operation,
        variables: &Value,
        features: &Value,
    ) -> Result<Value> {
        let qid = self
            .store
            .get(op)
            .ok_or_else(|| Error::GraphqlShape(format!("no query id for operation {}", op.name())))?;
        let url = format!("{GQL_BASE}/{}/{}", qid.id, op.name());

        let body = serde_json::json!({
            "variables": variables,
            "features": features,
            "queryId": qid.id,
        });

        self.throttle().await;

        let res = self
            .http
            .post(&url)
            .headers(self.headers()?)
            .json(&body)
            .send()
            .await?;

        self.parse(res).await
    }

    async fn throttle(&self) {
        let mut guard = self.next_allowed.lock().await;
        let now = Instant::now();
        if *guard > now {
            let wait_until = *guard;
            drop(guard);
            sleep_until(wait_until).await;
            let mut guard = self.next_allowed.lock().await;
            *guard = Instant::now() + MIN_INTERVAL;
        } else {
            *guard = now + MIN_INTERVAL;
        }
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
        h.insert(
            reqwest::header::ACCEPT,
            HeaderValue::from_static("*/*"),
        );
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
        let value: Value = serde_json::from_str(&body)?;
        if let Some(errors) = value.get("errors").and_then(Value::as_array) {
            if !errors.is_empty() {
                return Err(Error::GraphqlShape(format!(
                    "graphql errors: {}",
                    truncate(&errors[0].to_string(), 400)
                )));
            }
        }
        Ok(value)
    }
}

fn truncate(s: &str, max: usize) -> String {
    if s.len() <= max {
        s.to_string()
    } else {
        format!("{}…", &s[..max])
    }
}
