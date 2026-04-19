use crate::server::error::ApiError;
use crate::server::state::{AppState, save_session_state};
use axum::Json;
use axum::extract::State;
use std::sync::Arc;
use unrager_model::SessionState;

pub async fn get(
    State(state): State<Arc<AppState>>,
) -> std::result::Result<Json<SessionState>, ApiError> {
    let s = state.session.lock().await.clone();
    Ok(Json(s))
}

pub async fn patch(
    State(state): State<Arc<AppState>>,
    Json(patch): Json<serde_json::Value>,
) -> std::result::Result<Json<SessionState>, ApiError> {
    let mut s = state.session.lock().await;
    let mut val = serde_json::to_value(&*s).map_err(ApiError::from)?;
    merge(&mut val, patch);
    *s = serde_json::from_value(val).map_err(ApiError::from)?;
    let _ = save_session_state(&state.session_path, &s);
    Ok(Json(s.clone()))
}

fn merge(dst: &mut serde_json::Value, src: serde_json::Value) {
    use serde_json::Value;
    match (dst, src) {
        (Value::Object(d), Value::Object(s)) => {
            for (k, v) in s {
                merge(d.entry(k).or_insert(Value::Null), v);
            }
        }
        (d, s) => *d = s,
    }
}
