use crate::error::{Error, Result};
use crate::model::User;
use crate::parse::tweet::decode_html_entities;
use chrono::{DateTime, Utc};
use serde_json::Value;

#[derive(Debug, Clone)]
pub struct RawNotification {
    pub id: String,
    pub notification_type: String,
    pub actors: Vec<User>,
    pub others_count: Option<u64>,
    pub target_tweet_id: Option<String>,
    pub target_tweet_like_count: Option<u64>,
    pub target_tweet_created_at: Option<DateTime<Utc>>,
    pub target_tweet_snippet: Option<String>,
    pub timestamp: DateTime<Utc>,
}

#[derive(Debug, Clone, Default)]
pub struct NotificationPage {
    pub notifications: Vec<RawNotification>,
    pub next_cursor: Option<String>,
    pub top_cursor: Option<String>,
}

pub fn parse_response(response: &Value) -> Result<NotificationPage> {
    let global = response.get("globalObjects").ok_or_else(|| {
        Error::GraphqlShape("missing globalObjects in notification response".into())
    })?;

    let notif_map = global
        .get("notifications")
        .and_then(Value::as_object)
        .ok_or_else(|| Error::GraphqlShape("missing globalObjects.notifications".into()))?;
    let tweets_map = global.get("tweets").and_then(Value::as_object);
    let users_map = global.get("users").and_then(Value::as_object);

    let mut page = NotificationPage::default();

    let instructions = response
        .pointer("/timeline/instructions")
        .and_then(Value::as_array);

    if let Some(instructions) = instructions {
        for instr in instructions {
            if let Some(entries) = instr
                .get("addEntries")
                .and_then(|ae| ae.get("entries"))
                .and_then(Value::as_array)
            {
                for entry in entries {
                    parse_timeline_entry(entry, notif_map, tweets_map, users_map, &mut page);
                }
            }
        }
    }

    if page.notifications.is_empty() && !notif_map.is_empty() {
        for (notif_id, notif_obj) in notif_map {
            if let Some(rn) = build_notification(notif_id, notif_obj, tweets_map, users_map) {
                page.notifications.push(rn);
            }
        }
        page.notifications
            .sort_by(|a, b| b.timestamp.cmp(&a.timestamp));
    }

    Ok(page)
}

pub fn parse_mentions_response(response: &Value) -> Result<NotificationPage> {
    let global = response
        .get("globalObjects")
        .ok_or_else(|| Error::GraphqlShape("missing globalObjects in mentions response".into()))?;

    let tweets_map = global.get("tweets").and_then(Value::as_object);
    let users_map = global.get("users").and_then(Value::as_object);

    let mut page = NotificationPage::default();

    let instructions = response
        .pointer("/timeline/instructions")
        .and_then(Value::as_array);

    let Some(instructions) = instructions else {
        return Ok(page);
    };

    for instr in instructions {
        let Some(entries) = instr
            .get("addEntries")
            .and_then(|ae| ae.get("entries"))
            .and_then(Value::as_array)
        else {
            continue;
        };
        for entry in entries {
            let content = entry.get("content");
            let Some(content) = content else { continue };

            if let Some(op) = content.get("operation") {
                if let Some(cursor) = op.get("cursor") {
                    let cursor_type = cursor
                        .get("cursorType")
                        .and_then(Value::as_str)
                        .unwrap_or("");
                    let value = cursor.get("value").and_then(Value::as_str);
                    if let Some(v) = value {
                        match cursor_type {
                            "Bottom" => page.next_cursor = Some(v.to_string()),
                            "Top" => page.top_cursor = Some(v.to_string()),
                            _ => {}
                        }
                    }
                }
                continue;
            }

            let tweet_id = content
                .pointer("/item/content/tweet/id")
                .and_then(Value::as_str);
            let Some(tweet_id) = tweet_id else { continue };

            let entry_id = entry
                .get("entryId")
                .and_then(Value::as_str)
                .unwrap_or(tweet_id);

            let Some(tweets) = tweets_map else { continue };
            let Some(tweet_obj) = tweets.get(tweet_id) else {
                continue;
            };

            let user_id = tweet_obj.get("user_id_str").and_then(Value::as_str);
            let actor = user_id
                .and_then(|uid| users_map?.get(uid))
                .and_then(|u| parse_v2_user(user_id.unwrap_or("0"), u).ok());

            let created_at = tweet_obj
                .get("created_at")
                .and_then(Value::as_str)
                .and_then(|s| {
                    DateTime::parse_from_str(s, "%a %b %d %H:%M:%S %z %Y")
                        .map(|dt| dt.with_timezone(&Utc))
                        .ok()
                })
                .unwrap_or_else(Utc::now);

            let snippet = tweet_obj.get("full_text").and_then(Value::as_str).map(|t| {
                let decoded = decode_html_entities(t);
                let stripped = strip_leading_mentions(&decoded);
                stripped.chars().take(80).collect::<String>()
            });

            page.notifications.push(RawNotification {
                id: entry_id.to_string(),
                notification_type: "Reply".to_string(),
                actors: actor.into_iter().collect(),
                others_count: None,
                target_tweet_id: Some(tweet_id.to_string()),
                target_tweet_like_count: None,
                target_tweet_created_at: None,
                target_tweet_snippet: snippet,
                timestamp: created_at,
            });
        }
    }

    page.notifications
        .sort_by(|a, b| b.timestamp.cmp(&a.timestamp));

    Ok(page)
}

fn parse_timeline_entry(
    entry: &Value,
    notif_map: &serde_json::Map<String, Value>,
    tweets_map: Option<&serde_json::Map<String, Value>>,
    users_map: Option<&serde_json::Map<String, Value>>,
    page: &mut NotificationPage,
) {
    let sort_index = entry.get("sortIndex").and_then(Value::as_str).unwrap_or("");

    let content = entry.get("content");
    let Some(content) = content else { return };

    let operation = content.get("operation");
    if let Some(op) = operation {
        if let Some(cursor) = op.get("cursor") {
            let cursor_type = cursor
                .get("cursorType")
                .and_then(Value::as_str)
                .unwrap_or("");
            let value = cursor.get("value").and_then(Value::as_str);
            if let Some(v) = value {
                match cursor_type {
                    "Bottom" => page.next_cursor = Some(v.to_string()),
                    "Top" => page.top_cursor = Some(v.to_string()),
                    _ => {}
                }
            }
        }
        return;
    }

    let notif_id = content
        .pointer("/notification/id")
        .and_then(Value::as_str)
        .or_else(|| content.get("id").and_then(Value::as_str))
        .unwrap_or(sort_index);

    if notif_id.is_empty() {
        return;
    }

    if let Some(notif_obj) = notif_map.get(notif_id) {
        if let Some(rn) = build_notification(notif_id, notif_obj, tweets_map, users_map) {
            page.notifications.push(rn);
        }
    }
}

fn build_notification(
    notif_id: &str,
    notif_obj: &Value,
    tweets_map: Option<&serde_json::Map<String, Value>>,
    users_map: Option<&serde_json::Map<String, Value>>,
) -> Option<RawNotification> {
    let icon_name = notif_obj
        .pointer("/icon/id")
        .and_then(Value::as_str)
        .unwrap_or("");

    let notification_type = classify_type(icon_name);

    let timestamp_ms = notif_obj
        .get("timestampMs")
        .and_then(Value::as_str)
        .and_then(|s| s.parse::<i64>().ok())
        .unwrap_or(0);
    let timestamp = DateTime::from_timestamp_millis(timestamp_ms).unwrap_or_else(Utc::now);

    let user_actions = notif_obj
        .pointer("/template/aggregateUserActionsV1/fromUsers")
        .and_then(Value::as_array);
    let actors = resolve_actors(user_actions, users_map);

    let others_count = notif_obj
        .pointer("/message/text")
        .and_then(Value::as_str)
        .and_then(extract_others_count);

    let target_tweet_ids = notif_obj
        .pointer("/template/aggregateUserActionsV1/targetObjects")
        .and_then(Value::as_array);
    let (target_tweet_id, target_tweet_like_count, target_tweet_created_at, target_tweet_snippet) =
        resolve_target_tweet(target_tweet_ids, tweets_map);

    tracing::debug!(
        notif_id,
        notification_type,
        actors = actors.len(),
        target_tweet_id = target_tweet_id.as_deref().unwrap_or("none"),
        "notification entry"
    );

    Some(RawNotification {
        id: notif_id.to_string(),
        notification_type: notification_type.to_string(),
        others_count,
        actors,
        target_tweet_id,
        target_tweet_like_count,
        target_tweet_created_at,
        target_tweet_snippet,
        timestamp,
    })
}

fn classify_type(icon_name: &str) -> &str {
    match icon_name {
        "heart_icon" => "Like",
        "retweet_icon" => "Retweet",
        "person_icon" => "Follow",
        "reply_icon" => "Reply",
        "quote_icon" => "Quote",
        "mention_icon" | "at_icon" => "Mention",
        "conversation_bubble_icon" => "Reply",
        "bell_icon" | "recommendation_icon" | "magic_rec_icon" | "alert_bell_icon" => {
            "Recommendation"
        }
        "bird_icon" | "safety_icon" | "security_alert_icon" | "lock_icon" => "System",
        "list_icon" => "List",
        "communities_icon" | "community_icon" => "Community",
        "spaces_icon" | "space_icon" | "microphone_icon" | "live_icon" => "Spaces",
        "milestone_icon" => "Milestone",
        "trending_icon" | "lightning_bolt_icon" | "news_icon" => "Trending",
        "birdwatch_icon" => "CommunityNote",
        "histogram_icon" => "Poll",
        "topic_icon" => "Topic",
        _ => "Other",
    }
}

fn resolve_actors(
    from_users: Option<&Vec<Value>>,
    users_map: Option<&serde_json::Map<String, Value>>,
) -> Vec<User> {
    let Some(from_users) = from_users else {
        return Vec::new();
    };
    let Some(users_map) = users_map else {
        return Vec::new();
    };
    from_users
        .iter()
        .filter_map(|fu| {
            let user_id = fu.pointer("/user/id").and_then(Value::as_str)?;
            let user_obj = users_map.get(user_id)?;
            parse_v2_user(user_id, user_obj).ok()
        })
        .collect()
}

fn resolve_target_tweet(
    target_objects: Option<&Vec<Value>>,
    tweets_map: Option<&serde_json::Map<String, Value>>,
) -> (
    Option<String>,
    Option<u64>,
    Option<DateTime<Utc>>,
    Option<String>,
) {
    let Some(targets) = target_objects else {
        return (None, None, None, None);
    };
    let Some(tweets_map) = tweets_map else {
        return (None, None, None, None);
    };

    for target in targets {
        let tweet_id = target.pointer("/tweet/id").and_then(Value::as_str);
        let Some(tweet_id) = tweet_id else { continue };
        let Some(tweet_obj) = tweets_map.get(tweet_id) else {
            continue;
        };

        let like_count = tweet_obj.get("favorite_count").and_then(Value::as_u64);
        let created_at = tweet_obj
            .get("created_at")
            .and_then(Value::as_str)
            .and_then(|s| {
                DateTime::parse_from_str(s, "%a %b %d %H:%M:%S %z %Y")
                    .map(|dt| dt.with_timezone(&Utc))
                    .ok()
            });
        let snippet = tweet_obj.get("full_text").and_then(Value::as_str).map(|t| {
            let decoded = decode_html_entities(t);
            let stripped = strip_leading_mentions(&decoded);
            stripped.chars().take(80).collect::<String>()
        });

        return (Some(tweet_id.to_string()), like_count, created_at, snippet);
    }

    (None, None, None, None)
}

fn extract_others_count(text: &str) -> Option<u64> {
    let marker = "and ";
    let idx = text.find(marker)?;
    let after = &text[idx + marker.len()..];
    let num_str: String = after.chars().take_while(|c| c.is_ascii_digit()).collect();
    if num_str.is_empty() {
        return None;
    }
    num_str.parse().ok()
}

fn strip_leading_mentions(text: &str) -> &str {
    let mut rest = text;
    loop {
        rest = rest.trim_start();
        if let Some(after_at) = rest.strip_prefix('@') {
            match after_at.find(|c: char| !c.is_alphanumeric() && c != '_') {
                Some(0) => break,
                Some(end) => rest = &after_at[end..],
                None => return "",
            }
        } else {
            break;
        }
    }
    rest
}

fn parse_v2_user(user_id: &str, obj: &Value) -> Result<User> {
    let handle = obj
        .get("screen_name")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    let name = obj
        .get("name")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    let verified = obj
        .get("ext_is_blue_verified")
        .and_then(Value::as_bool)
        .or_else(|| obj.get("verified").and_then(Value::as_bool))
        .unwrap_or(false);
    let followers = obj
        .get("followers_count")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let following = obj
        .get("friends_count")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    Ok(User {
        rest_id: user_id.to_string(),
        handle,
        name,
        verified,
        followers,
        following,
    })
}
