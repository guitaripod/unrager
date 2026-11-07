use crate::server::state::AppState;
use axum::Json;
use axum::extract::State;
use std::sync::Arc;
use unrager_model::{RateBudget, RateLimitsResponse};

/// X's budget for every operation it has answered since the server started,
/// so a tool polling through the server can stop before it is the one that
/// runs a budget dry and freezes that operation for the apps.
pub async fn rate_limits(State(state): State<Arc<AppState>>) -> Json<RateLimitsResponse> {
    let budgets = state
        .gql
        .rate_windows()
        .into_iter()
        .map(|(op, window, cooldown)| RateBudget {
            operation: op.name().to_string(),
            limit: window.limit,
            remaining: window.remaining,
            reset_at: window.reset_at,
            cooldown_secs: cooldown.map_or(0, |d| d.as_secs().max(1)),
        })
        .collect();
    Json(RateLimitsResponse { budgets })
}
