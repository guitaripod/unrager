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
    /// Whether the authenticated viewer follows this user. Populated on
    /// profile payloads (X's `UserByScreenName` relationship perspective);
    /// absent on timeline authors and older servers, so it stays optional
    /// and is omitted from the wire when unknown.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub followed_by_me: Option<bool>,
    /// The profile's header image, sized for a phone-width banner. Populated
    /// on profile payloads only; absent when the account has none or on
    /// older servers, and omitted from the wire when unknown.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub banner_url: Option<String>,
    /// The profile's bio with its t.co links expanded. Populated on profile
    /// payloads; omitted when empty or unknown.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    /// The free-text location the account gives. Omitted when empty.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub location: Option<String>,
    /// The profile's website, as the full URL rather than its t.co link.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub website: Option<String>,
    /// When the account was created, as an RFC 3339 timestamp.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub joined_at: Option<String>,
    /// Whether the account's posts are protected. Omitted when false.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub protected: bool,
    /// Whether the signed-in user mutes this account; omitted when unknown.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub muting: Option<bool>,
    /// Whether the signed-in user blocks this account; omitted when unknown.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub blocking: Option<bool>,
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
    /// The handle of the account this is a reply to (X's
    /// `in_reply_to_screen_name`), so a client can say who a reply is
    /// addressed to without the leading `@mentions` in its text. Absent on
    /// older servers, and omitted from the wire when unknown.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub in_reply_to_handle: Option<String>,
    pub quoted_tweet: Option<Box<Tweet>>,
    pub media: Vec<Media>,
    pub url: String,
    #[serde(default)]
    pub urls: Vec<TweetUrl>,
    /// Set when this post reached the timeline as someone's repost: the post
    /// itself is the original (its id, author, text and counts), and this is
    /// the account that reposted it. Absent on ordinary posts and older
    /// servers, and omitted from the wire when unset.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub retweeted_by: Option<User>,
}

impl Tweet {
    /// Whether this post is a repost. Posts stored before reposts were parsed
    /// as their original only carry X's `RT @handle:` text, so that prefix
    /// still counts.
    pub fn is_repost(&self) -> bool {
        self.retweeted_by.is_some() || self.text.starts_with("RT @")
    }
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
    /// Natural pixel width of the source media (photo `original_info`, or the
    /// numerator of a video/GIF `aspect_ratio`). `None` for non-visual kinds.
    /// Clients use `width`/`height` to size the attachment to its true aspect
    /// instead of assuming 16:9.
    #[serde(default)]
    pub width: Option<u32>,
    /// Natural pixel height of the source media, paired with [`Media::width`].
    #[serde(default)]
    pub height: Option<u32>,
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
    /// Filled from the X-Posed community cache rather than X: the country,
    /// device and a few counters, with verification and the display name
    /// unknown. Omitted when false.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub community: bool,
}
