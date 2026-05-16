use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct User {
    pub rest_id: String,
    pub handle: String,
    pub name: String,
    pub verified: bool,
    pub followers: u64,
    pub following: u64,
    #[serde(default)]
    pub avatar_url: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
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
    pub bookmark_count: u64,
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
    #[serde(default)]
    pub urls: Vec<TweetUrl>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TweetUrl {
    pub expanded_url: String,
    pub display_url: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Media {
    pub kind: MediaKind,
    pub url: String,
    #[serde(default)]
    pub video_url: Option<String>,
    pub alt_text: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MediaKind {
    Photo,
    Video,
    AnimatedGif,
    YouTube {
        video_id: String,
    },
    Article {
        article_id: String,
        title: String,
        preview_text: String,
    },
    LinkCard {
        title: String,
        description: String,
        domain: String,
        target_url: String,
    },
    Broadcast {
        broadcast_id: String,
        title: String,
        broadcaster_name: String,
        is_live: bool,
    },
    Poll {
        options: Vec<PollOption>,
        ends_at: Option<DateTime<Utc>>,
        counts_final: bool,
    },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PollOption {
    pub label: String,
    pub count: u64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AboutProfile {
    pub rest_id: String,
    pub handle: String,
    pub name: String,
    #[serde(default)]
    pub account_based_in: Option<String>,
    #[serde(default)]
    pub location_accurate: Option<bool>,
    #[serde(default)]
    pub source: Option<String>,
    #[serde(default)]
    pub username_changes: Option<u64>,
    #[serde(default)]
    pub affiliate_username: Option<String>,
    #[serde(default)]
    pub created_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub is_blue_verified: bool,
    #[serde(default)]
    pub verified: bool,
    #[serde(default)]
    pub verified_since: Option<DateTime<Utc>>,
}
