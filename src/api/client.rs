use crate::auth::oauth;
use crate::error::{Error, Result};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::time::Duration;

const TWEETS_ENDPOINT: &str = "https://api.x.com/2/tweets";

#[derive(Debug, Clone, Serialize)]
pub struct PostRequest {
    pub text: String,
    pub in_reply_to_tweet_id: Option<String>,
}

impl PostRequest {
    pub fn to_json(&self) -> Value {
        let mut body = json!({ "text": self.text });
        if let Some(ref reply_to) = self.in_reply_to_tweet_id {
            body["reply"] = json!({ "in_reply_to_tweet_id": reply_to });
        }
        body
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct PostedTweet {
    pub id: String,
    pub text: String,
}

impl PostedTweet {
    pub fn url(&self) -> String {
        format!("https://x.com/i/web/status/{}", self.id)
    }
}

pub struct ApiClient {
    http: reqwest::Client,
    access_token: String,
}

impl ApiClient {
    pub async fn new() -> Result<Self> {
        let tokens = oauth::load_or_authorize().await?;
        let http = reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(10))
            .timeout(Duration::from_secs(30))
            .build()?;
        Ok(Self {
            http,
            access_token: tokens.access_token,
        })
    }

    pub async fn post(&self, request: &PostRequest) -> Result<PostedTweet> {
        let body = request.to_json();
        let res = self
            .http
            .post(TWEETS_ENDPOINT)
            .bearer_auth(&self.access_token)
            .json(&body)
            .send()
            .await?;

        let status = res.status();
        let text = res.text().await?;
        if !status.is_success() {
            return Err(classify_post_error(status.as_u16(), &text));
        }

        let parsed: Value = serde_json::from_str(&text)?;
        let data = parsed
            .get("data")
            .ok_or_else(|| Error::GraphqlShape(format!("post response missing data: {text}")))?;
        let posted: PostedTweet = serde_json::from_value(data.clone())?;
        Ok(posted)
    }
}

fn classify_post_error(status: u16, body: &str) -> Error {
    if status == 403 && (body.contains("insufficient") || body.contains("credit")) {
        return Error::Config(format!(
            "403: insufficient credits for the write. \
             Top up at console.x.com > Billing > Credits. Raw: {body}"
        ));
    }
    if status == 401 {
        return Error::Config(format!(
            "401: access token rejected. Delete ~/.config/unrager/tokens.json and re-authorize. Raw: {body}"
        ));
    }
    Error::GraphqlStatus {
        status,
        body: body.to_string(),
    }
}
