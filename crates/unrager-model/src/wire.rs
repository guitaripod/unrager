use crate::tweet::{AboutProfile, Tweet, User};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

/// Outcome class of `GET /api/about/{rest_id}`. Serializes lowercase.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AboutStatus {
    /// X returned an `about_profile` for the user; `profile` is present and
    /// `alpha2`/`flag` are derived server-side from `account_based_in`
    /// (still absent when the user hasn't set a country). Cacheable.
    Resolved,
    /// X has no `about_profile` for this user. Clients may cache for the
    /// session — there is nothing to show.
    None,
    /// Rate-limited or transient upstream failure. Clients must NOT cache;
    /// retry later with backoff.
    Deferred,
}

/// Wire response for `GET /api/about/{rest_id}?screen_name={handle}`.
/// `profile`, `alpha2`, and `flag` are omitted when absent; clients must
/// also accept explicit `null`s.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AboutView {
    pub status: AboutStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub profile: Option<AboutProfile>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub alpha2: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub flag: Option<String>,
}

impl AboutView {
    pub fn resolved(profile: AboutProfile, alpha2: Option<String>, flag: Option<String>) -> Self {
        Self {
            status: AboutStatus::Resolved,
            profile: Some(profile),
            alpha2,
            flag,
        }
    }

    pub fn none() -> Self {
        Self {
            status: AboutStatus::None,
            profile: None,
            alpha2: None,
            flag: None,
        }
    }

    pub fn deferred() -> Self {
        Self {
            status: AboutStatus::Deferred,
            profile: None,
            alpha2: None,
            flag: None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TimelinePage {
    pub tweets: Vec<Tweet>,
    pub cursor: Option<String>,
}

/// Freshness of one materialized Home variant, reported by `GET /api/feed/status`
/// so clients can show "updated Nm ago". `age_secs` is `-1` when the variant has
/// never been ingested (cold buffer).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FeedStatus {
    pub variant: String,
    pub last_ingest_at: i64,
    pub last_ingest_count: i64,
    pub age_secs: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FeedStatusResponse {
    pub feeds: Vec<FeedStatus>,
}

/// One page of a thread. The first page always carries `focal` (the server
/// 404s when the focal tweet is genuinely absent); cursor continuation pages
/// omit it entirely — they only append replies, and clients keep rendering
/// the focal they already have.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ThreadView {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub focal: Option<Tweet>,
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
    #[serde(default)]
    pub avatar_url: Option<String>,
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
    /// Media on the target tweet (when the notification is about a post with
    /// attachments), so clients can show a thumbnail. Empty otherwise.
    #[serde(default)]
    pub target_media: Vec<crate::Media>,
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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn sample_profile() -> AboutProfile {
        AboutProfile {
            rest_id: "42".into(),
            handle: "someone".into(),
            name: "Someone".into(),
            account_based_in: Some("United States".into()),
            location_accurate: Some(true),
            source: None,
            username_changes: None,
            affiliate_username: None,
            created_at: None,
            is_blue_verified: false,
            verified: false,
            verified_since: None,
        }
    }

    #[test]
    fn about_status_serializes_lowercase() {
        assert_eq!(
            serde_json::to_string(&AboutStatus::Resolved).unwrap(),
            r#""resolved""#
        );
        assert_eq!(
            serde_json::to_string(&AboutStatus::None).unwrap(),
            r#""none""#
        );
        assert_eq!(
            serde_json::to_string(&AboutStatus::Deferred).unwrap(),
            r#""deferred""#
        );
    }

    #[test]
    fn about_view_resolved_carries_profile_alpha2_flag() {
        let view = AboutView::resolved(sample_profile(), Some("US".into()), Some("🇺🇸".into()));
        let v = serde_json::to_value(&view).unwrap();
        assert_eq!(v["status"], "resolved");
        assert_eq!(v["alpha2"], "US");
        assert_eq!(v["flag"], "🇺🇸");
        assert_eq!(v["profile"]["rest_id"], "42");
        assert_eq!(v["profile"]["account_based_in"], "United States");
    }

    #[test]
    fn about_view_none_and_deferred_omit_absent_fields() {
        for view in [AboutView::none(), AboutView::deferred()] {
            let v = serde_json::to_value(&view).unwrap();
            let obj = v.as_object().unwrap();
            assert_eq!(obj.len(), 1, "only status should serialize: {v}");
            assert!(obj.contains_key("status"));
        }
    }

    #[test]
    fn about_view_decodes_explicit_nulls() {
        let view: AboutView = serde_json::from_str(
            r#"{"status":"deferred","profile":null,"alpha2":null,"flag":null}"#,
        )
        .unwrap();
        assert_eq!(view, AboutView::deferred());
        let view: AboutView =
            serde_json::from_str(r#"{"status":"none","profile":null,"alpha2":null,"flag":null}"#)
                .unwrap();
        assert_eq!(view, AboutView::none());
    }

    #[test]
    fn about_view_decodes_omitted_fields() {
        let view: AboutView = serde_json::from_str(r#"{"status":"none"}"#).unwrap();
        assert_eq!(view, AboutView::none());
    }

    #[test]
    fn about_view_roundtrips() {
        let view = AboutView::resolved(sample_profile(), Some("US".into()), Some("🇺🇸".into()));
        let json = serde_json::to_string(&view).unwrap();
        let back: AboutView = serde_json::from_str(&json).unwrap();
        assert_eq!(back, view);
    }

    #[test]
    fn about_view_resolved_without_country_still_resolved() {
        let mut profile = sample_profile();
        profile.account_based_in = None;
        let view = AboutView::resolved(profile, None, None);
        let v = serde_json::to_value(&view).unwrap();
        assert_eq!(v["status"], "resolved");
        assert!(v.as_object().unwrap().contains_key("profile"));
        assert!(!v.as_object().unwrap().contains_key("alpha2"));
        assert!(!v.as_object().unwrap().contains_key("flag"));
    }

    #[test]
    fn about_view_exact_wire_shape_for_deferred() {
        let v = serde_json::to_value(AboutView::deferred()).unwrap();
        assert_eq!(v, json!({"status": "deferred"}));
    }
}
