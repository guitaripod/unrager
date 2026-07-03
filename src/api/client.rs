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
    pub quote_tweet_id: Option<String>,
    pub media_ids: Vec<String>,
}

impl PostRequest {
    pub fn to_json(&self) -> Value {
        let mut body = json!({ "text": self.text });
        if let Some(ref reply_to) = self.in_reply_to_tweet_id {
            body["reply"] = json!({ "in_reply_to_tweet_id": reply_to });
        }
        if let Some(ref quote) = self.quote_tweet_id {
            body["quote_tweet_id"] = json!(quote);
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
        self.post_composed(text, in_reply_to_tweet_id, None, media_files, &[])
            .await
    }

    /// Full compose surface: uploads `media_files`, appends any pre-uploaded
    /// `media_ids`, and supports quoting a tweet.
    pub async fn post_composed(
        &self,
        text: &str,
        in_reply_to_tweet_id: Option<&str>,
        quote_tweet_id: Option<&str>,
        media_files: &[MediaFile],
        media_ids: &[String],
    ) -> Result<PostedTweet> {
        let mut ids = Vec::with_capacity(media_files.len() + media_ids.len());
        if !media_files.is_empty() {
            let uploader = MediaUploader::new(&self.http, &self.access_token);
            for file in media_files {
                let id = uploader.upload(file).await?;
                tracing::debug!("uploaded {} → media_id {id}", file.path.display());
                ids.push(id);
            }
        }
        ids.extend(media_ids.iter().cloned());
        let request = PostRequest {
            text: text.to_string(),
            in_reply_to_tweet_id: in_reply_to_tweet_id.map(str::to_string),
            quote_tweet_id: quote_tweet_id.map(str::to_string),
            media_ids: ids,
        };
        self.post_request(&request).await
    }

    /// Upload a single media file and return its media id without posting
    /// anything. Backs `POST /api/media/upload`.
    pub async fn upload_media(&self, file: &MediaFile) -> Result<String> {
        MediaUploader::new(&self.http, &self.access_token)
            .upload(file)
            .await
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
    if is_credits_depleted(status, body) {
        return Error::Config(format!(
            "{status}: credits depleted. \
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

fn is_credits_depleted(status: u16, body: &str) -> bool {
    (status == 402 || status == 403)
        && (body.contains("CreditsDepleted")
            || body.contains("credits to fulfill")
            || body.contains("insufficient")
            || body.contains("\"type\":\"https://api.twitter.com/2/problems/credits\""))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn post_request_minimal_text_only() {
        let req = PostRequest {
            text: "hello".into(),
            in_reply_to_tweet_id: None,
            quote_tweet_id: None,
            media_ids: vec![],
        };
        assert_eq!(req.to_json(), json!({"text": "hello"}));
    }

    #[test]
    fn post_request_carries_quote_tweet_id() {
        let req = PostRequest {
            text: "take".into(),
            in_reply_to_tweet_id: None,
            quote_tweet_id: Some("123".into()),
            media_ids: vec![],
        };
        assert_eq!(
            req.to_json(),
            json!({"text": "take", "quote_tweet_id": "123"})
        );
    }

    #[test]
    fn post_request_full_shape() {
        let req = PostRequest {
            text: "all".into(),
            in_reply_to_tweet_id: Some("9".into()),
            quote_tweet_id: Some("123".into()),
            media_ids: vec!["m1".into(), "m2".into()],
        };
        assert_eq!(
            req.to_json(),
            json!({
                "text": "all",
                "reply": {"in_reply_to_tweet_id": "9"},
                "quote_tweet_id": "123",
                "media": {"media_ids": ["m1", "m2"]}
            })
        );
    }
}
