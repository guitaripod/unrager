use crate::api::media::{MediaFile, MediaUploader};
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
    pub media_ids: Vec<String>,
}

impl PostRequest {
    pub fn to_json(&self) -> Value {
        let mut body = json!({ "text": self.text });
        if let Some(ref reply_to) = self.in_reply_to_tweet_id {
            body["reply"] = json!({ "in_reply_to_tweet_id": reply_to });
        }
        if !self.media_ids.is_empty() {
            body["media"] = json!({ "media_ids": self.media_ids });
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
            .timeout(Duration::from_secs(120))
            .build()?;
        Ok(Self {
            http,
            access_token: tokens.access_token,
        })
    }

    pub async fn post_with_media(
        &self,
        text: &str,
        in_reply_to_tweet_id: Option<&str>,
        media_files: &[MediaFile],
    ) -> Result<PostedTweet> {
        let media_ids = if media_files.is_empty() {
            Vec::new()
        } else {
            let uploader = MediaUploader::new(&self.http, &self.access_token);
            let mut ids = Vec::with_capacity(media_files.len());
            for file in media_files {
                let id = uploader.upload(file).await?;
                tracing::debug!("uploaded {} → media_id {id}", file.path.display());
                ids.push(id);
            }
            ids
        };
        let request = PostRequest {
            text: text.to_string(),
            in_reply_to_tweet_id: in_reply_to_tweet_id.map(str::to_string),
            media_ids,
        };
        self.post_request(&request).await
    }

    async fn post_request(&self, request: &PostRequest) -> Result<PostedTweet> {
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

        let parsed: Value = serde_json::from_str(&text).map_err(|e| {
            Error::GraphqlShape(format!("post response was not valid json ({e}): {text}"))
        })?;
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
            "401: access token rejected. \
             Delete ~/.config/unrager/tokens.json and re-authorize. Raw: {body}"
        ));
    }
    Error::GraphqlStatus {
        status,
        body: body.to_string(),
    }
}
