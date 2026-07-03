//! Wire-shape conformance, mirroring `UnragerKit/Tests/.../DecodingTests.swift`.
//! Guarantees the re-used `unrager-model` types decode the exact JSON the server
//! emits — the same fixtures the Apple client tests against.

use unrager_gtk_core::model::{
    AboutStatus, AboutView, FeedStatusResponse, FilterVerdictEvent, Media, MediaKind, Notification,
    SearchProduct, SessionState, SourceKind, ThreadView, TokenEvent, Tweet, Verdict,
};

fn decode<T: serde::de::DeserializeOwned>(json: &str) -> T {
    serde_json::from_str(json).expect("decode")
}

#[test]
fn feed_status_decodes() {
    let json = r#"
    {"feeds":[
      {"variant":"home_foryou","last_ingest_at":1782549081,"last_ingest_count":39,"age_secs":12},
      {"variant":"home_following","last_ingest_at":0,"last_ingest_count":0,"age_secs":-1}
    ]}
    "#;
    let resp: FeedStatusResponse = decode(json);
    assert_eq!(resp.feeds.len(), 2);
    assert_eq!(resp.feeds[0].variant, "home_foryou");
    assert_eq!(resp.feeds[0].last_ingest_count, 39);
    assert_eq!(resp.feeds[1].age_secs, -1, "a cold variant reports age -1");
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

const MINIMAL_TWEET: &str = r#"
{"rest_id":"1","author":{"rest_id":"2","handle":"a","name":"A","verified":false,
  "followers":0,"following":0},"created_at":"2026-06-19T12:00:00Z","text":"hi",
  "reply_count":0,"retweet_count":0,"like_count":0,"quote_count":0,"view_count":null,
  "media":[],"url":"https://x.com/a/status/1"}
"#;

#[test]
fn thread_view_first_page_carries_focal() {
    let json = format!(
        r#"{{"focal":{MINIMAL_TWEET},"ancestors":[],"replies":[{MINIMAL_TWEET}],"cursor":"next"}}"#
    );
    let view: ThreadView = decode(&json);
    assert_eq!(view.focal.as_ref().map(|t| t.rest_id.as_str()), Some("1"));
    assert_eq!(view.replies.len(), 1);
    assert_eq!(view.cursor.as_deref(), Some("next"));
}

#[test]
fn thread_view_continuation_omits_focal() {
    let json = format!(r#"{{"replies":[{MINIMAL_TWEET}],"cursor":null}}"#);
    let view: ThreadView = decode(&json);
    assert!(
        view.focal.is_none(),
        "continuation pages carry no focal key"
    );
    assert!(view.ancestors.is_empty());
    assert_eq!(view.replies.len(), 1);
    assert!(view.cursor.is_none());
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
fn about_view_resolved_carries_profile_and_derived_flag() {
    let json = r#"
    {"status":"resolved",
     "profile":{"rest_id":"44196397","handle":"elonmusk","name":"Elon Musk",
                "account_based_in":"United States","location_accurate":true,
                "source":"United States App Store","username_changes":2,
                "created_at":"2009-06-02T20:12:29Z","is_blue_verified":true,"verified":false},
     "alpha2":"US","flag":"🇺🇸"}
    "#;
    let view: AboutView = decode(json);
    assert_eq!(view.status, AboutStatus::Resolved);
    let profile = view.profile.expect("resolved carries a profile");
    assert_eq!(profile.handle, "elonmusk");
    assert_eq!(profile.account_based_in.as_deref(), Some("United States"));
    assert_eq!(view.alpha2.as_deref(), Some("US"));
    assert_eq!(view.flag.as_deref(), Some("🇺🇸"));
}

#[test]
fn about_view_resolved_without_country_has_no_flag() {
    let json = r#"
    {"status":"resolved",
     "profile":{"rest_id":"9","handle":"a","name":"A"},
     "alpha2":null,"flag":null}
    "#;
    let view: AboutView = decode(json);
    assert_eq!(view.status, AboutStatus::Resolved);
    assert!(view.profile.is_some());
    assert!(view.alpha2.is_none());
    assert!(view.flag.is_none());
}

#[test]
fn about_view_none_decodes_with_explicit_nulls_and_with_omitted_fields() {
    let explicit: AboutView =
        decode(r#"{"status":"none","profile":null,"alpha2":null,"flag":null}"#);
    assert_eq!(explicit.status, AboutStatus::None);
    assert!(explicit.profile.is_none());
    assert!(explicit.alpha2.is_none());
    assert!(explicit.flag.is_none());

    let omitted: AboutView = decode(r#"{"status":"none"}"#);
    assert_eq!(omitted.status, AboutStatus::None);
    assert!(omitted.profile.is_none());
    assert!(omitted.flag.is_none());
}

#[test]
fn about_view_deferred_decodes_with_explicit_nulls_and_with_omitted_fields() {
    let explicit: AboutView =
        decode(r#"{"status":"deferred","profile":null,"alpha2":null,"flag":null}"#);
    assert_eq!(explicit.status, AboutStatus::Deferred);
    assert!(explicit.profile.is_none());

    let omitted: AboutView = decode(r#"{"status":"deferred"}"#);
    assert_eq!(omitted.status, AboutStatus::Deferred);
    assert!(omitted.flag.is_none());
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
