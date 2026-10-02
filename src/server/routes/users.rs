use crate::gql::endpoints;
use crate::gql::query_ids::Operation;
use crate::parse::user as parse_user;
use crate::server::error::ApiError;
use crate::server::state::AppState;
use axum::Json;
use axum::extract::{Path, Query, State};
use serde::Deserialize;
use serde_json::{Value, json};
use std::sync::{Arc, PoisonError};
use std::time::{Duration, Instant};
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

/// How long the full `Followers` op is skipped after X answered 404 for it,
/// before it's tried again in case X restored it.
const FOLLOWERS_RETRY_AFTER: Duration = Duration::from_secs(60 * 60);

/// X removed the full `Followers` list op from its GraphQL API in 2025 (it
/// 404s with every query id while `Following` works), so this tries it and
/// falls back to `BlueVerifiedFollowers` — the verified-followers list
/// x.com itself still serves. Only a 404 on a first page counts as the op
/// being gone (a 400 is as likely a stale cursor), and only for
/// [`FOLLOWERS_RETRY_AFTER`].
pub async fn followers(
    State(state): State<Arc<AppState>>,
    Path(user_id): Path<String>,
    Query(q): Query<UserListQuery>,
) -> std::result::Result<Json<UserListPage>, ApiError> {
    let first_page = q.cursor.is_none();
    let dead_since = *state
        .followers_op_dead_since
        .lock()
        .unwrap_or_else(PoisonError::into_inner);
    if use_full_followers(dead_since.map(|since| since.elapsed()), first_page) {
        match user_list(&state, Operation::Followers, &user_id, &q).await {
            Err(e) if first_page && is_gone_upstream(&e) => {
                tracing::warn!("Followers op answered 404; using BlueVerifiedFollowers");
                *state
                    .followers_op_dead_since
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner) = Some(Instant::now());
            }
            Ok(page) => {
                if dead_since.is_some() {
                    tracing::info!("Followers op answers again");
                    *state
                        .followers_op_dead_since
                        .lock()
                        .unwrap_or_else(PoisonError::into_inner) = None;
                }
                return Ok(page);
            }
            Err(e) => return Err(e),
        }
    }
    let mut page = user_list(&state, Operation::BlueVerifiedFollowers, &user_id, &q).await?;
    page.0.verified_only = true;
    Ok(page)
}

/// Whether a followers page asks the full `Followers` op. A continuation
/// page follows the list its first page came from, which is the verified
/// one once `Followers` was found gone; a first page tries `Followers` again
/// once [`FOLLOWERS_RETRY_AFTER`] has passed.
fn use_full_followers(dead_for: Option<Duration>, first_page: bool) -> bool {
    match dead_for {
        None => true,
        Some(elapsed) => first_page && elapsed >= FOLLOWERS_RETRY_AFTER,
    }
}

fn is_gone_upstream(e: &ApiError) -> bool {
    e.kind == "upstream" && (e.message.contains("status 404") || e.message.contains("[http 404]"))
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
    let count = super::timeline::page_count(q.count, USER_LIST_COUNT);
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
        verified_only: false,
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
    Ok(state.user_id(trimmed).await?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::Error;

    #[test]
    fn followers_is_tried_until_found_gone_then_again_after_a_while() {
        assert!(use_full_followers(None, true));
        assert!(use_full_followers(None, false));
        let just_now = Some(Duration::from_secs(5));
        assert!(!use_full_followers(just_now, true));
        assert!(!use_full_followers(just_now, false));
        let long_ago = Some(FOLLOWERS_RETRY_AFTER);
        assert!(use_full_followers(long_ago, true));
        assert!(
            !use_full_followers(long_ago, false),
            "a verified list's next page stays on the verified list"
        );
    }

    #[test]
    fn only_a_404_means_the_op_is_gone() {
        let status = |status| {
            ApiError::from(Error::GraphqlStatus {
                status,
                body: String::new(),
            })
        };
        assert!(is_gone_upstream(&status(404)));
        assert!(!is_gone_upstream(&status(400)));
        assert!(is_gone_upstream(&ApiError::from(Error::GraphqlApi {
            status: Some(404),
            code: None,
            message: "Not found".into(),
        })));
        assert!(!is_gone_upstream(&ApiError::from(Error::RateLimited {
            remaining_secs: 60
        })));
    }
}
