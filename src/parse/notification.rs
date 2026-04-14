use crate::error::{Error, Result};
use crate::model::User;
use crate::parse::tweet::{decode_html_entities, parse_tweet_result};
use crate::parse::user::parse_user_result;
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

pub fn parse_notifications_timeline(response: &Value) -> Result<NotificationPage> {
    let instructions = find_instructions(response).ok_or_else(|| {
        Error::GraphqlShape(
            "NotificationsTimeline: could not locate timeline.instructions in response".into(),
        )
    })?;

    let mut page = NotificationPage::default();
    let mut reply_count = 0usize;
    let mut grouped_count = 0usize;
    let mut skipped = 0usize;

    for instr in instructions {
        let itype = instr.get("type").and_then(Value::as_str).unwrap_or("");
        if itype != "TimelineAddEntries" {
            continue;
        }
        let Some(entries) = instr.get("entries").and_then(Value::as_array) else {
            continue;
        };
        for entry in entries {
            let entry_id = entry
                .get("entryId")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            let Some(content) = entry.get("content") else {
                skipped += 1;
                continue;
            };

            if let Some(cursor) = extract_cursor(content) {
                match cursor.0.as_str() {
                    "Top" => page.top_cursor = Some(cursor.1),
                    "Bottom" => page.next_cursor = Some(cursor.1),
                    _ => {}
                }
                continue;
            }

            let item_typename = content
                .pointer("/itemContent/__typename")
                .and_then(Value::as_str)
                .unwrap_or("");

            match item_typename {
                "TimelineTweet" => {
                    if let Some(rn) = build_tweet_entry(&entry_id, content) {
                        reply_count += 1;
                        page.notifications.push(rn);
                    } else {
                        skipped += 1;
                        tracing::debug!(entry_id = %entry_id, "TimelineTweet entry failed to parse");
                    }
                }
                "TimelineNotification" => {
                    if let Some(rn) = build_grouped_entry(&entry_id, content) {
                        grouped_count += 1;
                        page.notifications.push(rn);
                    } else {
                        skipped += 1;
                        tracing::debug!(entry_id = %entry_id, "TimelineNotification entry failed to parse");
                    }
                }
                other => {
                    skipped += 1;
                    tracing::debug!(entry_id = %entry_id, kind = %other, "unknown notifications entry, skipped");
                }
            }
        }
    }

    page.notifications
        .sort_by(|a, b| b.timestamp.cmp(&a.timestamp));

    let mut type_counts: std::collections::BTreeMap<&str, usize> =
        std::collections::BTreeMap::new();
    for n in &page.notifications {
        *type_counts.entry(n.notification_type.as_str()).or_insert(0) += 1;
    }
    tracing::info!(
        total = page.notifications.len(),
        replies = reply_count,
        grouped = grouped_count,
        skipped,
        has_top_cursor = page.top_cursor.is_some(),
        has_bottom_cursor = page.next_cursor.is_some(),
        types = ?type_counts,
        "notifications timeline parsed"
    );

    Ok(page)
}

fn find_instructions(response: &Value) -> Option<&Vec<Value>> {
    let candidates = [
        "/data/viewer_v2/user_results/result/notification_timeline/timeline/instructions",
        "/data/viewer/user_results/result/notification_timeline/timeline/instructions",
        "/data/notification_timeline/timeline/instructions",
        "/data/viewer_v2/notification_timeline/timeline/instructions",
    ];
    for path in candidates {
        if let Some(arr) = response.pointer(path).and_then(Value::as_array) {
            return Some(arr);
        }
    }
    None
}

fn extract_cursor(content: &Value) -> Option<(String, String)> {
    let entry_type = content
        .get("entryType")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let typename = content
        .get("__typename")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if entry_type != "TimelineTimelineCursor" && typename != "TimelineTimelineCursor" {
        return None;
    }
    let cursor_type = content
        .get("cursorType")
        .and_then(Value::as_str)?
        .to_string();
    let value = content.get("value").and_then(Value::as_str)?.to_string();
    Some((cursor_type, value))
}

fn build_tweet_entry(_entry_id: &str, content: &Value) -> Option<RawNotification> {
    let result = content.pointer("/itemContent/tweet_results/result")?;
    let tweet = parse_tweet_result(result).ok()?;

    let is_mention = tweet.in_reply_to_tweet_id.is_none();
    let notification_type = if is_mention { "Mention" } else { "Reply" }.to_string();
    let stable_id = format!("tweet-{}", tweet.rest_id);

    Some(RawNotification {
        id: stable_id,
        notification_type,
        actors: vec![tweet.author.clone()],
        others_count: None,
        target_tweet_id: Some(tweet.rest_id.clone()),
        target_tweet_like_count: Some(tweet.like_count),
        target_tweet_created_at: Some(tweet.created_at),
        target_tweet_snippet: Some(tweet.text.clone()),
        timestamp: tweet.created_at,
    })
}

fn build_grouped_entry(entry_id: &str, content: &Value) -> Option<RawNotification> {
    let item = content.get("itemContent")?;

    let icon = item
        .get("notification_icon")
        .and_then(Value::as_str)
        .or_else(|| item.pointer("/icon/id").and_then(Value::as_str))
        .unwrap_or("");
    let element = content
        .pointer("/clientEventInfo/element")
        .and_then(Value::as_str)
        .unwrap_or("");
    let notification_type = classify_type(icon, element);

    let timestamp = parse_notification_timestamp(item).unwrap_or_else(Utc::now);

    let actors = extract_actors(item);
    let others_count = item
        .pointer("/rich_message/text")
        .and_then(Value::as_str)
        .or_else(|| item.pointer("/message/text").and_then(Value::as_str))
        .and_then(extract_others_count);

    let (target_tweet_id, target_tweet_like_count, target_tweet_created_at, target_tweet_snippet) =
        extract_target_tweet(item);

    let stable_id =
        composite_grouped_id(&notification_type, &actors, &target_tweet_id, others_count)
            .unwrap_or_else(|| entry_id.to_string());

    Some(RawNotification {
        id: stable_id,
        notification_type,
        actors,
        others_count,
        target_tweet_id,
        target_tweet_like_count,
        target_tweet_created_at,
        target_tweet_snippet,
        timestamp,
    })
}

fn composite_grouped_id(
    notification_type: &str,
    actors: &[User],
    target_tweet_id: &Option<String>,
    others_count: Option<u64>,
) -> Option<String> {
    if actors.is_empty() && target_tweet_id.is_none() {
        return None;
    }
    let mut handles: Vec<&str> = actors.iter().map(|u| u.handle.as_str()).collect();
    handles.sort_unstable();
    let actors_part = handles.join(",");
    let target_part = target_tweet_id.as_deref().unwrap_or("-");
    let others_part = others_count.unwrap_or(0);
    Some(format!(
        "g-{notification_type}-{target_part}-{actors_part}-{others_part}"
    ))
}

fn parse_notification_timestamp(item: &Value) -> Option<DateTime<Utc>> {
    let v = item.get("timestamp_ms")?;
    if let Some(s) = v.as_str() {
        if let Ok(dt) = DateTime::parse_from_rfc3339(s) {
            return Some(dt.with_timezone(&Utc));
        }
        if let Ok(ms) = s.parse::<i64>() {
            return DateTime::from_timestamp_millis(ms);
        }
    }
    if let Some(ms) = v.as_i64() {
        return DateTime::from_timestamp_millis(ms);
    }
    None
}

fn classify_type(icon_id: &str, element: &str) -> String {
    let by_element = match element {
        "users_liked_your_tweet"
        | "users_liked_your_retweet"
        | "user_liked_your_tweet"
        | "user_liked_multiple_tweets" => Some("Like"),
        "users_retweeted_your_tweet"
        | "users_retweeted_your_retweet"
        | "user_retweeted_your_tweet"
        | "user_retweeted_multiple_tweets" => Some("Retweet"),
        "users_followed_you" | "user_followed_you" => Some("Follow"),
        "user_replied_to_your_tweet" | "users_replied_to_your_tweet" => Some("Reply"),
        "user_quoted_your_tweet" | "users_quoted_your_tweet" => Some("Quote"),
        "user_mentioned_you" | "users_mentioned_you" => Some("Mention"),
        _ => None,
    };
    if let Some(t) = by_element {
        return t.to_string();
    }
    match icon_id {
        "heart_icon" => "Like",
        "retweet_icon" => "Retweet",
        "person_icon" => "Follow",
        "reply_icon" | "conversation_bubble_icon" => "Reply",
        "quote_icon" => "Quote",
        "mention_icon" | "at_icon" => "Mention",
        "milestone_icon" => "Milestone",
        "bell_icon" | "recommendation_icon" | "magic_rec_icon" | "alert_bell_icon" => {
            "Recommendation"
        }
        "bird_icon" | "safety_icon" | "security_alert_icon" | "lock_icon" => "System",
        "list_icon" => "List",
        "communities_icon" | "community_icon" => "Community",
        "spaces_icon" | "space_icon" | "microphone_icon" | "live_icon" => "Spaces",
        "trending_icon" | "lightning_bolt_icon" | "news_icon" => "Trending",
        "birdwatch_icon" => "CommunityNote",
        "histogram_icon" => "Poll",
        "topic_icon" => "Topic",
        _ => "Other",
    }
    .to_string()
}

fn extract_actors(item: &Value) -> Vec<User> {
    let from_users = item
        .pointer("/template/from_users")
        .or_else(|| item.pointer("/template/aggregate_user_actions_v1/from_users"))
        .or_else(|| item.pointer("/template/aggregateUserActionsV1/fromUsers"))
        .and_then(Value::as_array);
    let Some(from_users) = from_users else {
        return Vec::new();
    };
    from_users
        .iter()
        .filter_map(|fu| {
            let result = fu
                .pointer("/user_results/result")
                .or_else(|| fu.pointer("/userResults/result"))?;
            parse_user_result(result)
        })
        .collect()
}

fn extract_target_tweet(
    item: &Value,
) -> (
    Option<String>,
    Option<u64>,
    Option<DateTime<Utc>>,
    Option<String>,
) {
    let targets = item
        .pointer("/template/target_objects")
        .or_else(|| item.pointer("/template/aggregate_user_actions_v1/target_objects"))
        .or_else(|| item.pointer("/template/aggregateUserActionsV1/targetObjects"))
        .and_then(Value::as_array);
    let Some(targets) = targets else {
        return (None, None, None, None);
    };

    for target in targets {
        let result = target
            .pointer("/tweet_results/result")
            .or_else(|| target.pointer("/tweetResults/result"));
        let Some(result) = result else { continue };
        let Ok(tweet) = parse_tweet_result(result) else {
            continue;
        };
        let snippet = decode_html_entities(&tweet.text);
        return (
            Some(tweet.rest_id),
            Some(tweet.like_count),
            Some(tweet.created_at),
            Some(snippet),
        );
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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parses_tweet_entry_as_reply() {
        let response = json!({
            "data": {
                "viewer_v2": {
                    "user_results": {
                        "result": {
                            "notification_timeline": {
                                "timeline": {
                                    "instructions": [{
                                        "type": "TimelineAddEntries",
                                        "entries": [{
                                            "entryId": "tweet-123",
                                            "sortIndex": "1",
                                            "content": {
                                                "entryType": "TimelineTimelineItem",
                                                "itemContent": {
                                                    "__typename": "TimelineTweet",
                                                    "tweet_results": {
                                                        "result": {
                                                            "__typename": "Tweet",
                                                            "rest_id": "123",
                                                            "core": {
                                                                "user_results": {
                                                                    "result": {
                                                                        "__typename": "User",
                                                                        "rest_id": "u1",
                                                                        "is_blue_verified": false,
                                                                        "core": {
                                                                            "screen_name": "alice",
                                                                            "name": "Alice"
                                                                        },
                                                                        "legacy": {
                                                                            "followers_count": 0,
                                                                            "friends_count": 0
                                                                        }
                                                                    }
                                                                }
                                                            },
                                                            "legacy": {
                                                                "created_at": "Tue Apr 14 06:58:00 +0000 2026",
                                                                "full_text": "hello",
                                                                "in_reply_to_status_id_str": "99",
                                                                "reply_count": 0,
                                                                "retweet_count": 0,
                                                                "favorite_count": 0,
                                                                "quote_count": 0,
                                                                "entities": {}
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }]
                                    }]
                                }
                            }
                        }
                    }
                }
            }
        });
        let page = parse_notifications_timeline(&response).unwrap();
        assert_eq!(page.notifications.len(), 1);
        assert_eq!(page.notifications[0].notification_type, "Reply");
        assert_eq!(page.notifications[0].actors[0].handle, "alice");
    }

    #[test]
    fn parses_cursor_entries() {
        let response = json!({
            "data": {
                "viewer_v2": {
                    "user_results": {
                        "result": {
                            "notification_timeline": {
                                "timeline": {
                                    "instructions": [{
                                        "type": "TimelineAddEntries",
                                        "entries": [
                                            {
                                                "entryId": "cursor-top-0",
                                                "content": {
                                                    "entryType": "TimelineTimelineCursor",
                                                    "cursorType": "Top",
                                                    "value": "TOP_CUR"
                                                }
                                            },
                                            {
                                                "entryId": "cursor-bottom-0",
                                                "content": {
                                                    "entryType": "TimelineTimelineCursor",
                                                    "cursorType": "Bottom",
                                                    "value": "BOT_CUR"
                                                }
                                            }
                                        ]
                                    }]
                                }
                            }
                        }
                    }
                }
            }
        });
        let page = parse_notifications_timeline(&response).unwrap();
        assert_eq!(page.top_cursor.as_deref(), Some("TOP_CUR"));
        assert_eq!(page.next_cursor.as_deref(), Some("BOT_CUR"));
    }

    #[test]
    fn classify_by_element_wins_over_icon() {
        assert_eq!(classify_type("heart_icon", "users_followed_you"), "Follow");
        assert_eq!(classify_type("", "users_liked_your_tweet"), "Like");
        assert_eq!(classify_type("reply_icon", ""), "Reply");
    }
}
