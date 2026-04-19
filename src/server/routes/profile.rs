use crate::gql::endpoints;
use crate::gql::query_ids::Operation;
use crate::parse::timeline;
use crate::parse::user as parse_user;
use crate::server::error::ApiError;
use crate::server::state::AppState;
use crate::tui::focus;
use axum::Json;
use axum::extract::{Path, Query, State};
use serde::Deserialize;
use std::sync::Arc;
use unrager_model::ProfileView;

#[derive(Debug, Deserialize, Default)]
pub struct ProfileQuery {
    #[serde(default)]
    pub include_replies: bool,
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
    let user_response = state
        .gql
        .get(
            Operation::UserByScreenName,
            &endpoints::user_by_screen_name_variables(screen),
            &endpoints::user_by_screen_name_features(),
        )
        .await?;
    let user_node = user_response
        .pointer("/data/user/result")
        .or_else(|| user_response.pointer("/data/user_v2/result"))
        .ok_or_else(|| ApiError::bad_request("user not found"))?;
    let user = parse_user::parse_user_result(user_node)
        .ok_or_else(|| ApiError::bad_request("user response shape unexpected"))?;

    let op = if q.include_replies {
        Operation::UserTweetsAndReplies
    } else {
        Operation::UserTweets
    };
    let tweets_response = state
        .gql
        .get(
            op,
            &endpoints::user_tweets_variables(&user.rest_id, 40, None),
            &endpoints::user_tweets_features(),
        )
        .await?;
    let instructions = timeline::extract_instructions_multi(
        &tweets_response,
        &[
            "/data/user/result/timeline/timeline/instructions",
            "/data/user/result/timeline_v2/timeline/instructions",
        ],
    )?;
    let page = timeline::walk(instructions);

    Ok(Json(ProfileView {
        user,
        pinned: None,
        recent: page.tweets,
        cursor: page.next_cursor,
    }))
}

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
    let page = focus::fetch_likers(&state.gql, &tweet_id, q.cursor.as_deref()).await?;
    Ok(Json(serde_json::json!({
        "users": page.users,
        "cursor": page.next_cursor,
    })))
}
