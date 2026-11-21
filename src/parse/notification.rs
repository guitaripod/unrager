use crate::error::{Error, Result};
use crate::model::{Media, User};
use crate::parse::tweet::{decode_html_entities, parse_legacy_post, parse_tweet_result};
use crate::parse::user::parse_user_result;
use chrono::{DateTime, Utc};
use serde_json::Value;

#[derive(Debug, Clone)]
pub struct RawNotification {
    pub id: String,
    pub notification_type: String,
    pub actors: Vec<User>,
    pub others_count: Option<u64>,
    /// X's fully rendered notification text ("Your poll has ended", "A and 3
    /// others liked your post"), so actor-less kinds don't degrade to
    /// "Someone <type>".
    pub message: Option<String>,
    pub target_tweet_id: Option<String>,
    pub target_tweet_like_count: Option<u64>,
    pub target_tweet_created_at: Option<DateTime<Utc>>,
    pub target_tweet_snippet: Option<String>,
    pub target_tweet_favorited: bool,
    pub target_media: Vec<Media>,
    /// Where X sends a reader who opens the notification when that isn't a
    /// post in `target_tweet_id`: a Community Note's page, for one.
    pub url: Option<String>,
    pub timestamp: DateTime<Utc>,
}

/// The type of a "New post notifications for …" row, about a post by an
/// account the user asked to be told about.
pub const POST_TYPE: &str = "Post";

impl RawNotification {
    /// How many people the notification stands for: everyone listed, or the
    /// first name plus X's "and N others" when that says more.
    pub fn people_count(&self) -> u64 {
        let listed = self.actors.len() as u64;
        match self.others_count {
            Some(others) if !self.actors.is_empty() => listed.max(1 + others),
            _ => listed,
        }
    }

    /// Whether this is a "New post" row X sent without the post, which the
    /// account's followed-posts timeline has (see [`attach_followed_posts`]).
    pub fn wants_followed_post(&self) -> bool {
        self.notification_type == POST_TYPE && self.target_tweet_id.is_none()
    }
}

#[derive(Debug, Clone, Default)]
pub struct NotificationPage {
    pub notifications: Vec<RawNotification>,
    pub next_cursor: Option<String>,
    pub top_cursor: Option<String>,
    /// X's own read marker for the account (`TimelineMarkEntriesUnreadGreaterThanSortIndex`),
    /// in milliseconds: a notification whose sort index is above it is unread
    /// on x.com. Only a first page carries it.
    pub unread_after_ms: Option<i64>,
}

impl NotificationPage {
    /// The newest notification time on the page, which a client that has shown
    /// the whole page has read up to.
    pub fn newest_ms(&self) -> Option<i64> {
        self.notifications
            .iter()
            .map(|n| n.timestamp.timestamp_millis())
            .max()
    }
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
        if itype == "TimelineMarkEntriesUnreadGreaterThanSortIndex" {
            page.unread_after_ms = instr
                .get("sort_index")
                .and_then(Value::as_str)
                .and_then(|s| s.parse().ok());
            continue;
        }
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
        .sort_by_key(|n| std::cmp::Reverse(n.timestamp));
    merge_repeated_groups(&mut page.notifications);

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
        message: None,
        target_tweet_id: Some(tweet.rest_id.clone()),
        target_tweet_like_count: Some(tweet.like_count),
        target_tweet_created_at: Some(tweet.created_at),
        target_tweet_snippet: Some(tweet.text.clone()),
        target_tweet_favorited: tweet.favorited,
        target_media: tweet.media.clone(),
        url: None,
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

    let actors = extract_actors(item);
    let message = item
        .pointer("/rich_message/text")
        .and_then(Value::as_str)
        .or_else(|| item.pointer("/message/text").and_then(Value::as_str))
        .map(|s| decode_html_entities(s.trim()));
    let others_count = message.as_deref().and_then(extract_others_count);

    let target = extract_target_tweet(item);
    let target_tweet_id = target.as_ref().map(|t| t.id.clone());
    let snippet = match &target {
        Some(target) => Some(target.snippet.clone()),
        None => attached_note(item),
    };

    // The timestamp must be a pure function of the notification, never the fetch
    // time: a drifting `Utc::now()` makes already-seen items re-count as unread on
    // every poll, so the unread badge reappears right after you've checked it.
    // Prefer the parsed time, then the target tweet's time, then a fixed epoch.
    let timestamp = parse_notification_timestamp(item)
        .or_else(|| target.as_ref().map(|t| t.created_at))
        .unwrap_or_else(|| DateTime::from_timestamp(0, 0).expect("unix epoch is valid"));

    let stable_id = composite_grouped_id(&notification_type, &actors, &target_tweet_id)
        .unwrap_or_else(|| entry_id.to_string());

    Some(RawNotification {
        id: stable_id,
        notification_type,
        actors,
        others_count,
        message,
        target_tweet_id,
        target_tweet_like_count: target.as_ref().map(|t| t.like_count),
        target_tweet_created_at: target.as_ref().map(|t| t.created_at),
        target_tweet_snippet: snippet,
        target_tweet_favorited: target.as_ref().is_some_and(|t| t.favorited),
        target_media: target.as_ref().map(|t| t.media.clone()).unwrap_or_default(),
        url: external_url(item),
        timestamp,
    })
}

/// A grouped notification's id. The same group arrives again whenever someone
/// joins it, with more actors and a higher "and N others", so the id must not
/// depend on who is in it: a client keeping the group's row by id would show
/// every growth as a second notification. A group about a tweet is that tweet
/// plus the kind of activity; one with no tweet (new followers) is named by the
/// kind and the actors it lists, which is the most that is stable.
fn composite_grouped_id(
    notification_type: &str,
    actors: &[User],
    target_tweet_id: &Option<String>,
) -> Option<String> {
    if let Some(target) = target_tweet_id {
        return Some(format!("g-{notification_type}-{target}"));
    }
    if actors.is_empty() {
        return None;
    }
    let mut handles: Vec<&str> = actors.iter().map(|u| u.handle.as_str()).collect();
    handles.sort_unstable();
    Some(format!("g-{notification_type}--{}", handles.join(",")))
}

/// The text X attaches under a notification that has no post of its own: a
/// Community Note's wording. The sources a note lists after its text, one
/// address per line, are left out.
fn attached_note(item: &Value) -> Option<String> {
    let text = item
        .pointer("/template/additional_context/text")
        .and_then(Value::as_str)?;
    let kept: Vec<&str> = text
        .lines()
        .filter(|line| !is_bare_address(line.trim()))
        .collect();
    let note = decode_html_entities(kept.join("\n").trim());
    (!note.is_empty()).then_some(note)
}

fn is_bare_address(line: &str) -> bool {
    (line.starts_with("https://") || line.starts_with("http://"))
        && !line.contains(char::is_whitespace)
}

/// The web page a notification opens, when X names one, on x.com.
fn external_url(item: &Value) -> Option<String> {
    let link = item.get("notification_url")?;
    if link.get("urlType").and_then(Value::as_str) != Some("ExternalUrl") {
        return None;
    }
    let url = link.get("url").and_then(Value::as_str)?;
    let url = match url.strip_prefix("https://twitter.com/") {
        Some(rest) => format!("https://x.com/{rest}"),
        None => url.to_string(),
    };
    url.starts_with("https://").then_some(url)
}

/// Folds notifications that share an id into the newest of them. X starts a
/// new group for a post each time activity resumes ("Dan liked your post" an
/// hour after "Ann and 2 others liked your post"), and both carry the id of
/// the post and the activity: one row then stands for everyone, newest first,
/// at the time of the latest. `notifications` is newest first.
fn merge_repeated_groups(notifications: &mut Vec<RawNotification>) {
    let mut merged: Vec<RawNotification> = Vec::with_capacity(notifications.len());
    for older in notifications.drain(..) {
        match merged.iter_mut().find(|kept| kept.id == older.id) {
            Some(kept) => absorb(kept, older),
            None => merged.push(older),
        }
    }
    *notifications = merged;
}

/// Adds `older`'s people to `kept`, a newer notification with the same id.
fn absorb(kept: &mut RawNotification, older: RawNotification) {
    let mut people = kept.people_count() + older.people_count();
    for actor in older.actors {
        if kept.actors.iter().any(|a| a.rest_id == actor.rest_id) {
            people = people.saturating_sub(1);
        } else {
            kept.actors.push(actor);
        }
    }
    if kept.actors.is_empty() {
        return;
    }
    kept.others_count = (people > 1).then(|| people - 1);
    kept.message = None;
}

/// A post by an account the user asked to be told about, from the timeline
/// behind X's "New post notifications" rows.
#[derive(Debug, Clone)]
pub struct FollowedPost {
    pub id: String,
    pub author_id: String,
    pub created_at: DateTime<Utc>,
    pub text: String,
    pub media: Vec<Media>,
    pub favorited: bool,
    pub like_count: u64,
}

/// Reads the posts of `/2/notifications/device_follow.json`: the tweets its
/// timeline lists (`globalObjects` also holds the posts they quote).
pub fn parse_followed_posts(response: &Value) -> Vec<FollowedPost> {
    let Some(tweets) = response
        .pointer("/globalObjects/tweets")
        .and_then(Value::as_object)
    else {
        return Vec::new();
    };
    let listed: Vec<&str> = response
        .pointer("/timeline/instructions")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|i| i.pointer("/addEntries/entries").and_then(Value::as_array))
        .flatten()
        .filter_map(|e| e.pointer("/content/item/content/tweet/id"))
        .filter_map(Value::as_str)
        .collect();
    listed
        .iter()
        .filter_map(|id| tweets.get(*id))
        .filter_map(parse_legacy_post)
        .map(|post| FollowedPost {
            id: post.id,
            author_id: post.author_id,
            created_at: post.created_at,
            text: post.text,
            media: post.media,
            favorited: post.favorited,
            like_count: post.like_count,
        })
        .collect()
}

/// How long before its notification a followed account's post may have been
/// written and still be the one the notification is about.
const FOLLOWED_POST_WINDOW_SECS: i64 = 6 * 60 * 60;
/// X stamps the notification a moment after the post; this much later still
/// counts as before it.
const FOLLOWED_POST_SLACK_SECS: i64 = 60;

/// Gives each "New post" notification without a post the one it is about: the
/// newest post by one of its accounts written up to the notification's time.
/// The row then opens that post and is named after it. Returns whether every
/// such notification found its post.
pub fn attach_followed_posts(
    notifications: &mut [RawNotification],
    posts: &[FollowedPost],
) -> bool {
    let mut complete = true;
    for notification in notifications.iter_mut().filter(|n| n.wants_followed_post()) {
        let latest = notification.timestamp.timestamp() + FOLLOWED_POST_SLACK_SECS;
        let earliest = latest - FOLLOWED_POST_WINDOW_SECS;
        let post = posts
            .iter()
            .filter(|p| notification.actors.iter().any(|a| a.rest_id == p.author_id))
            .filter(|p| (earliest..=latest).contains(&p.created_at.timestamp()))
            .max_by_key(|p| p.created_at);
        let Some(post) = post else {
            complete = false;
            continue;
        };
        notification.id = format!("g-{POST_TYPE}-{}", post.id);
        notification.target_tweet_id = Some(post.id.clone());
        notification.target_tweet_like_count = Some(post.like_count);
        notification.target_tweet_created_at = Some(post.created_at);
        notification.target_tweet_snippet = Some(post.text.clone());
        notification.target_tweet_favorited = post.favorited;
        notification.target_media = post.media.clone();
    }
    complete
}

fn parse_notification_timestamp(item: &Value) -> Option<DateTime<Utc>> {
    // X sends this as snake_case on some payloads and camelCase on others; miss
    // either and the timestamp would drift to `now()` (see `build_grouped_entry`).
    let v = item
        .get("timestamp_ms")
        .or_else(|| item.get("timestampMs"))?;
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
        "device_follow_tweet_notification_entry" => Some(POST_TYPE),
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

struct TargetTweet {
    id: String,
    like_count: u64,
    created_at: DateTime<Utc>,
    snippet: String,
    favorited: bool,
    media: Vec<Media>,
}

fn extract_target_tweet(item: &Value) -> Option<TargetTweet> {
    let targets = item
        .pointer("/template/target_objects")
        .or_else(|| item.pointer("/template/aggregate_user_actions_v1/target_objects"))
        .or_else(|| item.pointer("/template/aggregateUserActionsV1/targetObjects"))
        .and_then(Value::as_array)?;

    for target in targets {
        let result = target
            .pointer("/tweet_results/result")
            .or_else(|| target.pointer("/tweetResults/result"));
        let Some(result) = result else { continue };
        let Ok(tweet) = parse_tweet_result(result) else {
            continue;
        };
        return Some(TargetTweet {
            id: tweet.rest_id,
            like_count: tweet.like_count,
            created_at: tweet.created_at,
            snippet: tweet.text,
            favorited: tweet.favorited,
            media: tweet.media,
        });
    }

    None
}

/// The N of "and N others" in a grouped notification's message. Every "and "
/// is tried, so one inside a name ("Grand Prix and 4 others") doesn't hide
/// the phrase, and only a number followed by " other" counts.
fn extract_others_count(text: &str) -> Option<u64> {
    let marker = "and ";
    text.match_indices(marker).find_map(|(idx, _)| {
        let after = &text[idx + marker.len()..];
        let digits = after.len() - after.trim_start_matches(|c: char| c.is_ascii_digit()).len();
        if digits == 0 || !after[digits..].starts_with(" other") {
            return None;
        }
        after[..digits].parse().ok()
    })
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
    fn grouped_timestamp_is_deterministic_without_timestamp_ms() {
        // A grouped entry lacking a timestamp must get a stable, fetch-time-
        // independent value — never Utc::now() — so an already-seen notification
        // doesn't re-count as unread on the next poll (the red-dot reappears bug).
        let content = json!({
            "clientEventInfo": { "element": "users_followed_you" },
            "itemContent": { "notification_icon": "person_icon" }
        });
        let a = build_grouped_entry("g-1", &content).unwrap();
        let b = build_grouped_entry("g-1", &content).unwrap();
        assert_eq!(
            a.timestamp, b.timestamp,
            "timestamp must not depend on fetch time"
        );
        assert_eq!(
            a.timestamp,
            DateTime::from_timestamp(0, 0).unwrap(),
            "no timestamp + no target falls back to a fixed epoch"
        );
    }

    #[test]
    fn parses_camelcase_timestamp_ms() {
        let item = json!({ "timestampMs": "1700000000000" });
        assert_eq!(
            parse_notification_timestamp(&item),
            DateTime::from_timestamp_millis(1_700_000_000_000)
        );
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
        assert_eq!(page.unread_after_ms, None);
    }

    #[test]
    fn reads_xs_unread_marker() {
        let response = json!({
            "data": { "viewer_v2": { "user_results": { "result": {
                "notification_timeline": { "timeline": { "instructions": [
                    { "type": "TimelineClearEntriesUnreadState" },
                    {
                        "type": "TimelineMarkEntriesUnreadGreaterThanSortIndex",
                        "sort_index": "1791121401034"
                    }
                ] } }
            } } } }
        });
        let page = parse_notifications_timeline(&response).unwrap();
        assert_eq!(page.unread_after_ms, Some(1_791_121_401_034));
    }

    #[test]
    fn grouped_entry_carries_rendered_message_and_others_count() {
        let content = json!({
            "clientEventInfo": { "element": "users_liked_your_tweet" },
            "itemContent": {
                "notification_icon": "heart_icon",
                "timestamp_ms": "1700000000000",
                "rich_message": { "text": "Alice, Bob and 47 others liked your post" }
            }
        });
        let n = build_grouped_entry("g-1", &content).unwrap();
        assert_eq!(
            n.message.as_deref(),
            Some("Alice, Bob and 47 others liked your post")
        );
        assert_eq!(n.others_count, Some(47));
    }

    #[test]
    fn a_liked_posts_snippet_is_decoded_once() {
        let content = json!({
            "clientEventInfo": { "element": "users_liked_your_tweet" },
            "itemContent": {
                "notification_icon": "heart_icon",
                "timestamp_ms": "1700000000000",
                "template": { "target_objects": [{ "tweet_results": { "result": {
                    "__typename": "Tweet",
                    "rest_id": "77",
                    "core": { "user_results": { "result": {
                        "rest_id": "100",
                        "legacy": { "screen_name": "me", "name": "Me" }
                    } } },
                    "legacy": {
                        "full_text": "write &amp;amp; for &amp;",
                        "created_at": "Mon Jan 01 12:00:00 +0000 2024"
                    }
                } } }] }
            }
        });
        let n = build_grouped_entry("g-2", &content).unwrap();
        assert_eq!(n.target_tweet_snippet.as_deref(), Some("write &amp; for &"));
    }

    #[test]
    fn others_count_reads_the_phrase_not_a_name() {
        assert_eq!(
            extract_others_count("Grand Prix and 4 others liked your post"),
            Some(4)
        );
        assert_eq!(
            extract_others_count("Hand 2 Tech and 9 others liked your post"),
            Some(9)
        );
        assert_eq!(
            extract_others_count("Alice and 1 other reposted your post"),
            Some(1)
        );
        assert_eq!(extract_others_count("Alice and Bob liked your post"), None);
    }

    fn user(handle: &str) -> User {
        User {
            rest_id: handle.to_string(),
            handle: handle.to_string(),
            name: handle.to_string(),
            verified: false,
            followers: 0,
            following: 0,
            avatar_url: None,
            followed_by_me: None,
            follows_me: None,
            banner_url: None,
            description: None,
            location: None,
            website: None,
            joined_at: None,
            protected: false,
            muting: None,
            blocking: None,
        }
    }

    #[test]
    fn a_growing_group_about_a_tweet_keeps_its_id() {
        let target = Some("42".to_string());
        let small = composite_grouped_id("Like", &[user("alice")], &target);
        let grown = composite_grouped_id(
            "Like",
            &[user("bob"), user("alice"), user("carol")],
            &target,
        );
        assert_eq!(small, grown, "growth must not mint a new id");
        assert_ne!(
            small,
            composite_grouped_id("Retweet", &[user("alice")], &target),
            "a different kind of activity is a different notification"
        );
        assert_ne!(
            small,
            composite_grouped_id("Like", &[user("alice")], &Some("43".to_string())),
            "a different tweet is a different notification"
        );
    }

    #[test]
    fn a_group_without_a_tweet_is_named_by_its_actors() {
        let none = None;
        assert_eq!(
            composite_grouped_id("Follow", &[user("b"), user("a")], &none),
            composite_grouped_id("Follow", &[user("a"), user("b")], &none),
            "actor order doesn't matter"
        );
        assert_eq!(composite_grouped_id("Follow", &[], &none), None);
    }

    #[test]
    fn actorless_grouped_entry_keeps_message_without_others_count() {
        let content = json!({
            "clientEventInfo": { "element": "" },
            "itemContent": {
                "notification_icon": "histogram_icon",
                "timestamp_ms": "1700000000000",
                "message": { "text": "Your poll has ended" }
            }
        });
        let n = build_grouped_entry("g-2", &content).unwrap();
        assert_eq!(n.notification_type, "Poll");
        assert_eq!(n.message.as_deref(), Some("Your poll has ended"));
        assert_eq!(n.others_count, None);
        assert!(n.actors.is_empty());
    }

    #[test]
    fn classify_by_element_wins_over_icon() {
        assert_eq!(classify_type("heart_icon", "users_followed_you"), "Follow");
        assert_eq!(classify_type("", "users_liked_your_tweet"), "Like");
        assert_eq!(classify_type("reply_icon", ""), "Reply");
    }

    fn user_json(id: &str, handle: &str) -> Value {
        json!({ "user_results": { "result": {
            "__typename": "User",
            "rest_id": id,
            "core": { "name": handle, "screen_name": handle },
            "legacy": { "screen_name": handle, "name": handle }
        }}})
    }

    fn like_entry(entry: &str, users: &[(&str, &str)], message: &str, at: &str) -> Value {
        json!({
            "entryId": entry,
            "content": {
                "clientEventInfo": { "element": "users_liked_your_tweet" },
                "itemContent": {
                    "__typename": "TimelineNotification",
                    "notification_icon": "heart_icon",
                    "rich_message": { "text": message },
                    "timestamp_ms": at,
                    "template": {
                        "from_users": users.iter().map(|(id, h)| user_json(id, h)).collect::<Vec<_>>(),
                        "target_objects": [{ "tweet_results": { "result": {
                            "__typename": "Tweet",
                            "rest_id": "900",
                            "core": user_json("1", "me"),
                            "legacy": {
                                "full_text": "my post",
                                "created_at": "Wed Oct 10 20:19:24 +0000 2018",
                                "favorite_count": 4
                            }
                        }}}]
                    }
                }
            }
        })
    }

    fn timeline_of(entries: Vec<Value>) -> Value {
        json!({ "data": { "notification_timeline": { "timeline": { "instructions": [
            { "type": "TimelineAddEntries", "entries": entries }
        ]}}}})
    }

    #[test]
    fn two_groups_about_one_post_become_one_row_led_by_the_newest() {
        let older = like_entry(
            "n-1",
            &[("11", "ann"), ("12", "bob"), ("13", "cat")],
            "ann and 2 others liked your post",
            "2026-11-20T23:38:21.000Z",
        );
        let newer = like_entry(
            "n-2",
            &[("14", "dan"), ("12", "bob")],
            "dan and bob liked your post",
            "2026-11-21T02:36:09.000Z",
        );
        let page = parse_notifications_timeline(&timeline_of(vec![older, newer])).unwrap();
        assert_eq!(page.notifications.len(), 1);
        let row = &page.notifications[0];
        let handles: Vec<&str> = row.actors.iter().map(|a| a.handle.as_str()).collect();
        assert_eq!(handles, ["dan", "bob", "ann", "cat"]);
        assert_eq!(row.people_count(), 4);
        assert_eq!(row.others_count, Some(3));
        assert_eq!(row.timestamp.to_rfc3339(), "2026-11-21T02:36:09+00:00");
    }

    #[test]
    fn people_count_reads_x_listing_everyone_it_counts() {
        let entry = like_entry(
            "n-1",
            &[("11", "ann"), ("12", "bob"), ("13", "cat")],
            "ann and 2 others liked your post",
            "2026-11-20T23:38:21.000Z",
        );
        let page = parse_notifications_timeline(&timeline_of(vec![entry])).unwrap();
        assert_eq!(page.notifications[0].people_count(), 3);
    }

    #[test]
    fn a_community_note_carries_its_text_and_its_page() {
        let entry = json!({
            "entryId": "n-note",
            "content": {
                "clientEventInfo": { "element": "generic_birdwatch_new_community_note" },
                "itemContent": {
                    "__typename": "TimelineNotification",
                    "notification_icon": "birdwatch_icon",
                    "notification_url": {
                        "url": "https://twitter.com/i/birdwatch/n/77?src=ntab",
                        "urlType": "ExternalUrl"
                    },
                    "rich_message": { "text": "Readers added a Community Note to a post you liked" },
                    "timestamp_ms": "2026-11-20T09:00:35.958Z",
                    "template": {
                        "additional_context": {
                            "text": "The clip is spliced.\n\nhttps://example.com/a\nhttps://example.com/b"
                        },
                        "from_users": [],
                        "target_objects": []
                    }
                }
            }
        });
        let page = parse_notifications_timeline(&timeline_of(vec![entry])).unwrap();
        let note = &page.notifications[0];
        assert_eq!(note.notification_type, "CommunityNote");
        assert_eq!(
            note.target_tweet_snippet.as_deref(),
            Some("The clip is spliced.")
        );
        assert_eq!(
            note.url.as_deref(),
            Some("https://x.com/i/birdwatch/n/77?src=ntab")
        );
        assert!(note.target_tweet_id.is_none());
    }

    fn new_post_entry(at: &str) -> Value {
        json!({
            "entryId": "n-post",
            "content": {
                "clientEventInfo": { "element": "device_follow_tweet_notification_entry" },
                "itemContent": {
                    "__typename": "TimelineNotification",
                    "notification_icon": "bell_icon",
                    "notification_url": {
                        "url": "/2/notifications/device_follow.json",
                        "urlType": "UrtEndpoint"
                    },
                    "rich_message": { "text": "New post notifications for ann" },
                    "timestamp_ms": at,
                    "template": { "from_users": [user_json("11", "ann")], "target_objects": [] }
                }
            }
        })
    }

    fn followed(posts: &[(&str, &str, &str)]) -> Value {
        let tweets: serde_json::Map<String, Value> = posts
            .iter()
            .map(|(id, author, at)| {
                let tweet = json!({
                    "id_str": id, "user_id_str": author, "created_at": at,
                    "full_text": format!("post {id}"), "favorite_count": 2
                });
                (id.to_string(), tweet)
            })
            .collect();
        let entries: Vec<Value> = posts
            .iter()
            .filter(|(id, _, _)| *id != "quoted")
            .map(|(id, _, _)| json!({ "content": { "item": { "content": { "tweet": { "id": id } } } } }))
            .collect();
        json!({
            "globalObjects": { "tweets": tweets },
            "timeline": { "instructions": [{ "addEntries": { "entries": entries } }] }
        })
    }

    #[test]
    fn a_new_post_row_gets_the_post_it_is_about() {
        let entry = new_post_entry("2026-11-20T20:18:34.000Z");
        let mut page = parse_notifications_timeline(&timeline_of(vec![entry])).unwrap();
        assert_eq!(page.notifications[0].notification_type, POST_TYPE);
        assert!(page.notifications[0].wants_followed_post());
        assert!(page.notifications[0].url.is_none());

        let posts = parse_followed_posts(&followed(&[
            ("501", "11", "Fri Nov 20 20:13:06 +0000 2026"),
            ("502", "11", "Fri Nov 20 20:18:33 +0000 2026"),
            ("503", "11", "Fri Nov 20 21:40:00 +0000 2026"),
            ("504", "99", "Fri Nov 20 20:18:30 +0000 2026"),
            ("quoted", "11", "Fri Nov 20 20:18:34 +0000 2026"),
        ]));
        assert_eq!(posts.len(), 4);
        assert!(attach_followed_posts(&mut page.notifications, &posts));
        let row = &page.notifications[0];
        assert_eq!(row.target_tweet_id.as_deref(), Some("502"));
        assert_eq!(row.target_tweet_snippet.as_deref(), Some("post 502"));
        assert_eq!(row.id, "g-Post-502");
        assert!(!row.wants_followed_post());
    }

    #[test]
    fn a_new_post_row_whose_post_is_not_listed_stays_as_it_was() {
        let entry = new_post_entry("2026-11-20T20:18:34.000Z");
        let mut page = parse_notifications_timeline(&timeline_of(vec![entry])).unwrap();
        let posts = parse_followed_posts(&followed(&[(
            "503",
            "11",
            "Fri Nov 20 21:40:00 +0000 2026",
        )]));
        assert!(!attach_followed_posts(&mut page.notifications, &posts));
        assert!(page.notifications[0].target_tweet_id.is_none());
    }
}
