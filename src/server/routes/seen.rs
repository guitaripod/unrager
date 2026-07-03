use crate::server::error::ApiError;
use crate::server::state::AppState;
use axum::Json;
use axum::extract::{Path, State};
use serde::Deserialize;
use serde_json::json;
use std::sync::Arc;

pub async fn list(
    State(_state): State<Arc<AppState>>,
) -> std::result::Result<Json<serde_json::Value>, ApiError> {
    Ok(Json(
        json!({ "note": "full seen list not exposed; use /api/seen/{id} to check" }),
    ))
}

#[derive(Debug, Deserialize)]
pub struct MarkBody {
    #[serde(default)]
    pub ids: Vec<String>,
}

pub async fn mark(
    State(state): State<Arc<AppState>>,
    Json(body): Json<MarkBody>,
) -> std::result::Result<Json<serde_json::Value>, ApiError> {
    let mut store = state.seen.lock().await;
    let count = body.ids.len();
    store.mark_all(body.ids);
    Ok(Json(json!({ "marked": count })))
}

pub async fn clear(
    State(_state): State<Arc<AppState>>,
) -> std::result::Result<Json<serde_json::Value>, ApiError> {
    Ok(Json(
        json!({ "ok": false, "note": "clear not supported; seen entries auto-expire after 30 days" }),
    ))
}

pub async fn check(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> std::result::Result<Json<serde_json::Value>, ApiError> {
    let store = state.seen.lock().await;
    Ok(Json(
        json!({ "id": id.clone(), "seen": store.is_seen(&id) }),
    ))
}

pub async fn notifications_seen_get(
    State(state): State<Arc<AppState>>,
) -> std::result::Result<Json<unrager_model::NotificationsSeenMarker>, ApiError> {
    let store = state.seen.lock().await;
    Ok(Json(unrager_model::NotificationsSeenMarker {
        marker: store.notifications_marker(),
    }))
}

pub async fn notifications_seen_put(
    State(state): State<Arc<AppState>>,
    Json(body): Json<unrager_model::NotificationsSeenMarker>,
) -> std::result::Result<Json<unrager_model::NotificationsSeenMarker>, ApiError> {
    let marker = body
        .marker
        .as_deref()
        .map(str::trim)
        .filter(|m| !m.is_empty())
        .ok_or_else(|| ApiError::bad_request("marker required"))?;
    let mut store = state.seen.lock().await;
    store.set_notifications_marker(marker);
    Ok(Json(unrager_model::NotificationsSeenMarker {
        marker: store.notifications_marker(),
    }))
}
