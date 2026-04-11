use crate::model::Tweet;
use crate::parse::tweet::parse_tweet_result;
use serde_json::Value;

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
