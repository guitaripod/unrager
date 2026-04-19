use crate::gql::endpoints;
use crate::gql::query_ids::Operation;
use crate::server::error::ApiError;
use crate::server::state::AppState;
use axum::Json;
use axum::extract::{Path, State};
use serde_json::json;
use std::sync::Arc;

pub async fn like(
    State(state): State<Arc<AppState>>,
    Path(tweet_id): Path<String>,
) -> std::result::Result<Json<serde_json::Value>, ApiError> {
    match state
        .gql
        .post(
            Operation::FavoriteTweet,
            &endpoints::favorite_variables(&tweet_id),
            &endpoints::mutation_features(),
        )
        .await
    {
        Ok(_) => Ok(Json(json!({ "ok": true }))),
        Err(e) if already_engaged(&e) => Ok(Json(json!({ "ok": true, "idempotent": true }))),
        Err(e) => Err(e.into()),
    }
}

pub async fn unlike(
    State(state): State<Arc<AppState>>,
    Path(tweet_id): Path<String>,
) -> std::result::Result<Json<serde_json::Value>, ApiError> {
    match state
        .gql
        .post(
            Operation::UnfavoriteTweet,
            &endpoints::favorite_variables(&tweet_id),
            &endpoints::mutation_features(),
        )
        .await
    {
        Ok(_) => Ok(Json(json!({ "ok": true }))),
        Err(e) if already_engaged(&e) => Ok(Json(json!({ "ok": true, "idempotent": true }))),
        Err(e) => Err(e.into()),
    }
}

fn already_engaged(e: &crate::error::Error) -> bool {
    let msg = e.to_string();
    msg.contains("\"code\":139") || msg.contains("\"code\":327")
}
