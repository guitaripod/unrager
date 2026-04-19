use crate::gql::endpoints;
use crate::gql::query_ids::Operation;
use crate::parse::viewer;
use crate::server::error::ApiError;
use crate::server::state::AppState;
use axum::Json;
use axum::extract::State;
use serde_json::json;
use std::sync::Arc;

pub async fn whoami(
    State(state): State<Arc<AppState>>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let response = state
        .gql
        .get(
            Operation::Viewer,
            &endpoints::viewer_variables(),
            &endpoints::viewer_features(),
        )
        .await?;
    let viewer = viewer::parse(&response)?;
    Ok(Json(json!({
        "handle": viewer.handle,
        "rest_id": viewer.user_id,
        "name": viewer.name,
    })))
}
