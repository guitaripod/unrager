use crate::server::state::AppState;
use axum::Json;
use axum::extract::State;
use serde_json::json;
use std::sync::Arc;

pub async fn health(State(state): State<Arc<AppState>>) -> Json<serde_json::Value> {
    Json(json!({
        "ok": true,
        "name": "unrager",
        "version": env!("CARGO_PKG_VERSION"),
        "filter_only": state.filter_only,
        "build": build_info(),
    }))
}

fn build_info() -> serde_json::Value {
    json!({
        "features": {
            "tui": cfg!(feature = "tui"),
            "server": cfg!(feature = "server"),
        },
        "profile": if cfg!(debug_assertions) { "debug" } else { "release" },
    })
}
