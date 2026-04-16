use crate::error::{Error, Result};
use crate::model::Tweet;
use crate::parse::tweet::parse_tweet_result;
use serde_json::Value;

pub fn extract_instructions<'a>(response: &'a Value, path: &str) -> Result<&'a [Value]> {
    response
        .pointer(path)
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .ok_or_else(|| Error::GraphqlShape(format!("missing instructions at {path}")))
}

pub fn extract_instructions_multi<'a>(response: &'a Value, paths: &[&str]) -> Result<&'a [Value]> {
    for path in paths {
        if let Some(arr) = response.pointer(path).and_then(Value::as_array) {
            return Ok(arr.as_slice());
        }
    }
    Err(Error::GraphqlShape(format!(
        "missing instructions at any of: {}",
        paths.join(", ")
    )))
}

#[derive(Debug, Clone, Default)]
pub struct TimelinePage {
    pub tweets: Vec<Tweet>,
    pub next_cursor: Option<String>,
    pub top_cursor: Option<String>,
}

pub fn walk(instructions: &[Value]) -> TimelinePage {
    let mut page = TimelinePage::default();
    for instr in instructions {
        let type_name = instr.get("type").and_then(Value::as_str).unwrap_or("");
        match type_name {
            "TimelineAddEntries" => {
                if let Some(entries) = instr.get("entries").and_then(Value::as_array) {
                    for entry in entries {
                        collect_from_entry(entry, &mut page);
                    }
                }
            }
            "TimelineAddToModule" => {
                if let Some(items) = instr.get("moduleItems").and_then(Value::as_array) {
                    for item in items {
                        if let Some(ic) = item.pointer("/item/itemContent") {
                            collect_tweet_from_item_content(ic, &mut page.tweets);
                        }
                    }
                }
            }
            "TimelineReplaceEntry" | "TimelinePinEntry" => {
                if let Some(entry) = instr.get("entry") {
                    collect_from_entry(entry, &mut page);
                }
            }
            _ => {}
        }
    }
    page
}

fn collect_from_entry(entry: &Value, page: &mut TimelinePage) {
    let entry_id = entry.get("entryId").and_then(Value::as_str).unwrap_or("");
    let Some(content) = entry.get("content") else {
        return;
    };
    let entry_type = content
        .get("entryType")
        .and_then(Value::as_str)
        .unwrap_or_else(|| {
            content
                .get("__typename")
                .and_then(Value::as_str)
                .unwrap_or("")
        });

    match entry_type {
        "TimelineTimelineItem" => {
            if let Some(ic) = content.get("itemContent") {
                collect_tweet_from_item_content(ic, &mut page.tweets);
            }
        }
        "TimelineTimelineModule" => {
            if let Some(items) = content.get("items").and_then(Value::as_array) {
                for item in items {
                    if let Some(ic) = item.pointer("/item/itemContent") {
                        collect_tweet_from_item_content(ic, &mut page.tweets);
                    }
                }
            }
        }
        "TimelineTimelineCursor" => {
            let cursor_type = content
                .get("cursorType")
                .and_then(Value::as_str)
                .unwrap_or("");
            if let Some(value) = content.get("value").and_then(Value::as_str) {
                match cursor_type {
                    "Bottom" => page.next_cursor = Some(value.to_string()),
                    "Top" => page.top_cursor = Some(value.to_string()),
                    _ => {}
                }
            }
        }
        _ => {}
    }

    if page.next_cursor.is_none() && entry_id.starts_with("cursor-bottom") {
        if let Some(value) = content.get("value").and_then(Value::as_str) {
            page.next_cursor = Some(value.to_string());
        }
    }
}

fn collect_tweet_from_item_content(item_content: &Value, tweets: &mut Vec<Tweet>) {
    let item_type = item_content
        .get("itemType")
        .and_then(Value::as_str)
        .unwrap_or("");
    if item_type != "TimelineTweet" {
        return;
    }
    if item_content
        .get("promotedMetadata")
        .is_some_and(|v| !v.is_null())
    {
        return;
    }
    let Some(result) = item_content.pointer("/tweet_results/result") else {
        return;
    };
    if let Ok(tweet) = parse_tweet_result(result) {
        tweets.push(tweet);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn tweet_node(rest_id: &str, text: &str) -> Value {
        json!({
            "__typename": "Tweet",
            "rest_id": rest_id,
            "core": {
                "user_results": {
                    "result": {
                        "rest_id": "1",
                        "legacy": {
                            "screen_name": "u",
                            "name": "U",
                            "verified": false,
                            "followers_count": 0,
                            "friends_count": 0
                        },
                        "is_blue_verified": false
                    }
                }
            },
            "legacy": {
                "full_text": text,
                "created_at": "Mon Jan 01 00:00:00 +0000 2024",
                "reply_count": 0,
                "retweet_count": 0,
                "favorite_count": 0,
                "quote_count": 0
            }
        })
    }

    fn tweet_entry(entry_id: &str, rest_id: &str, text: &str) -> Value {
        json!({
            "entryId": entry_id,
            "content": {
                "entryType": "TimelineTimelineItem",
                "itemContent": {
                    "itemType": "TimelineTweet",
                    "tweet_results": {
                        "result": tweet_node(rest_id, text)
                    }
                }
            }
        })
    }

    fn cursor_entry(entry_id: &str, cursor_type: &str, value: &str) -> Value {
        json!({
            "entryId": entry_id,
            "content": {
                "entryType": "TimelineTimelineCursor",
                "cursorType": cursor_type,
                "value": value
            }
        })
    }

    #[test]
    fn walk_basic_entries_and_cursors() {
        let instructions = vec![json!({
            "type": "TimelineAddEntries",
            "entries": [
                tweet_entry("tweet-1", "1001", "first"),
                tweet_entry("tweet-2", "1002", "second"),
                cursor_entry("cursor-bottom", "Bottom", "abc123"),
                cursor_entry("cursor-top", "Top", "xyz789")
            ]
        })];
        let page = walk(&instructions);
        assert_eq!(page.tweets.len(), 2);
        assert_eq!(page.tweets[0].rest_id, "1001");
        assert_eq!(page.tweets[1].rest_id, "1002");
        assert_eq!(page.next_cursor.as_deref(), Some("abc123"));
        assert_eq!(page.top_cursor.as_deref(), Some("xyz789"));
    }

    #[test]
    fn walk_filters_promoted_tweets() {
        let promoted = json!({
            "entryId": "promoted-1",
            "content": {
                "entryType": "TimelineTimelineItem",
                "itemContent": {
                    "itemType": "TimelineTweet",
                    "promotedMetadata": { "advertiser_id": "99" },
                    "tweet_results": {
                        "result": tweet_node("ad", "buy stuff")
                    }
                }
            }
        });
        let instructions = vec![json!({
            "type": "TimelineAddEntries",
            "entries": [
                tweet_entry("tweet-1", "1001", "organic"),
                promoted
            ]
        })];
        let page = walk(&instructions);
        assert_eq!(page.tweets.len(), 1);
        assert_eq!(page.tweets[0].rest_id, "1001");
    }

    #[test]
    fn walk_timeline_module() {
        let instructions = vec![json!({
            "type": "TimelineAddToModule",
            "moduleItems": [
                {
                    "item": {
                        "itemContent": {
                            "itemType": "TimelineTweet",
                            "tweet_results": {
                                "result": tweet_node("2001", "in module")
                            }
                        }
                    }
                }
            ]
        })];
        let page = walk(&instructions);
        assert_eq!(page.tweets.len(), 1);
        assert_eq!(page.tweets[0].rest_id, "2001");
    }

    #[test]
    fn walk_replace_entry() {
        let instructions = vec![json!({
            "type": "TimelineReplaceEntry",
            "entry": tweet_entry("tweet-1", "3001", "replaced")
        })];
        let page = walk(&instructions);
        assert_eq!(page.tweets.len(), 1);
        assert_eq!(page.tweets[0].text, "replaced");
    }

    #[test]
    fn walk_pin_entry() {
        let instructions = vec![json!({
            "type": "TimelinePinEntry",
            "entry": tweet_entry("tweet-1", "4001", "pinned")
        })];
        let page = walk(&instructions);
        assert_eq!(page.tweets.len(), 1);
        assert_eq!(page.tweets[0].text, "pinned");
    }

    #[test]
    fn walk_typename_fallback_for_entry_type() {
        let instructions = vec![json!({
            "type": "TimelineAddEntries",
            "entries": [{
                "entryId": "t-1",
                "content": {
                    "__typename": "TimelineTimelineItem",
                    "itemContent": {
                        "itemType": "TimelineTweet",
                        "tweet_results": {
                            "result": tweet_node("5001", "typename fallback")
                        }
                    }
                }
            }]
        })];
        let page = walk(&instructions);
        assert_eq!(page.tweets.len(), 1);
    }

    #[test]
    fn walk_cursor_bottom_fallback_from_entry_id() {
        let instructions = vec![json!({
            "type": "TimelineAddEntries",
            "entries": [{
                "entryId": "cursor-bottom-0",
                "content": {
                    "entryType": "SomeOtherType",
                    "value": "fallback_cursor"
                }
            }]
        })];
        let page = walk(&instructions);
        assert_eq!(page.next_cursor.as_deref(), Some("fallback_cursor"));
    }

    #[test]
    fn walk_empty_instructions() {
        let page = walk(&[]);
        assert!(page.tweets.is_empty());
        assert!(page.next_cursor.is_none());
        assert!(page.top_cursor.is_none());
    }

    #[test]
    fn walk_module_in_entries() {
        let instructions = vec![json!({
            "type": "TimelineAddEntries",
            "entries": [{
                "entryId": "module-1",
                "content": {
                    "entryType": "TimelineTimelineModule",
                    "items": [
                        {
                            "item": {
                                "itemContent": {
                                    "itemType": "TimelineTweet",
                                    "tweet_results": {
                                        "result": tweet_node("6001", "in module entry")
                                    }
                                }
                            }
                        }
                    ]
                }
            }]
        })];
        let page = walk(&instructions);
        assert_eq!(page.tweets.len(), 1);
        assert_eq!(page.tweets[0].rest_id, "6001");
    }
}
