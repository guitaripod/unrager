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

    let mut media = parse_media(legacy);
    let (youtube_media, youtube_tcos) = parse_youtube_embeds(legacy);
    media.extend(youtube_media);
    let (article_media, article_tcos) = parse_article_embed(node, legacy);
    media.extend(article_media);
    let text = strip_tco_urls(&text, &youtube_tcos);
    let text = strip_tco_urls(&text, &article_tcos);

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
                MediaKind::Photo | MediaKind::YouTube { .. } | MediaKind::Article { .. } => None,
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

/// Scans `entities.urls` for YouTube links and returns synthesized Media entries
/// plus the `display_url` tokens whose substitutions should be stripped from the
/// tweet body. scrub_urls_in_text has already replaced t.co with display_url by
/// the time we strip, so we match on display_url.
fn parse_youtube_embeds(legacy: &Value) -> (Vec<Media>, Vec<String>) {
    let mut embeds = Vec::new();
    let mut display_urls = Vec::new();
    let Some(arr) = legacy.pointer("/entities/urls").and_then(Value::as_array) else {
        return (embeds, display_urls);
    };
    for u in arr {
        let expanded = u.get("expanded_url").and_then(Value::as_str).unwrap_or("");
        let Some(video_id) = extract_youtube_id(expanded) else {
            continue;
        };
        let thumbnail = format!("https://img.youtube.com/vi/{video_id}/mqdefault.jpg");
        embeds.push(Media {
            kind: MediaKind::YouTube { video_id },
            url: thumbnail,
            video_url: None,
            alt_text: None,
        });
        if let Some(display) = u.get("display_url").and_then(Value::as_str) {
            display_urls.push(display.to_string());
        }
    }
    (embeds, display_urls)
}

/// Extracts the X article preview from `node.article.article_results.result`
/// (when `articles_preview_enabled` is on) and, when an article is found, also
/// returns the display_url of its `entities.urls[]` entry so the t.co link
/// can be stripped from the tweet body. Falls back to URL-only detection
/// (minimal card, empty title/preview) if the article object is absent.
fn parse_article_embed(node: &Value, legacy: &Value) -> (Vec<Media>, Vec<String>) {
    let mut embeds = Vec::new();
    let mut display_urls = Vec::new();

    let inline = node
        .pointer("/article/article_results/result")
        .and_then(parse_article_result);

    if let Some((article_id, title, preview_text, cover_url)) = inline {
        collect_article_display_url(legacy, &article_id, &mut display_urls);
        embeds.push(Media {
            kind: MediaKind::Article {
                article_id,
                title,
                preview_text,
            },
            url: cover_url,
            video_url: None,
            alt_text: None,
        });
        return (embeds, display_urls);
    }

    if let Some(arr) = legacy.pointer("/entities/urls").and_then(Value::as_array) {
        for u in arr {
            let expanded = u.get("expanded_url").and_then(Value::as_str).unwrap_or("");
            let Some(article_id) = extract_article_id(expanded) else {
                continue;
            };
            if let Some(display) = u.get("display_url").and_then(Value::as_str) {
                display_urls.push(display.to_string());
            }
            embeds.push(Media {
                kind: MediaKind::Article {
                    article_id,
                    title: String::new(),
                    preview_text: String::new(),
                },
                url: String::new(),
                video_url: None,
                alt_text: None,
            });
        }
    }

    (embeds, display_urls)
}

fn parse_article_result(result: &Value) -> Option<(String, String, String, String)> {
    let article_id = result
        .get("rest_id")
        .and_then(Value::as_str)
        .map(str::to_string)?;
    let title = result
        .get("title")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    let preview_text = result
        .get("preview_text")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    let cover_url = result
        .pointer("/cover_media/media_info/original_img_url")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    Some((
        article_id,
        decode_html_entities(&title),
        decode_html_entities(&preview_text),
        cover_url,
    ))
}

fn collect_article_display_url(legacy: &Value, article_id: &str, out: &mut Vec<String>) {
    let Some(arr) = legacy.pointer("/entities/urls").and_then(Value::as_array) else {
        return;
    };
    for u in arr {
        let expanded = u.get("expanded_url").and_then(Value::as_str).unwrap_or("");
        if extract_article_id(expanded).as_deref() == Some(article_id) {
            if let Some(display) = u.get("display_url").and_then(Value::as_str) {
                out.push(display.to_string());
            }
        }
    }
}

/// Returns the numeric article id from an X article URL. Accepts both the
/// canonical `/i/article/{id}` shape and the per-user `/{handle}/article/{id}`
/// shape. Ignores extra path segments and query strings.
pub fn extract_article_id(url: &str) -> Option<String> {
    let rest = url
        .strip_prefix("https://")
        .or_else(|| url.strip_prefix("http://"))
        .unwrap_or(url);
    let rest = rest
        .strip_prefix("www.")
        .or_else(|| rest.strip_prefix("m."))
        .unwrap_or(rest);

    let (host, path_query) = rest.split_once('/')?;
    if host != "x.com" && host != "twitter.com" {
        return None;
    }

    let path = path_query.split(['?', '#']).next().unwrap_or("");
    let segments: Vec<&str> = path.split('/').filter(|s| !s.is_empty()).collect();
    let id = match segments.as_slice() {
        ["i", "article", id, ..] => *id,
        [_handle, "article", id, ..] => *id,
        _ => return None,
    };
    if is_numeric_id(id) {
        Some(id.to_string())
    } else {
        None
    }
}

fn is_numeric_id(s: &str) -> bool {
    !s.is_empty() && s.chars().all(|c| c.is_ascii_digit())
}

/// Returns the 11-character YouTube video id from a watch URL, short URL, or
/// embed URL. Accepts both `youtube.com` and `youtu.be`, http or https, with or
/// without `www.`/`m.`, and ignores extra query parameters.
pub fn extract_youtube_id(url: &str) -> Option<String> {
    let rest = url
        .strip_prefix("https://")
        .or_else(|| url.strip_prefix("http://"))
        .unwrap_or(url);
    let rest = rest
        .strip_prefix("www.")
        .or_else(|| rest.strip_prefix("m."))
        .unwrap_or(rest);

    let (host, path_query) = rest.split_once('/')?;

    let raw_id = match host {
        "youtu.be" => path_query.split(['?', '&', '#']).next().unwrap_or(""),
        "youtube.com" => {
            if let Some(after) = path_query.strip_prefix("watch") {
                let query = after.strip_prefix('?').unwrap_or(after);
                query
                    .split('&')
                    .find_map(|kv| kv.strip_prefix("v="))
                    .unwrap_or("")
            } else if let Some(after) = path_query.strip_prefix("shorts/") {
                after.split(['?', '&', '#', '/']).next().unwrap_or("")
            } else if let Some(after) = path_query.strip_prefix("embed/") {
                after.split(['?', '&', '#', '/']).next().unwrap_or("")
            } else if let Some(after) = path_query.strip_prefix("live/") {
                after.split(['?', '&', '#', '/']).next().unwrap_or("")
            } else {
                ""
            }
        }
        _ => return None,
    };

    if is_valid_youtube_id(raw_id) {
        Some(raw_id.to_string())
    } else {
        None
    }
}

fn is_valid_youtube_id(s: &str) -> bool {
    s.len() == 11
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

fn strip_tco_urls(text: &str, tcos: &[String]) -> String {
    let mut out = text.to_string();
    for tco in tcos {
        out = strip_url(&out, tco);
    }
    out.trim().to_string()
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
    fn youtube_id_from_watch_url() {
        assert_eq!(
            extract_youtube_id("https://www.youtube.com/watch?v=dQw4w9WgXcQ"),
            Some("dQw4w9WgXcQ".into())
        );
        assert_eq!(
            extract_youtube_id("https://youtube.com/watch?v=dQw4w9WgXcQ&t=42s"),
            Some("dQw4w9WgXcQ".into())
        );
        assert_eq!(
            extract_youtube_id("https://m.youtube.com/watch?v=dQw4w9WgXcQ"),
            Some("dQw4w9WgXcQ".into())
        );
    }

    #[test]
    fn youtube_id_from_short_url() {
        assert_eq!(
            extract_youtube_id("https://youtu.be/dQw4w9WgXcQ"),
            Some("dQw4w9WgXcQ".into())
        );
        assert_eq!(
            extract_youtube_id("https://youtu.be/dQw4w9WgXcQ?t=42"),
            Some("dQw4w9WgXcQ".into())
        );
    }

    #[test]
    fn youtube_id_from_shorts_embed_live() {
        assert_eq!(
            extract_youtube_id("https://www.youtube.com/shorts/abcdefghijk"),
            Some("abcdefghijk".into())
        );
        assert_eq!(
            extract_youtube_id("https://www.youtube.com/embed/abcdefghijk"),
            Some("abcdefghijk".into())
        );
        assert_eq!(
            extract_youtube_id("https://www.youtube.com/live/abcdefghijk"),
            Some("abcdefghijk".into())
        );
    }

    #[test]
    fn youtube_id_rejects_non_youtube() {
        assert_eq!(
            extract_youtube_id("https://example.com/watch?v=abcdefghijk"),
            None
        );
        assert_eq!(extract_youtube_id("https://youtube.com/"), None);
        assert_eq!(
            extract_youtube_id("https://youtube.com/channel/UCabc"),
            None
        );
    }

    #[test]
    fn youtube_id_rejects_malformed_id() {
        assert_eq!(extract_youtube_id("https://youtu.be/short"), None);
        assert_eq!(
            extract_youtube_id("https://youtu.be/waytoolongidentifier"),
            None
        );
        assert_eq!(extract_youtube_id("https://youtu.be/has space1"), None);
    }

    #[test]
    fn parse_injects_youtube_media_and_strips_display_url() {
        let mut v = minimal_tweet_json("2100", "watch this https://t.co/YT vibes");
        v["legacy"]["entities"] = json!({
            "urls": [
                {
                    "url": "https://t.co/YT",
                    "display_url": "youtu.be/dQw4w9WgXcQ",
                    "expanded_url": "https://youtu.be/dQw4w9WgXcQ"
                }
            ]
        });
        let tweet = parse_tweet_result(&v).unwrap();
        assert_eq!(tweet.media.len(), 1);
        match &tweet.media[0].kind {
            MediaKind::YouTube { video_id } => assert_eq!(video_id, "dQw4w9WgXcQ"),
            other => panic!("expected YouTube kind, got {other:?}"),
        }
        assert_eq!(
            tweet.media[0].url,
            "https://img.youtube.com/vi/dQw4w9WgXcQ/mqdefault.jpg"
        );
        assert_eq!(tweet.text, "watch this vibes");
    }

    #[test]
    fn parse_leaves_non_youtube_url_untouched() {
        let mut v = minimal_tweet_json("2101", "read https://t.co/AB about foo");
        v["legacy"]["entities"] = json!({
            "urls": [
                {
                    "url": "https://t.co/AB",
                    "display_url": "example.com/article",
                    "expanded_url": "https://example.com/article"
                }
            ]
        });
        let tweet = parse_tweet_result(&v).unwrap();
        assert!(tweet.media.is_empty());
        assert_eq!(tweet.text, "read example.com/article about foo");
    }

    #[test]
    fn article_id_from_canonical_url() {
        assert_eq!(
            extract_article_id("https://x.com/i/article/1789876543210987654"),
            Some("1789876543210987654".into())
        );
        assert_eq!(
            extract_article_id("https://twitter.com/i/article/1234"),
            Some("1234".into())
        );
    }

    #[test]
    fn article_id_from_user_url() {
        assert_eq!(
            extract_article_id("https://x.com/someuser/article/1789876543210987654"),
            Some("1789876543210987654".into())
        );
        assert_eq!(
            extract_article_id("https://x.com/foo/article/42/extra/path"),
            Some("42".into())
        );
    }

    #[test]
    fn article_id_rejects_non_article() {
        assert_eq!(extract_article_id("https://x.com/i/status/1234"), None);
        assert_eq!(extract_article_id("https://example.com/i/article/1"), None);
        assert_eq!(extract_article_id("https://x.com/"), None);
        assert_eq!(
            extract_article_id("https://x.com/user/status/123/article/456"),
            None
        );
    }

    #[test]
    fn article_id_rejects_non_numeric() {
        assert_eq!(extract_article_id("https://x.com/i/article/abc"), None);
        assert_eq!(extract_article_id("https://x.com/i/article/"), None);
    }

    #[test]
    fn parse_injects_inline_article_with_cover() {
        let mut v = minimal_tweet_json("3000", "read my article https://t.co/ART");
        v["legacy"]["entities"] = json!({
            "urls": [
                {
                    "url": "https://t.co/ART",
                    "display_url": "x.com/i/article/99…",
                    "expanded_url": "https://x.com/i/article/9911223344"
                }
            ]
        });
        v["article"] = json!({
            "article_results": {
                "result": {
                    "rest_id": "9911223344",
                    "title": "Why rage filters matter",
                    "preview_text": "A short teaser shown in the card.",
                    "cover_media": {
                        "media_info": {
                            "original_img_url": "https://pbs.twimg.com/media/ABC.jpg"
                        }
                    }
                }
            }
        });
        let tweet = parse_tweet_result(&v).unwrap();
        assert_eq!(tweet.media.len(), 1);
        match &tweet.media[0].kind {
            MediaKind::Article {
                article_id,
                title,
                preview_text,
            } => {
                assert_eq!(article_id, "9911223344");
                assert_eq!(title, "Why rage filters matter");
                assert_eq!(preview_text, "A short teaser shown in the card.");
            }
            other => panic!("expected Article, got {other:?}"),
        }
        assert_eq!(tweet.media[0].url, "https://pbs.twimg.com/media/ABC.jpg");
        assert_eq!(tweet.text, "read my article");
    }

    #[test]
    fn parse_article_fallback_from_url_only() {
        let mut v = minimal_tweet_json("3001", "check this https://t.co/AR2");
        v["legacy"]["entities"] = json!({
            "urls": [
                {
                    "url": "https://t.co/AR2",
                    "display_url": "x.com/i/article/77…",
                    "expanded_url": "https://x.com/i/article/7788"
                }
            ]
        });
        let tweet = parse_tweet_result(&v).unwrap();
        assert_eq!(tweet.media.len(), 1);
        match &tweet.media[0].kind {
            MediaKind::Article {
                article_id,
                title,
                preview_text,
            } => {
                assert_eq!(article_id, "7788");
                assert!(title.is_empty());
                assert!(preview_text.is_empty());
            }
            other => panic!("expected Article, got {other:?}"),
        }
        assert!(tweet.media[0].url.is_empty());
        assert_eq!(tweet.text, "check this");
    }

    #[test]
    fn parse_article_decodes_entities_in_title() {
        let mut v = minimal_tweet_json("3002", "read this");
        v["legacy"]["entities"] = json!({
            "urls": [{
                "url": "https://t.co/X",
                "display_url": "x.com/i/article/42",
                "expanded_url": "https://x.com/i/article/42"
            }]
        });
        v["article"] = json!({
            "article_results": {
                "result": {
                    "rest_id": "42",
                    "title": "Tom &amp; Jerry &lt;deep dive&gt;",
                    "preview_text": "it&#39;s a classic"
                }
            }
        });
        let tweet = parse_tweet_result(&v).unwrap();
        match &tweet.media[0].kind {
            MediaKind::Article {
                title,
                preview_text,
                ..
            } => {
                assert_eq!(title, "Tom & Jerry <deep dive>");
                assert_eq!(preview_text, "it's a classic");
            }
            _ => panic!("expected Article"),
        }
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
