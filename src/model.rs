use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct User {
    pub rest_id: String,
    pub handle: String,
    pub name: String,
    pub verified: bool,
    pub followers: u64,
    pub following: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Tweet {
    pub rest_id: String,
    pub author: User,
    pub created_at: DateTime<Utc>,
    pub text: String,
    pub reply_count: u64,
    pub retweet_count: u64,
    pub like_count: u64,
    pub quote_count: u64,
    pub view_count: Option<u64>,
    #[serde(default)]
    pub favorited: bool,
    #[serde(default)]
    pub retweeted: bool,
    #[serde(default)]
    pub bookmarked: bool,
    pub lang: Option<String>,
    pub in_reply_to_tweet_id: Option<String>,
    pub quoted_tweet: Option<Box<Tweet>>,
    pub media: Vec<Media>,
    pub url: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Media {
    pub kind: MediaKind,
    pub url: String,
    #[serde(default)]
    pub video_url: Option<String>,
    pub alt_text: Option<String>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MediaKind {
    Photo,
    Video,
    AnimatedGif,
}
