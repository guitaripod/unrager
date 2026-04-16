use crate::auth::XSession;
use crate::config::AppConfig;
use crate::gql::{GqlClient, QueryIdStore};
use crate::model::{Tweet, User};
use crate::parse::timeline::TimelinePage;
use crate::tui::app::*;
use crate::tui::event::Event;
use crate::tui::filter::FilterMode;
use crate::tui::media::MediaRegistry;
use crate::tui::seen::SeenStore;
use crate::tui::source::{Source, SourceKind};
use crate::tui::whisper::WhisperState;
use chrono::Utc;
use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::time::Instant;
use tempfile::TempDir;
use tokio::sync::mpsc;

pub fn dummy_app() -> (App, mpsc::UnboundedReceiver<Event>, TempDir) {
    let (tx, rx) = mpsc::unbounded_channel();
    let session = XSession {
        auth_token: "test".into(),
        ct0: "test".into(),
        twid: "test".into(),
    };
    let tmp = TempDir::new().unwrap();
    let store = QueryIdStore::with_fallbacks();
    let client = Arc::new(GqlClient::new(session, store, tmp.path().join("qids.json")).unwrap());
    let seen = SeenStore::open(&tmp.path().join("seen.db")).unwrap();
    let notif_seen = SeenStore::open(&tmp.path().join("notif_seen.db")).unwrap();
    let app = App {
        running: true,
        mode: InputMode::Normal,
        command_buffer: String::new(),
        source: Source::new(SourceKind::Home { following: true }),
        focus_stack: Vec::new(),
        active: ActivePane::Source,
        history: vec![SourceKind::Home { following: true }],
        history_cursor: 0,
        status: DEFAULT_STATUS.into(),
        status_until: None,
        error: None,
        last_tick: Instant::now(),
        terminal_focused: true,
        last_render_at: None,
        dirty: false,
        seen,
        session_path: tmp.path().join("session.json"),
        timestamps: TimestampStyle::Relative,
        metrics: MetricsStyle::Visible,
        display_names: DisplayNameStyle::Visible,
        split_pct: 50,
        spinner_frame: 0,
        is_dark: true,
        expanded_bodies: HashSet::new(),
        inline_threads: HashMap::new(),
        media: MediaRegistry::new(),
        media_auto_expand: false,
        feed_mode: FeedMode::All,
        self_handle: Some("testuser".into()),
        filter_mode: FilterMode::Off,
        filter_cfg: None,
        filter_cache: None,
        filter_classifier: None,
        filter_verdicts: HashMap::new(),
        filter_inflight: HashSet::new(),
        filter_hidden_count: 0,
        pending_classification: Vec::new(),
        translations: HashMap::new(),
        translation_inflight: HashSet::new(),
        engage_inflight: HashSet::new(),
        liked_tweet_ids: HashSet::new(),
        brief_cache: HashMap::new(),
        reply_sort: ReplySortOrder::Newest,
        app_config: AppConfig::default(),
        help_scroll: 0,
        whisper: WhisperState::new(),
        notif_seen,
        notif_unread_badge: 0,
        notif_actor_cursor: None,
        client,
        tx,
        pending_thread: None,
        pending_open: None,
        pending_notif_scroll: None,
        fetch_baseline: None,
        update_available: None,
        changelog: None,
        changelog_scroll: 0,
        changelog_loading: false,
    };
    (app, rx, tmp)
}

pub fn make_tweet(id: &str, text: &str) -> Tweet {
    Tweet {
        rest_id: id.to_string(),
        author: User {
            rest_id: "1".to_string(),
            handle: "test".to_string(),
            name: "Test".to_string(),
            verified: false,
            followers: 0,
            following: 0,
        },
        created_at: Utc::now(),
        text: text.to_string(),
        reply_count: 0,
        retweet_count: 0,
        like_count: 0,
        quote_count: 0,
        view_count: None,
        favorited: false,
        retweeted: false,
        bookmarked: false,
        lang: None,
        in_reply_to_tweet_id: None,
        quoted_tweet: None,
        media: vec![],
        url: format!("https://x.com/test/status/{id}"),
    }
}

pub fn make_page(tweets: Vec<Tweet>) -> TimelinePage {
    TimelinePage {
        tweets,
        next_cursor: None,
        top_cursor: None,
    }
}
