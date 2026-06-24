//! Wire-shape conformance, mirroring `UnragerKit/Tests/.../DecodingTests.swift`.
//! Guarantees the re-used `unrager-model` types decode the exact JSON the server
//! emits — the same fixtures the Apple client tests against.

use unrager_gtk_core::model::{
    FilterVerdictEvent, Media, MediaKind, Notification, SearchProduct, SessionState, SourceKind,
    TokenEvent, Tweet, Verdict,
};

fn decode<T: serde::de::DeserializeOwned>(json: &str) -> T {
    serde_json::from_str(json).expect("decode")
}

#[test]
fn full_tweet_with_nested_quote_media_and_counts() {
    let json = r#"
    {
      "rest_id": "1790000000000000001",
      "author": {"rest_id":"44196397","handle":"elonmusk","name":"Elon Musk",
                 "verified":true,"followers":200000000,"following":500,
                 "avatar_url":"https://pbs.twimg.com/x_normal.jpg"},
      "created_at": "2026-06-19T12:00:00Z",
      "text": "Hello world",
      "reply_count": 12, "retweet_count": 34, "like_count": 567, "quote_count": 8,
      "view_count": 102345, "bookmark_count": 5,
      "favorited": false, "retweeted": false, "bookmarked": false,
      "lang": "en", "in_reply_to_tweet_id": null,
      "quoted_tweet": {
        "rest_id":"123","author":{"rest_id":"1","handle":"a","name":"A","verified":false,
          "followers":0,"following":0,"avatar_url":null},
        "created_at":"2026-06-18T12:00:00Z","text":"quoted","reply_count":0,
        "retweet_count":0,"like_count":0,"quote_count":0,"view_count":null,
        "media":[],"url":"https://x.com/a/status/123","urls":[]
      },
      "media": [{"kind":"photo","url":"https://pbs.twimg.com/m.jpg","video_url":null,"alt_text":"a cat"}],
      "url": "https://x.com/elonmusk/status/1790000000000000001",
      "urls": [{"expanded_url":"https://example.com/a","display_url":"example.com/a"}]
    }
    "#;
    let tweet: Tweet = decode(json);
    assert_eq!(tweet.rest_id, "1790000000000000001");
    assert_eq!(tweet.author.handle, "elonmusk");
    assert_eq!(tweet.like_count, 567);
    assert_eq!(tweet.view_count, Some(102345));
    assert_eq!(tweet.bookmark_count, 5);
    assert_eq!(tweet.quoted_tweet.as_ref().unwrap().rest_id, "123");
    assert_eq!(tweet.media.len(), 1);
    assert_eq!(tweet.media[0].kind, MediaKind::Photo);
    assert_eq!(tweet.media[0].alt_text.as_deref(), Some("a cat"));
    assert_eq!(tweet.urls[0].display_url, "example.com/a");
}

#[test]
fn tweet_tolerates_missing_defaultable_fields() {
    let json = r#"
    {"rest_id":"1","author":{"rest_id":"2","handle":"a","name":"A","verified":false,
      "followers":0,"following":0},"created_at":"2026-06-19T12:00:00Z","text":"hi",
      "reply_count":0,"retweet_count":0,"like_count":0,"quote_count":0,"view_count":null,
      "media":[],"url":"https://x.com/a/status/1"}
    "#;
    let tweet: Tweet = decode(json);
    assert_eq!(tweet.bookmark_count, 0);
    assert!(!tweet.favorited);
    assert!(tweet.media.is_empty());
    assert!(tweet.urls.is_empty());
    assert_eq!(tweet.view_count, None);
    assert_eq!(tweet.author.avatar_url, None);
}

#[test]
fn media_kind_unit_and_struct_variants() {
    let video: Media =
        decode(r#"{"kind":"video","url":"p.jpg","video_url":"v.mp4","alt_text":null}"#);
    assert_eq!(video.kind, MediaKind::Video);
    assert_eq!(video.video_url.as_deref(), Some("v.mp4"));

    let gif: Media = decode(r#"{"kind":"animated_gif","url":"g.jpg","video_url":"g.mp4"}"#);
    assert_eq!(gif.kind, MediaKind::AnimatedGif);

    let yt: Media = decode(r#"{"kind":{"you_tube":{"video_id":"dQw4w9WgXcQ"}},"url":"y.jpg"}"#);
    assert_eq!(
        yt.kind,
        MediaKind::YouTube {
            video_id: "dQw4w9WgXcQ".to_string()
        }
    );

    let card: Media = decode(
        r#"{"kind":{"link_card":{"title":"T","description":"D","domain":"example.com","target_url":"https://example.com"}},"url":"c.jpg"}"#,
    );
    match card.kind {
        MediaKind::LinkCard {
            title,
            domain,
            target_url,
            ..
        } => {
            assert_eq!(title, "T");
            assert_eq!(domain, "example.com");
            assert_eq!(target_url, "https://example.com");
        }
        other => panic!("expected link_card, got {other:?}"),
    }

    let poll: Media = decode(
        r#"{"kind":{"poll":{"options":[{"label":"A","count":10},{"label":"B","count":3}],"ends_at":"2026-06-20T00:00:00Z","counts_final":false}},"url":""}"#,
    );
    match poll.kind {
        MediaKind::Poll {
            options,
            ends_at,
            counts_final,
        } => {
            assert_eq!(options.len(), 2);
            assert_eq!(options[0].count, 10);
            assert!(ends_at.is_some());
            assert!(!counts_final);
        }
        other => panic!("expected poll, got {other:?}"),
    }
}

#[test]
fn source_kind_round_trips() {
    let cases = [
        SourceKind::Home { following: true },
        SourceKind::User {
            handle: "elonmusk".to_string(),
        },
        SourceKind::Search {
            query: "rust".to_string(),
            product: SearchProduct::Top,
        },
        SourceKind::Mentions { target: None },
        SourceKind::Bookmarks {
            query: "*".to_string(),
        },
    ];
    for case in cases {
        let data = serde_json::to_string(&case).unwrap();
        let decoded: SourceKind = serde_json::from_str(&data).unwrap();
        assert_eq!(decoded, case);
    }
}

#[test]
fn session_state_applies_defaults() {
    let state: SessionState = decode(r#"{"current_source":null}"#);
    assert_eq!(state.feed_mode, unrager_gtk_core::model::FeedMode::All);
    assert!(!state.filter_enabled);
    assert!(state.current_source.is_none());
}

#[test]
fn sse_event_shapes() {
    let token: TokenEvent = decode(r#"{"token":"hi","done":false}"#);
    assert_eq!(token.token, "hi");
    let done: TokenEvent = decode(r#"{"token":"","done":true}"#);
    assert!(done.done);
    let verdict: FilterVerdictEvent = decode(r#"{"id":"1","verdict":"hide"}"#);
    assert_eq!(verdict.verdict, Verdict::Hide);
}

#[test]
fn notification_renames_type_and_carries_target_media() {
    let json = r#"
    {"id":"n1","type":"like","actors":[{"handle":"a","name":"A","rest_id":"9","verified":false,"avatar_url":"https://pbs.twimg.com/a.jpg"}],
     "target_tweet_id":"1","target_tweet_snippet":"hi","target_tweet_like_count":5,
     "target_media":[{"kind":"photo","url":"https://pbs.twimg.com/media/x.jpg","video_url":null,"alt_text":null,"width":1200,"height":675}],
     "timestamp":"2026-06-19T12:30:00Z"}
    "#;
    let notif: Notification = decode(json);
    assert_eq!(notif.kind, "like");
    assert_eq!(notif.actors[0].handle, "a");
    assert_eq!(
        notif.actors[0].avatar_url.as_deref(),
        Some("https://pbs.twimg.com/a.jpg")
    );
    assert_eq!(notif.target_tweet_like_count, Some(5));
    assert_eq!(notif.target_media[0].kind, MediaKind::Photo);
    assert_eq!(
        notif.target_media[0].url,
        "https://pbs.twimg.com/media/x.jpg"
    );
    assert_eq!(notif.target_media[0].width, Some(1200));
}
