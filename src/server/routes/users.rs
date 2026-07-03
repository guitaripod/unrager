use crate::gql::endpoints;
use crate::gql::query_ids::Operation;
use crate::parse::user as parse_user;
use crate::server::error::ApiError;
use crate::server::state::AppState;
use crate::tui::source;
use axum::Json;
use axum::extract::{Path, Query, State};
use serde::Deserialize;
use serde_json::{Value, json};
use std::sync::Arc;
use std::sync::atomic::Ordering;
use unrager_model::UserListPage;

const USER_LIST_COUNT: u32 = 50;

pub async fn follow(
    State(state): State<Arc<AppState>>,
    Path(user_id): Path<String>,
) -> std::result::Result<Json<serde_json::Value>, ApiError> {
    friendship_mutation(&state, &user_id, "/i/api/1.1/friendships/create.json").await
}

pub async fn unfollow(
    State(state): State<Arc<AppState>>,
    Path(user_id): Path<String>,
) -> std::result::Result<Json<serde_json::Value>, ApiError> {
    friendship_mutation(&state, &user_id, "/i/api/1.1/friendships/destroy.json").await
}

/// X's follow/unfollow are legacy 1.1 REST endpoints, not GraphQL. Both are
/// idempotent server-side: following an already-followed account (and the
/// reverse) returns the user object with a 200.
async fn friendship_mutation(
    state: &Arc<AppState>,
    user_id: &str,
    path: &str,
) -> std::result::Result<Json<serde_json::Value>, ApiError> {
    let rest_id = resolve_rest_id(state, user_id).await?;
    let response = state
        .gql
        .post_form_1_1(path, &[("user_id", rest_id.as_str())])
        .await?;
    let following = response
        .get("following")
        .and_then(Value::as_bool)
        .unwrap_or(path.ends_with("create.json"));
    Ok(Json(json!({ "ok": true, "following": following })))
}

#[derive(Debug, Deserialize, Default)]
pub struct UserListQuery {
    #[serde(default)]
    pub cursor: Option<String>,
    #[serde(default)]
    pub count: Option<u32>,
}

/// X removed the full `Followers` list op from its GraphQL API in 2025 (it
/// 404s with every query id while `Following` works), so this tries it once
/// and falls back to `BlueVerifiedFollowers` — the verified-followers list
/// x.com itself still serves. The dead op is remembered per-process so later
/// requests skip straight to the fallback; if X ever restores `Followers`, a
/// server restart picks it back up.
pub async fn followers(
    State(state): State<Arc<AppState>>,
    Path(user_id): Path<String>,
    Query(q): Query<UserListQuery>,
) -> std::result::Result<Json<UserListPage>, ApiError> {
    if !state.followers_op_dead.load(Ordering::Relaxed) {
        match user_list(&state, Operation::Followers, &user_id, &q).await {
            Err(e) if is_gone_upstream(&e) => {
                tracing::warn!("Followers op rejected upstream; using BlueVerifiedFollowers");
                state.followers_op_dead.store(true, Ordering::Relaxed);
            }
            other => return other,
        }
    }
    user_list(&state, Operation::BlueVerifiedFollowers, &user_id, &q).await
}

fn is_gone_upstream(e: &ApiError) -> bool {
    e.message.contains("status 404") || e.message.contains("status 400")
}

pub async fn following(
    State(state): State<Arc<AppState>>,
    Path(user_id): Path<String>,
    Query(q): Query<UserListQuery>,
) -> std::result::Result<Json<UserListPage>, ApiError> {
    user_list(&state, Operation::Following, &user_id, &q).await
}

async fn user_list(
    state: &Arc<AppState>,
    op: Operation,
    user_id: &str,
    q: &UserListQuery,
) -> std::result::Result<Json<UserListPage>, ApiError> {
    let rest_id = resolve_rest_id(state, user_id).await?;
    let count = q.count.unwrap_or(USER_LIST_COUNT);
    let response = state
        .gql
        .get(
            op,
            &endpoints::user_list_variables(&rest_id, count, q.cursor.as_deref()),
            &endpoints::user_list_features(),
        )
        .await?;
    let instructions = response
        .pointer("/data/user/result/timeline/timeline/instructions")
        .and_then(Value::as_array)
        .ok_or_else(|| {
            ApiError::internal(format!("{}: missing timeline instructions", op.name()))
        })?;
    let page = parse_user::parse_user_list_instructions(instructions);
    Ok(Json(UserListPage {
        users: page.users,
        cursor: page.next_cursor,
    }))
}

/// The path segment is normally a numeric rest_id; a handle (with or without
/// a leading `@`) is also accepted and resolved for convenience.
async fn resolve_rest_id(
    state: &Arc<AppState>,
    user_id: &str,
) -> std::result::Result<String, ApiError> {
    let trimmed = user_id.trim().trim_start_matches('@');
    if trimmed.is_empty() {
        return Err(ApiError::bad_request("empty user id"));
    }
    if trimmed.chars().all(|c| c.is_ascii_digit()) {
        return Ok(trimmed.to_string());
    }
    Ok(source::resolve_user_id(&state.gql, trimmed).await?)
}
