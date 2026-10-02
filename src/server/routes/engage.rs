use crate::gql::endpoints;
use crate::gql::query_ids::Operation;
use crate::server::error::ApiError;
use crate::server::routes::posts::x_error_code;
use crate::server::state::AppState;
use axum::Json;
use axum::extract::{Path, State};
use serde_json::json;
use std::sync::Arc;

pub async fn like(
    State(state): State<Arc<AppState>>,
    Path(tweet_id): Path<String>,
) -> std::result::Result<Json<serde_json::Value>, ApiError> {
    engage_mutation(
        &state,
        Operation::FavoriteTweet,
        endpoints::favorite_variables(&tweet_id),
    )
    .await
}

pub async fn unlike(
    State(state): State<Arc<AppState>>,
    Path(tweet_id): Path<String>,
) -> std::result::Result<Json<serde_json::Value>, ApiError> {
    engage_mutation(
        &state,
        Operation::UnfavoriteTweet,
        endpoints::favorite_variables(&tweet_id),
    )
    .await
}

pub async fn retweet(
    State(state): State<Arc<AppState>>,
    Path(tweet_id): Path<String>,
) -> std::result::Result<Json<serde_json::Value>, ApiError> {
    engage_mutation(
        &state,
        Operation::CreateRetweet,
        endpoints::create_retweet_variables(&tweet_id),
    )
    .await
}

pub async fn unretweet(
    State(state): State<Arc<AppState>>,
    Path(tweet_id): Path<String>,
) -> std::result::Result<Json<serde_json::Value>, ApiError> {
    engage_mutation(
        &state,
        Operation::DeleteRetweet,
        endpoints::delete_retweet_variables(&tweet_id),
    )
    .await
}

pub async fn bookmark(
    State(state): State<Arc<AppState>>,
    Path(tweet_id): Path<String>,
) -> std::result::Result<Json<serde_json::Value>, ApiError> {
    engage_mutation(
        &state,
        Operation::CreateBookmark,
        endpoints::bookmark_variables(&tweet_id),
    )
    .await
}

pub async fn unbookmark(
    State(state): State<Arc<AppState>>,
    Path(tweet_id): Path<String>,
) -> std::result::Result<Json<serde_json::Value>, ApiError> {
    engage_mutation(
        &state,
        Operation::DeleteBookmark,
        endpoints::bookmark_variables(&tweet_id),
    )
    .await
}

async fn engage_mutation(
    state: &Arc<AppState>,
    op: Operation,
    variables: serde_json::Value,
) -> std::result::Result<Json<serde_json::Value>, ApiError> {
    match state
        .gql
        .post(op, &variables, &endpoints::mutation_features())
        .await
    {
        Ok(_) => Ok(Json(json!({ "ok": true }))),
        Err(e) if already_engaged(op, &e) => Ok(Json(json!({ "ok": true, "idempotent": true }))),
        Err(e) => Err(e.into()),
    }
}

fn is_undo_op(op: Operation) -> bool {
    matches!(
        op,
        Operation::UnfavoriteTweet | Operation::DeleteRetweet | Operation::DeleteBookmark
    )
}

/// X's "you already did that" / "already undone" responses that map to an
/// idempotent OK because the requested end state already holds. Code 139
/// (already favorited) and 327 (already retweeted) and the bookmark dup
/// messages are create-side. Code 144 ("not found in actor's favorites" /
/// "No status found with that ID") only means "already gone" for an UNDO —
/// on a create op it is a genuine error (the tweet was deleted), so it must
/// not be swallowed there.
fn already_engaged(op: Operation, e: &crate::error::Error) -> bool {
    match x_error_code(e) {
        Some(144) => is_undo_op(op),
        Some(139 | 327) => true,
        _ => {
            let msg = e.to_string();
            msg.contains("Document already exists") || msg.contains("already bookmarked")
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::Error;

    fn typed(code: i64) -> Error {
        Error::GraphqlApi {
            status: None,
            code: Some(code),
            message: "nope".into(),
        }
    }

    #[test]
    fn repeating_a_like_or_repost_is_idempotent() {
        assert!(already_engaged(Operation::FavoriteTweet, &typed(139)));
        assert!(already_engaged(Operation::CreateRetweet, &typed(327)));
        let raw = Error::GraphqlStatus {
            status: 403,
            body: r#"{"errors":[{"code":139,"message":"already favorited"}]}"#.into(),
        };
        assert!(already_engaged(Operation::FavoriteTweet, &raw));
    }

    #[test]
    fn undoing_what_is_already_gone_is_idempotent_only_for_undo() {
        assert!(already_engaged(Operation::UnfavoriteTweet, &typed(144)));
        assert!(already_engaged(Operation::DeleteRetweet, &typed(144)));
        assert!(!already_engaged(Operation::FavoriteTweet, &typed(144)));
    }

    #[test]
    fn a_repeated_bookmark_is_idempotent() {
        let dup = Error::GraphqlApi {
            status: None,
            code: None,
            message: "Document already exists".into(),
        };
        assert!(already_engaged(Operation::CreateBookmark, &dup));
        assert!(!already_engaged(Operation::FavoriteTweet, &typed(226)));
    }
}
