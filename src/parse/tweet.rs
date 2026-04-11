use crate::error::{Error, Result};
use crate::model::{Media, MediaKind, Tweet, User};
use chrono::{DateTime, Utc};
use serde_json::Value;

pub fn parse_tweet_result_by_rest_id(response: &Value) -> Result<Tweet> {
    let wrapper = response
        .pointer("/data/tweetResult")
        .ok_or_else(|| Error::GraphqlShape("missing data.tweetResult".into()))?;
    let result = wrapper.get("result").ok_or_else(|| {
        Error::GraphqlShape(
            "tweet not accessible: it may be deleted, protected, or from a suspended account".into(),
        )
    })?;
    parse_tweet_result(result)
}

pub fn parse_tweet_result(result: &Value) -> Result<Tweet> {
    let unwrapped = unwrap_visibility(result)?;
    let typename = unwrapped.get("__typename").and_then(Value::as_str).unwrap_or("");
    match typename {
        "Tweet" => parse_tweet_node(unwrapped),
        "TweetTombstone" => Err(Error::GraphqlShape(format!(
            "tweet is a tombstone: {}",
            unwrapped
                .pointer("/tombstone/text/text")
                .and_then(Value::as_str)
                .unwrap_or("no reason given")
        ))),
        "TweetUnavailable" => Err(Error::GraphqlShape(format!(
            "tweet is unavailable: {}",
            unwrapped.get("reason").and_then(Value::as_str).unwrap_or("unknown")
        ))),
        other => Err(Error::GraphqlShape(format!(
            "unexpected tweet __typename: {other:?}"
        ))),
    }
}

fn unwrap_visibility(node: &Value) -> Result<&Value> {
    if node.get("__typename").and_then(Value::as_str) == Some("TweetWithVisibilityResults") {
        node.get("tweet")
            .ok_or_else(|| Error::GraphqlShape("visibility wrapper missing .tweet".into()))
    } else {
        Ok(node)
    }
}

fn parse_tweet_node(node: &Value) -> Result<Tweet> {
    let rest_id = node
        .get("rest_id")
        .and_then(Value::as_str)
        .ok_or_else(|| Error::GraphqlShape("tweet missing rest_id".into()))?
        .to_string();

    let legacy = node
        .get("legacy")
        .ok_or_else(|| Error::GraphqlShape("tweet missing legacy block".into()))?;

    let author = parse_author(node)?;
    let text = extract_text(node, legacy);
    let created_at = parse_created_at(legacy)?;

    let reply_count = u64_field(legacy, "reply_count");
    let retweet_count = u64_field(legacy, "retweet_count");
    let like_count = u64_field(legacy, "favorite_count");
    let quote_count = u64_field(legacy, "quote_count");

    let view_count = node
        .pointer("/views/count")
        .and_then(Value::as_str)
        .and_then(|s| s.parse::<u64>().ok());

    let lang = legacy
        .get("lang")
        .and_then(Value::as_str)
        .map(str::to_string);

    let in_reply_to_tweet_id = legacy
        .get("in_reply_to_status_id_str")
        .and_then(Value::as_str)
        .map(str::to_string);

    let quoted_tweet = node
        .pointer("/quoted_status_result/result")
        .and_then(|q| parse_tweet_result(q).ok())
        .map(Box::new);

    let media = parse_media(legacy);

    let url = format!("https://x.com/{}/status/{}", author.handle, rest_id);

    Ok(Tweet {
        rest_id,
        author,
        created_at,
        text,
        reply_count,
        retweet_count,
        like_count,
        quote_count,
        view_count,
        lang,
        in_reply_to_tweet_id,
        quoted_tweet,
        media,
        url,
    })
}

fn parse_author(node: &Value) -> Result<User> {
    let user = node
        .pointer("/core/user_results/result")
        .ok_or_else(|| Error::GraphqlShape("tweet missing core.user_results.result".into()))?;

    let rest_id = user
        .get("rest_id")
        .and_then(Value::as_str)
        .ok_or_else(|| Error::GraphqlShape("author missing rest_id".into()))?
        .to_string();

    let handle = user
        .pointer("/core/screen_name")
        .or_else(|| user.pointer("/legacy/screen_name"))
        .and_then(Value::as_str)
        .ok_or_else(|| Error::GraphqlShape("author missing screen_name".into()))?
        .to_string();

    let name = user
        .pointer("/core/name")
        .or_else(|| user.pointer("/legacy/name"))
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();

    let verified = user
        .get("is_blue_verified")
        .and_then(Value::as_bool)
        .unwrap_or(false)
        || user
            .pointer("/legacy/verified")
            .and_then(Value::as_bool)
            .unwrap_or(false);

    let followers = user
        .pointer("/legacy/followers_count")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let following = user
        .pointer("/legacy/friends_count")
        .and_then(Value::as_u64)
        .unwrap_or(0);

    Ok(User {
        rest_id,
        handle,
        name,
        verified,
        followers,
        following,
    })
}

fn extract_text(node: &Value, legacy: &Value) -> String {
    if let Some(note) = node
        .pointer("/note_tweet/note_tweet_results/result/text")
        .and_then(Value::as_str)
    {
        return note.to_string();
    }
    legacy
        .get("full_text")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string()
}

fn parse_created_at(legacy: &Value) -> Result<DateTime<Utc>> {
    let raw = legacy
        .get("created_at")
        .and_then(Value::as_str)
        .ok_or_else(|| Error::GraphqlShape("tweet missing created_at".into()))?;
    DateTime::parse_from_str(raw, "%a %b %d %H:%M:%S %z %Y")
        .map(|dt| dt.with_timezone(&Utc))
        .map_err(|e| Error::GraphqlShape(format!("bad created_at {raw:?}: {e}")))
}

fn u64_field(legacy: &Value, key: &str) -> u64 {
    legacy.get(key).and_then(Value::as_u64).unwrap_or(0)
}

fn parse_media(legacy: &Value) -> Vec<Media> {
    let Some(items) = legacy
        .pointer("/extended_entities/media")
        .and_then(Value::as_array)
    else {
        return Vec::new();
    };
    items
        .iter()
        .filter_map(|m| {
            let kind = match m.get("type").and_then(Value::as_str)? {
                "photo" => MediaKind::Photo,
                "video" => MediaKind::Video,
                "animated_gif" => MediaKind::AnimatedGif,
                _ => return None,
            };
            let url = m
                .get("media_url_https")
                .and_then(Value::as_str)?
                .to_string();
            let alt_text = m
                .get("ext_alt_text")
                .and_then(Value::as_str)
                .map(str::to_string);
            Some(Media {
                kind,
                url,
                alt_text,
            })
        })
        .collect()
}
