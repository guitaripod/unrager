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
            "tweet not accessible: it may be deleted, protected, or from a suspended account"
                .into(),
        )
    })?;
    parse_tweet_result(result)
}

pub fn parse_tweet_result(result: &Value) -> Result<Tweet> {
    let unwrapped = unwrap_visibility(result)?;
    let typename = unwrapped
        .get("__typename")
        .and_then(Value::as_str)
        .unwrap_or("");
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
            unwrapped
                .get("reason")
                .and_then(Value::as_str)
                .unwrap_or("unknown")
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
    let text = scrub_urls_in_text(&text, legacy);
    let created_at = parse_created_at(legacy)?;

    let reply_count = u64_field(legacy, "reply_count");
    let retweet_count = u64_field(legacy, "retweet_count");
    let like_count = u64_field(legacy, "favorite_count");
    let quote_count = u64_field(legacy, "quote_count");

    let view_count = node
        .pointer("/views/count")
        .and_then(Value::as_str)
        .and_then(|s| s.parse::<u64>().ok());

    let favorited = bool_field(legacy, "favorited");
    let retweeted = bool_field(legacy, "retweeted");
    let bookmarked = bool_field(legacy, "bookmarked");

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
        favorited,
        retweeted,
        bookmarked,
        lang,
        in_reply_to_tweet_id,
        quoted_tweet,
        media,
        url,
    })
}

fn parse_author(node: &Value) -> Result<User> {
    let user_node = node
        .pointer("/core/user_results/result")
        .ok_or_else(|| Error::GraphqlShape("tweet missing core.user_results.result".into()))?;
    crate::parse::user::parse_user_result(user_node)
        .ok_or_else(|| Error::GraphqlShape("author missing required fields".into()))
}

fn extract_text(node: &Value, legacy: &Value) -> String {
    let raw = if let Some(note) = node
        .pointer("/note_tweet/note_tweet_results/result/text")
        .and_then(Value::as_str)
    {
        note.to_string()
    } else {
        legacy
            .get("full_text")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string()
    };
    decode_html_entities(&raw)
}

pub fn decode_html_entities(s: &str) -> String {
    s.replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&apos;", "'")
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

fn bool_field(legacy: &Value, key: &str) -> bool {
    legacy.get(key).and_then(Value::as_bool).unwrap_or(false)
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
            let video_url = match kind {
                MediaKind::Photo => None,
                MediaKind::Video | MediaKind::AnimatedGif => best_video_variant(m),
            };
            let alt_text = m
                .get("ext_alt_text")
                .and_then(Value::as_str)
                .map(str::to_string);
            Some(Media {
                kind,
                url,
                video_url,
                alt_text,
            })
        })
        .collect()
}

fn best_video_variant(m: &Value) -> Option<String> {
    let variants = m
        .pointer("/video_info/variants")
        .and_then(Value::as_array)?;
    let mut best: Option<(u64, &str)> = None;
    for v in variants {
        if v.get("content_type").and_then(Value::as_str) != Some("video/mp4") {
            continue;
        }
        let Some(url) = v.get("url").and_then(Value::as_str) else {
            continue;
        };
        let bitrate = v.get("bitrate").and_then(Value::as_u64).unwrap_or(0);
        if best.as_ref().is_none_or(|(bb, _)| bitrate > *bb) {
            best = Some((bitrate, url));
        }
    }
    best.map(|(_, u)| u.to_string())
}

fn scrub_urls_in_text(text: &str, legacy: &Value) -> String {
    let mut out = text.to_string();

    let mut media_tco: Vec<String> = Vec::new();
    for ptr in ["/extended_entities/media", "/entities/media"] {
        if let Some(arr) = legacy.pointer(ptr).and_then(Value::as_array) {
            for m in arr {
                if let Some(u) = m.get("url").and_then(Value::as_str) {
                    let owned = u.to_string();
                    if !media_tco.contains(&owned) {
                        media_tco.push(owned);
                    }
                }
            }
        }
    }
    for tco in &media_tco {
        out = strip_url(&out, tco);
    }

    if let Some(arr) = legacy.pointer("/entities/urls").and_then(Value::as_array) {
        for u in arr {
            let tco = u.get("url").and_then(Value::as_str).unwrap_or("");
            let display = u.get("display_url").and_then(Value::as_str).unwrap_or("");
            if !tco.is_empty() && !display.is_empty() {
                out = out.replace(tco, display);
            }
        }
    }

    out.trim().to_string()
}

/// Removes every occurrence of `url` from `text`, collapsing the whitespace
/// around it so consecutive spaces and orphaned separators don't leak into the
/// visible text.
fn strip_url(text: &str, url: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(idx) = rest.find(url) {
        let before = &rest[..idx];
        let after = &rest[idx + url.len()..];
        out.push_str(before.trim_end_matches(|c: char| c.is_whitespace()));
        let trimmed_after = after.trim_start_matches(|c: char| c.is_whitespace());
        let had_leading_ws = before.ends_with(|c: char| c.is_whitespace());
        if !out.is_empty() && !trimmed_after.is_empty() && had_leading_ws {
            out.push(' ');
        }
        rest = trimmed_after;
    }
    out.push_str(rest);
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn minimal_tweet_json(rest_id: &str, text: &str) -> Value {
        json!({
            "__typename": "Tweet",
            "rest_id": rest_id,
            "core": {
                "user_results": {
                    "result": {
                        "rest_id": "100",
                        "legacy": {
                            "screen_name": "testuser",
                            "name": "Test User",
                            "verified": false,
                            "followers_count": 500,
                            "friends_count": 200
                        },
                        "is_blue_verified": false
                    }
                }
            },
            "legacy": {
                "full_text": text,
                "created_at": "Mon Jan 01 12:00:00 +0000 2024",
                "reply_count": 3,
                "retweet_count": 7,
                "favorite_count": 42,
                "quote_count": 1,
                "favorited": false,
                "retweeted": false,
                "bookmarked": false,
                "lang": "en"
            },
            "views": { "count": "1000" }
        })
    }

    #[test]
    fn parse_basic_tweet() {
        let v = minimal_tweet_json("111", "hello world");
        let tweet = parse_tweet_result(&v).unwrap();
        assert_eq!(tweet.rest_id, "111");
        assert_eq!(tweet.text, "hello world");
        assert_eq!(tweet.author.handle, "testuser");
        assert_eq!(tweet.author.name, "Test User");
        assert_eq!(tweet.author.followers, 500);
        assert_eq!(tweet.reply_count, 3);
        assert_eq!(tweet.retweet_count, 7);
        assert_eq!(tweet.like_count, 42);
        assert_eq!(tweet.quote_count, 1);
        assert_eq!(tweet.view_count, Some(1000));
        assert_eq!(tweet.lang.as_deref(), Some("en"));
        assert!(tweet.in_reply_to_tweet_id.is_none());
        assert!(tweet.quoted_tweet.is_none());
        assert!(tweet.media.is_empty());
    }

    #[test]
    fn parse_visibility_wrapper() {
        let inner = minimal_tweet_json("222", "wrapped");
        let v = json!({
            "__typename": "TweetWithVisibilityResults",
            "tweet": inner
        });
        let tweet = parse_tweet_result(&v).unwrap();
        assert_eq!(tweet.rest_id, "222");
        assert_eq!(tweet.text, "wrapped");
    }

    #[test]
    fn parse_tombstone() {
        let v = json!({
            "__typename": "TweetTombstone",
            "tombstone": { "text": { "text": "This Tweet was deleted" } }
        });
        let err = parse_tweet_result(&v).unwrap_err();
        assert!(err.to_string().contains("tombstone"));
        assert!(err.to_string().contains("deleted"));
    }

    #[test]
    fn parse_unavailable() {
        let v = json!({
            "__typename": "TweetUnavailable",
            "reason": "Suspended"
        });
        let err = parse_tweet_result(&v).unwrap_err();
        assert!(err.to_string().contains("unavailable"));
        assert!(err.to_string().contains("Suspended"));
    }

    #[test]
    fn parse_quoted_tweet() {
        let mut v = minimal_tweet_json("333", "look at this");
        let qt = minimal_tweet_json("444", "the original");
        v["quoted_status_result"] = json!({ "result": qt });
        let tweet = parse_tweet_result(&v).unwrap();
        assert_eq!(tweet.rest_id, "333");
        let qt = tweet.quoted_tweet.unwrap();
        assert_eq!(qt.rest_id, "444");
        assert_eq!(qt.text, "the original");
    }

    #[test]
    fn parse_note_tweet() {
        let mut v = minimal_tweet_json("555", "short fallback");
        v["note_tweet"] = json!({
            "note_tweet_results": {
                "result": {
                    "text": "this is the long-form note tweet text that exceeds 280 chars"
                }
            }
        });
        let tweet = parse_tweet_result(&v).unwrap();
        assert!(tweet.text.starts_with("this is the long-form"));
    }

    #[test]
    fn parse_media_photo_and_video() {
        let mut v = minimal_tweet_json("666", "media tweet");
        v["legacy"]["extended_entities"] = json!({
            "media": [
                {
                    "type": "photo",
                    "media_url_https": "https://pbs.twimg.com/media/abc.jpg",
                    "ext_alt_text": "a photo"
                },
                {
                    "type": "video",
                    "media_url_https": "https://pbs.twimg.com/media/def.mp4",
                    "ext_alt_text": null
                },
                {
                    "type": "animated_gif",
                    "media_url_https": "https://pbs.twimg.com/media/ghi.mp4"
                }
            ]
        });
        let tweet = parse_tweet_result(&v).unwrap();
        assert_eq!(tweet.media.len(), 3);
        assert!(matches!(tweet.media[0].kind, MediaKind::Photo));
        assert_eq!(tweet.media[0].alt_text.as_deref(), Some("a photo"));
        assert!(tweet.media[0].video_url.is_none());
        assert!(matches!(tweet.media[1].kind, MediaKind::Video));
        assert!(tweet.media[1].alt_text.is_none());
        assert!(matches!(tweet.media[2].kind, MediaKind::AnimatedGif));
    }

    #[test]
    fn parse_video_picks_highest_bitrate_mp4() {
        let mut v = minimal_tweet_json("670", "video tweet");
        v["legacy"]["extended_entities"] = json!({
            "media": [
                {
                    "type": "video",
                    "media_url_https": "https://pbs.twimg.com/ext_tw_video/poster.jpg",
                    "video_info": {
                        "variants": [
                            {"content_type": "application/x-mpegURL", "url": "https://video.twimg.com/x.m3u8"},
                            {"bitrate": 832000, "content_type": "video/mp4", "url": "https://video.twimg.com/low.mp4"},
                            {"bitrate": 2176000, "content_type": "video/mp4", "url": "https://video.twimg.com/high.mp4"},
                            {"bitrate": 1280000, "content_type": "video/mp4", "url": "https://video.twimg.com/mid.mp4"}
                        ]
                    }
                }
            ]
        });
        let tweet = parse_tweet_result(&v).unwrap();
        assert_eq!(tweet.media.len(), 1);
        assert_eq!(
            tweet.media[0].video_url.as_deref(),
            Some("https://video.twimg.com/high.mp4")
        );
    }

    #[test]
    fn parse_animated_gif_extracts_mp4() {
        let mut v = minimal_tweet_json("671", "gif tweet");
        v["legacy"]["extended_entities"] = json!({
            "media": [
                {
                    "type": "animated_gif",
                    "media_url_https": "https://pbs.twimg.com/tweet_video_thumb/abc.jpg",
                    "video_info": {
                        "variants": [
                            {"bitrate": 0, "content_type": "video/mp4", "url": "https://video.twimg.com/gif.mp4"}
                        ]
                    }
                }
            ]
        });
        let tweet = parse_tweet_result(&v).unwrap();
        assert_eq!(
            tweet.media[0].video_url.as_deref(),
            Some("https://video.twimg.com/gif.mp4")
        );
    }

    #[test]
    fn scrub_strips_media_tco_from_text() {
        let mut v = minimal_tweet_json("700", "look at this pic https://t.co/ABC123");
        v["legacy"]["extended_entities"] = json!({
            "media": [
                {
                    "type": "photo",
                    "media_url_https": "https://pbs.twimg.com/media/x.jpg",
                    "url": "https://t.co/ABC123"
                }
            ]
        });
        let tweet = parse_tweet_result(&v).unwrap();
        assert_eq!(tweet.text, "look at this pic");
    }

    #[test]
    fn scrub_replaces_link_tco_with_display_url() {
        let mut v = minimal_tweet_json("701", "check https://t.co/SHORT for details");
        v["legacy"]["entities"] = json!({
            "urls": [
                {
                    "url": "https://t.co/SHORT",
                    "display_url": "example.com/real",
                    "expanded_url": "https://example.com/real/page"
                }
            ]
        });
        let tweet = parse_tweet_result(&v).unwrap();
        assert_eq!(tweet.text, "check example.com/real for details");
    }

    #[test]
    fn scrub_handles_multiple_media_tco_urls() {
        let mut v = minimal_tweet_json("702", "two pics https://t.co/AAA https://t.co/BBB end");
        v["legacy"]["extended_entities"] = json!({
            "media": [
                {"type": "photo", "media_url_https": "https://pbs.twimg.com/a.jpg", "url": "https://t.co/AAA"},
                {"type": "photo", "media_url_https": "https://pbs.twimg.com/b.jpg", "url": "https://t.co/BBB"}
            ]
        });
        let tweet = parse_tweet_result(&v).unwrap();
        assert_eq!(tweet.text, "two pics end");
    }

    #[test]
    fn scrub_trims_trailing_media_tco() {
        let mut v = minimal_tweet_json("703", "body https://t.co/XYZ");
        v["legacy"]["extended_entities"] = json!({
            "media": [
                {"type": "photo", "media_url_https": "https://pbs.twimg.com/x.jpg", "url": "https://t.co/XYZ"}
            ]
        });
        let tweet = parse_tweet_result(&v).unwrap();
        assert_eq!(tweet.text, "body");
    }

    #[test]
    fn scrub_leaves_text_without_entities() {
        let v = minimal_tweet_json("704", "plain text no urls");
        let tweet = parse_tweet_result(&v).unwrap();
        assert_eq!(tweet.text, "plain text no urls");
    }

    #[test]
    fn scrub_preserves_link_url_when_display_missing() {
        let mut v = minimal_tweet_json("705", "see https://t.co/ABC now");
        v["legacy"]["entities"] = json!({
            "urls": [
                {"url": "https://t.co/ABC"}
            ]
        });
        let tweet = parse_tweet_result(&v).unwrap();
        assert_eq!(tweet.text, "see https://t.co/ABC now");
    }

    #[test]
    fn parse_html_entities_decoded() {
        let v = minimal_tweet_json(
            "777",
            "1 &lt; 2 &amp; 3 &gt; 0 &quot;ok&quot; it&#39;s fine",
        );
        let tweet = parse_tweet_result(&v).unwrap();
        assert_eq!(tweet.text, "1 < 2 & 3 > 0 \"ok\" it's fine");
    }

    #[test]
    fn parse_reply_fields() {
        let mut v = minimal_tweet_json("888", "replying");
        v["legacy"]["in_reply_to_status_id_str"] = json!("777");
        let tweet = parse_tweet_result(&v).unwrap();
        assert_eq!(tweet.in_reply_to_tweet_id.as_deref(), Some("777"));
    }

    #[test]
    fn parse_verified_author() {
        let mut v = minimal_tweet_json("999", "verified");
        v["core"]["user_results"]["result"]["is_blue_verified"] = json!(true);
        let tweet = parse_tweet_result(&v).unwrap();
        assert!(tweet.author.verified);
    }

    #[test]
    fn parse_tweet_result_by_rest_id_wrapper() {
        let inner = minimal_tweet_json("1001", "via rest_id");
        let response = json!({
            "data": {
                "tweetResult": {
                    "result": inner
                }
            }
        });
        let tweet = parse_tweet_result_by_rest_id(&response).unwrap();
        assert_eq!(tweet.rest_id, "1001");
    }

    #[test]
    fn parse_missing_view_count() {
        let mut v = minimal_tweet_json("1002", "no views");
        v.as_object_mut().unwrap().remove("views");
        let tweet = parse_tweet_result(&v).unwrap();
        assert!(tweet.view_count.is_none());
    }

    #[test]
    fn parse_unknown_typename_errors() {
        let v = json!({ "__typename": "SomethingNew" });
        let err = parse_tweet_result(&v).unwrap_err();
        assert!(err.to_string().contains("SomethingNew"));
    }

    #[test]
    fn parse_engagement_state() {
        let mut v = minimal_tweet_json("1100", "engaged tweet");
        v["legacy"]["favorited"] = json!(true);
        v["legacy"]["retweeted"] = json!(true);
        v["legacy"]["bookmarked"] = json!(true);
        let tweet = parse_tweet_result(&v).unwrap();
        assert!(tweet.favorited);
        assert!(tweet.retweeted);
        assert!(tweet.bookmarked);
    }

    #[test]
    fn parse_engagement_defaults_false() {
        let mut v = minimal_tweet_json("1101", "unengaged");
        v["legacy"].as_object_mut().unwrap().remove("favorited");
        v["legacy"].as_object_mut().unwrap().remove("retweeted");
        v["legacy"].as_object_mut().unwrap().remove("bookmarked");
        let tweet = parse_tweet_result(&v).unwrap();
        assert!(!tweet.favorited);
        assert!(!tweet.retweeted);
        assert!(!tweet.bookmarked);
    }
}
