use crate::cli::common;
use crate::gql::endpoints;
use crate::gql::query_ids::Operation;
use crate::parse::timeline;
use crate::server::error::ApiError;
use crate::server::state::AppState;
use crate::store::feed::FeedVariant;
use crate::tui::source;
use crate::tui::whisper;
use axum::Json;
use axum::extract::{Path, Query, State};
use serde::Deserialize;
use std::sync::Arc;
use unrager_model::{TimelinePage, Tweet};

#[derive(Debug, Deserialize, Default)]
pub struct PageQuery {
    #[serde(default)]
    pub cursor: Option<String>,
    #[serde(default)]
    pub count: Option<u32>,
}

const DEFAULT_COUNT: u32 = 20;

#[derive(Debug, Deserialize, Default)]
pub struct HomeQuery {
    #[serde(default)]
    pub following: bool,
    #[serde(default)]
    pub cursor: Option<String>,
    #[serde(default)]
    pub count: Option<u32>,
    #[serde(default)]
    pub mode: Option<String>,
}

pub async fn home(
    State(state): State<Arc<AppState>>,
    Query(q): Query<HomeQuery>,
) -> std::result::Result<Json<TimelinePage>, ApiError> {
    state.activity.touch();
    let count = q.count.unwrap_or(DEFAULT_COUNT);
    let variant = FeedVariant::from_following(q.following);
    let cursor = q.cursor.as_deref().filter(|c| !c.is_empty());

    let stored = if crate::store::feed::cursor_belongs_to_store(cursor) {
        let store = state.feed.lock().await;
        let cold = store.count(variant).map(|n| n == 0).unwrap_or(true);
        if cold && cursor.is_none() {
            None
        } else {
            Some(store.read_page(variant, cursor, count as usize)?)
        }
    } else {
        None
    };

    let page = match stored {
        Some(page) => {
            let tweets: Vec<Tweet> = page.items.into_iter().map(|s| s.tweet).collect();
            TimelinePage {
                tweets: apply_mode(tweets, q.mode.as_deref()),
                cursor: page.next_cursor,
            }
        }
        None => home_live(&state, q.following, count, cursor, q.mode.as_deref()).await?,
    };
    Ok(Json(page))
}

/// Live fetch used when the materialized buffer is still cold (e.g. the very
/// first launch before the ingest worker has filled it) and for continuing
/// pagination with the live X cursor such a cold first page handed out.
async fn home_live(
    state: &Arc<AppState>,
    following: bool,
    count: u32,
    cursor: Option<&str>,
    mode: Option<&str>,
) -> std::result::Result<TimelinePage, ApiError> {
    let op = if following {
        Operation::HomeLatestTimeline
    } else {
        Operation::HomeTimeline
    };
    let response = state
        .gql
        .post(
            op,
            &endpoints::home_timeline_variables(count, cursor, &[]),
            &endpoints::home_timeline_features(),
        )
        .await?;
    let instructions =
        timeline::extract_instructions(&response, "/data/home/home_timeline_urt/instructions")?;
    let page = timeline::walk(instructions);
    Ok(TimelinePage {
        tweets: apply_mode(page.tweets, mode),
        cursor: page.next_cursor,
    })
}

fn apply_mode(tweets: Vec<Tweet>, mode: Option<&str>) -> Vec<Tweet> {
    if mode == Some("originals") {
        filter_originals(tweets)
    } else {
        tweets
    }
}

fn filter_originals(v: Vec<Tweet>) -> Vec<Tweet> {
    v.into_iter()
        .filter(|t| {
            t.in_reply_to_tweet_id.is_none()
                && t.quoted_tweet.is_none()
                && !t.text.starts_with("RT @")
        })
        .collect()
}

#[derive(Debug, Deserialize, Default)]
pub struct UserQuery {
    #[serde(default)]
    pub cursor: Option<String>,
    #[serde(default)]
    pub count: Option<u32>,
    #[serde(default)]
    pub include_replies: bool,
}

pub async fn user(
    State(state): State<Arc<AppState>>,
    Path(handle): Path<String>,
    Query(q): Query<UserQuery>,
) -> std::result::Result<Json<TimelinePage>, ApiError> {
    user_timeline(&state, &handle, &q, q.include_replies).await
}

/// The tweets-and-replies variant of a user timeline (the TUI's `R` toggle),
/// exposed both as this subresource and as `?include_replies=true` on the
/// base route.
pub async fn user_replies(
    State(state): State<Arc<AppState>>,
    Path(handle): Path<String>,
    Query(q): Query<UserQuery>,
) -> std::result::Result<Json<TimelinePage>, ApiError> {
    user_timeline(&state, &handle, &q, true).await
}

async fn user_timeline(
    state: &Arc<AppState>,
    handle: &str,
    q: &UserQuery,
    include_replies: bool,
) -> std::result::Result<Json<TimelinePage>, ApiError> {
    let screen = handle.trim_start_matches('@');
    if screen.is_empty() {
        return Err(ApiError::bad_request("empty handle"));
    }
    let count = q.count.unwrap_or(DEFAULT_COUNT);
    let user_id = source::resolve_user_id(&state.gql, screen).await?;
    let op = if include_replies {
        Operation::UserTweetsAndReplies
    } else {
        Operation::UserTweets
    };
    let response = state
        .gql
        .get(
            op,
            &endpoints::user_tweets_variables(&user_id, count, q.cursor.as_deref()),
            &endpoints::user_tweets_features(),
        )
        .await?;
    let instructions = timeline::extract_instructions_multi(
        &response,
        &[
            "/data/user/result/timeline/timeline/instructions",
            "/data/user/result/timeline_v2/timeline/instructions",
        ],
    )?;
    let page = timeline::walk(instructions);
    Ok(Json(TimelinePage {
        tweets: page.tweets,
        cursor: page.next_cursor,
    }))
}

#[derive(Debug, Deserialize)]
pub struct SearchQuery {
    pub q: String,
    #[serde(default = "default_product")]
    pub product: String,
    #[serde(default)]
    pub cursor: Option<String>,
    #[serde(default)]
    pub count: Option<u32>,
}

fn default_product() -> String {
    "Latest".into()
}

pub async fn search(
    State(state): State<Arc<AppState>>,
    Query(q): Query<SearchQuery>,
) -> std::result::Result<Json<TimelinePage>, ApiError> {
    if q.q.trim().is_empty() {
        return Err(ApiError::bad_request("empty query"));
    }
    let count = q.count.unwrap_or(DEFAULT_COUNT);
    let product = normalize_product(&q.product);
    let response = state
        .gql
        .post(
            Operation::SearchTimeline,
            &endpoints::search_timeline_variables(&q.q, count, product, q.cursor.as_deref()),
            &endpoints::search_timeline_features(),
        )
        .await?;
    let instructions = timeline::extract_instructions(
        &response,
        "/data/search_by_raw_query/search_timeline/timeline/instructions",
    )?;
    let page = timeline::walk(instructions);
    Ok(Json(TimelinePage {
        tweets: page.tweets,
        cursor: page.next_cursor,
    }))
}

fn normalize_product(s: &str) -> &'static str {
    match s.to_ascii_lowercase().as_str() {
        "top" => "Top",
        "latest" => "Latest",
        "people" => "People",
        "photos" => "Photos",
        "videos" => "Videos",
        _ => "Latest",
    }
}

pub async fn mentions(
    State(state): State<Arc<AppState>>,
    Query(q): Query<PageQuery>,
) -> std::result::Result<Json<TimelinePage>, ApiError> {
    let handle = common::current_handle(&state.gql).await?;
    let query = format!("@{handle} -from:{handle}");
    let count = q.count.unwrap_or(DEFAULT_COUNT);
    let response = state
        .gql
        .post(
            Operation::SearchTimeline,
            &endpoints::search_timeline_variables(&query, count, "Latest", q.cursor.as_deref()),
            &endpoints::search_timeline_features(),
        )
        .await?;
    let instructions = timeline::extract_instructions(
        &response,
        "/data/search_by_raw_query/search_timeline/timeline/instructions",
    )?;
    let page = timeline::walk(instructions);
    Ok(Json(TimelinePage {
        tweets: page.tweets,
        cursor: page.next_cursor,
    }))
}

#[derive(Debug, Deserialize, Default)]
pub struct BookmarkQuery {
    #[serde(default)]
    pub q: Option<String>,
    #[serde(default)]
    pub cursor: Option<String>,
    #[serde(default)]
    pub count: Option<u32>,
}

/// With a non-empty `q`, searches bookmarks (`BookmarkSearchTimeline`);
/// without one, serves the full Bookmarks timeline.
pub async fn bookmarks(
    State(state): State<Arc<AppState>>,
    Query(q): Query<BookmarkQuery>,
) -> std::result::Result<Json<TimelinePage>, ApiError> {
    let count = q.count.unwrap_or(DEFAULT_COUNT);
    let query = q.q.as_deref().map(str::trim).filter(|s| !s.is_empty());
    let (response, path) = match query {
        Some(search) => (
            state
                .gql
                .get(
                    Operation::BookmarkSearchTimeline,
                    &endpoints::bookmark_search_variables(search, count, q.cursor.as_deref()),
                    &endpoints::bookmark_search_features(),
                )
                .await?,
            "/data/search_by_raw_query/bookmarks_search_timeline/timeline/instructions",
        ),
        None => (
            state
                .gql
                .get(
                    Operation::Bookmarks,
                    &endpoints::bookmarks_timeline_variables(count, q.cursor.as_deref()),
                    &endpoints::bookmarks_timeline_features(),
                )
                .await?,
            "/data/bookmark_timeline_v2/timeline/instructions",
        ),
    };
    let instructions = timeline::extract_instructions(&response, path)?;
    let page = timeline::walk(instructions);
    Ok(Json(TimelinePage {
        tweets: page.tweets,
        cursor: page.next_cursor,
    }))
}

pub async fn notifications(
    State(state): State<Arc<AppState>>,
    Query(q): Query<PageQuery>,
) -> std::result::Result<Json<unrager_model::NotificationsPage>, ApiError> {
    let page = whisper::fetch_notifications(&state.gql, q.cursor.as_deref()).await?;
    let notifications: Vec<unrager_model::Notification> = page
        .notifications
        .into_iter()
        .map(|n| unrager_model::Notification {
            id: n.id,
            kind: n.notification_type,
            actors: n
                .actors
                .into_iter()
                .map(|u| unrager_model::NotificationActor {
                    handle: u.handle,
                    name: u.name,
                    rest_id: u.rest_id,
                    verified: u.verified,
                    avatar_url: u.avatar_url,
                })
                .collect(),
            target_tweet_id: n.target_tweet_id,
            target_tweet_snippet: n.target_tweet_snippet,
            target_tweet_like_count: n.target_tweet_like_count,
            target_media: n.target_media,
            others_count: n.others_count,
            message: n.message,
            timestamp: n.timestamp,
        })
        .collect();
    Ok(Json(unrager_model::NotificationsPage {
        notifications,
        cursor: page.next_cursor,
    }))
}
