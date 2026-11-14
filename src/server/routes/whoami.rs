use crate::gql::endpoints;
use crate::gql::query_ids::Operation;
use crate::parse::viewer;
use crate::server::error::ApiError;
use crate::server::state::AppState;
use axum::Json;
use axum::extract::State;
use serde_json::json;
use std::sync::Arc;
use std::time::Duration;

/// How long the signed-in account X named is trusted before X is asked
/// again; a new login (another `twid`) asks at once.
const WHOAMI_TTL: Duration = Duration::from_secs(10 * 60);

/// `GET /api/whoami`: the account the server reads X as. Every client asks
/// as it starts (the browser extension on every x.com page), so the answer
/// is kept for a while rather than spend a paced request to X each time.
pub async fn whoami(
    State(state): State<Arc<AppState>>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let me = state.gql.self_user_id();
    if let Some(cached) = state.cached_whoami(me.as_deref(), WHOAMI_TTL) {
        return Ok(Json(cached));
    }
    let response = state
        .gql
        .get(
            Operation::Viewer,
            &endpoints::viewer_variables(),
            &endpoints::viewer_features(),
        )
        .await?;
    let viewer = viewer::parse(&response)?;
    let answer = json!({
        "handle": viewer.handle,
        "rest_id": viewer.user_id,
        "name": viewer.name,
    });
    state.remember_whoami(answer.clone());
    Ok(Json(answer))
}
