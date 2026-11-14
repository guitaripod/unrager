use crate::gql::endpoints;
use crate::gql::query_ids::Operation;
use crate::parse::timeline;
use crate::server::error::ApiError;
use crate::server::state::AppState;
use crate::tui::focus::Engagers;
use axum::Json;
use axum::extract::{Path, Query, State};
use serde::Deserialize;
use std::sync::Arc;
use unrager_model::ProfileView;

#[derive(Debug, Deserialize)]
pub struct ProfileQuery {
    #[serde(default)]
    pub include_replies: bool,
    /// `false` returns just the header (`recent: []`, no pinned post), for a
    /// client that loads the profile's posts from `/api/sources/user` itself.
    #[serde(default = "with_tweets")]
    pub tweets: bool,
}

impl Default for ProfileQuery {
    fn default() -> Self {
        Self {
            include_replies: false,
            tweets: with_tweets(),
        }
    }
}

fn with_tweets() -> bool {
    true
}

pub async fn profile(
    State(state): State<Arc<AppState>>,
    Path(handle): Path<String>,
    Query(q): Query<ProfileQuery>,
) -> std::result::Result<Json<ProfileView>, ApiError> {
    let screen = handle.trim_start_matches('@');
    if screen.is_empty() {
        return Err(ApiError::bad_request("empty handle"));
    }
    let user = state.user(screen).await?;

    let mut page = if q.tweets {
        recent_posts(&state, &user.rest_id, q.include_replies)
            .await
            .unwrap_or_else(|e| {
                tracing::warn!(handle = %screen, "profile posts failed, sending the header alone: {e}");
                timeline::TimelinePage::default()
            })
    } else {
        timeline::TimelinePage::default()
    };
    tokio::join!(
        state.hydrate_quotes(page.pinned.as_mut().map_or(&mut [], std::slice::from_mut)),
        state.hydrate_quotes(&mut page.tweets),
    );
    state.remember(page.pinned.iter().chain(&page.tweets));

    Ok(Json(ProfileView {
        user,
        pinned: page.pinned,
        recent: page.tweets,
        cursor: page.next_cursor,
    }))
}

/// The first page of a profile's posts, with its pinned post apart.
async fn recent_posts(
    state: &AppState,
    user_id: &str,
    include_replies: bool,
) -> crate::error::Result<timeline::TimelinePage> {
    let op = if include_replies {
        Operation::UserTweetsAndReplies
    } else {
        Operation::UserTweets
    };
    let response = state
        .gql
        .get(
            op,
            &endpoints::user_tweets_variables(user_id, 40, None),
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
    Ok(timeline::walk(instructions))
}

const LIKERS_COUNT: u32 = 50;

#[derive(Debug, Deserialize, Default)]
pub struct LikersQuery {
    #[serde(default)]
    pub cursor: Option<String>,
    #[serde(default)]
    pub count: Option<u32>,
}

pub async fn likers(
    State(state): State<Arc<AppState>>,
    Path(tweet_id): Path<String>,
    Query(q): Query<LikersQuery>,
) -> std::result::Result<Json<serde_json::Value>, ApiError> {
    let count = super::timeline::page_count(q.count, LIKERS_COUNT);
    let cursor = q.cursor.as_deref().filter(|c| !c.is_empty());
    let page = super::insights::engagers(&state, Engagers::Likes, &tweet_id, count, cursor).await?;
    Ok(Json(serde_json::json!({
        "users": page.users,
        "cursor": page.cursor,
    })))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn query(raw: &str) -> ProfileQuery {
        let uri: axum::http::Uri = format!("/api/profile/a?{raw}").parse().unwrap();
        Query::<ProfileQuery>::try_from_uri(&uri).unwrap().0
    }

    #[test]
    fn profile_posts_are_on_unless_turned_off() {
        assert!(query("").tweets);
        assert!(query("include_replies=true").tweets);
        assert!(!query("tweets=false").tweets);
        assert!(ProfileQuery::default().tweets);
    }
}
