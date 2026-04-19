use crate::cli::common;
use crate::gql::endpoints;
use crate::gql::query_ids::Operation;
use crate::parse::timeline;
use crate::server::error::ApiError;
use crate::server::state::AppState;
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
    let count = q.count.unwrap_or(DEFAULT_COUNT);
    let op = if q.following {
        Operation::HomeLatestTimeline
    } else {
        Operation::HomeTimeline
    };
    let response = state
        .gql
        .post(
            op,
            &endpoints::home_timeline_variables(count, q.cursor.as_deref()),
            &endpoints::home_timeline_features(),
        )
        .await?;
    let instructions =
        timeline::extract_instructions(&response, "/data/home/home_timeline_urt/instructions")?;
    let page = timeline::walk(instructions);
    let tweets = if q.mode.as_deref() == Some("originals") {
        filter_originals(page.tweets)
    } else {
        page.tweets
    };
    Ok(Json(TimelinePage {
        tweets,
        cursor: page.next_cursor,
    }))
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

pub async fn user(
    State(state): State<Arc<AppState>>,
    Path(handle): Path<String>,
    Query(q): Query<PageQuery>,
) -> std::result::Result<Json<TimelinePage>, ApiError> {
    let screen = handle.trim_start_matches('@');
    if screen.is_empty() {
        return Err(ApiError::bad_request("empty handle"));
    }
    let count = q.count.unwrap_or(DEFAULT_COUNT);
    let user_id = source::resolve_user_id(&state.gql, screen).await?;
    let response = state
        .gql
        .get(
            Operation::UserTweets,
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

#[derive(Debug, Deserialize)]
pub struct BookmarkQuery {
    pub q: String,
    #[serde(default)]
    pub cursor: Option<String>,
    #[serde(default)]
    pub count: Option<u32>,
}

pub async fn bookmarks(
    State(state): State<Arc<AppState>>,
    Query(q): Query<BookmarkQuery>,
) -> std::result::Result<Json<TimelinePage>, ApiError> {
    if q.q.trim().is_empty() {
        return Err(ApiError::bad_request(
            "bookmarks requires a non-empty q parameter",
        ));
    }
    let count = q.count.unwrap_or(DEFAULT_COUNT);
    let response = state
        .gql
        .get(
            Operation::BookmarkSearchTimeline,
            &endpoints::bookmark_search_variables(&q.q, count, q.cursor.as_deref()),
            &endpoints::bookmark_search_features(),
        )
        .await?;
    let instructions = timeline::extract_instructions(
        &response,
        "/data/search_by_raw_query/bookmarks_search_timeline/timeline/instructions",
    )?;
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
                })
                .collect(),
            target_tweet_id: n.target_tweet_id,
            target_tweet_snippet: n.target_tweet_snippet,
            target_tweet_like_count: n.target_tweet_like_count,
            timestamp: n.timestamp,
        })
        .collect();
    Ok(Json(unrager_model::NotificationsPage {
        notifications,
        cursor: page.next_cursor,
    }))
}
