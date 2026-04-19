use crate::tweet::{Tweet, User};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TimelinePage {
    pub tweets: Vec<Tweet>,
    pub cursor: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ThreadView {
    pub focal: Tweet,
    #[serde(default)]
    pub ancestors: Vec<Tweet>,
    #[serde(default)]
    pub replies: Vec<Tweet>,
    pub cursor: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ProfileView {
    pub user: User,
    pub pinned: Option<Tweet>,
    #[serde(default)]
    pub recent: Vec<Tweet>,
    pub cursor: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Verdict {
    Hide,
    Keep,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FilterVerdictEvent {
    pub id: String,
    pub verdict: Verdict,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TokenEvent {
    #[serde(default)]
    pub token: String,
    #[serde(default)]
    pub done: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BriefChunk {
    #[serde(default)]
    pub token: String,
    #[serde(default)]
    pub done: bool,
    #[serde(default)]
    pub tweet_count: Option<u64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AskPreset {
    Explain,
    Summary,
    Counter,
    Eli5,
    Entities,
}

impl AskPreset {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Explain => "explain",
            Self::Summary => "summary",
            Self::Counter => "counter",
            Self::Eli5 => "eli5",
            Self::Entities => "entities",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FilterTopic {
    pub name: String,
    pub description: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct NotificationActor {
    pub handle: String,
    pub name: String,
    pub rest_id: String,
    #[serde(default)]
    pub verified: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Notification {
    pub id: String,
    #[serde(rename = "type")]
    pub kind: String,
    #[serde(default)]
    pub actors: Vec<NotificationActor>,
    #[serde(default)]
    pub target_tweet_id: Option<String>,
    #[serde(default)]
    pub target_tweet_snippet: Option<String>,
    #[serde(default)]
    pub target_tweet_like_count: Option<u64>,
    pub timestamp: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ComposeResult {
    pub id: String,
    pub url: String,
    #[serde(default)]
    pub idempotent: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct NotificationsPage {
    #[serde(default)]
    pub notifications: Vec<Notification>,
    #[serde(default)]
    pub cursor: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct SessionState {
    pub current_source: Option<crate::source::SourceKind>,
    #[serde(default)]
    pub feed_mode: crate::source::FeedMode,
    #[serde(default)]
    pub filter_enabled: bool,
    #[serde(default)]
    pub theme: Option<String>,
}
