use crate::server::error::ApiError;
use crate::server::state::AppState;
use axum::Json;
use axum::extract::State;
use serde::Deserialize;
use std::sync::Arc;

pub async fn get_filter(
    State(state): State<Arc<AppState>>,
) -> std::result::Result<Json<serde_json::Value>, ApiError> {
    let cfg = state.filter_config.lock().await;
    Ok(Json(serde_json::json!({
        "drop_topics": cfg.drop_topics,
        "extra_guidance": cfg.extra_guidance,
        "ollama": {
            "model": cfg.ollama.model,
            "host": cfg.ollama.host,
        },
    })))
}

#[derive(Debug, Deserialize)]
pub struct FilterPatch {
    #[serde(default)]
    pub drop_topics: Option<Vec<String>>,
    #[serde(default)]
    pub extra_guidance: Option<String>,
}

pub async fn patch_filter(
    State(state): State<Arc<AppState>>,
    Json(patch): Json<FilterPatch>,
) -> std::result::Result<Json<serde_json::Value>, ApiError> {
    let mut cfg = state.filter_config.lock().await;
    if let Some(topics) = patch.drop_topics {
        cfg.drop_topics = topics;
    }
    if let Some(guidance) = patch.extra_guidance {
        cfg.extra_guidance = guidance;
    }
    let serialized =
        toml::to_string_pretty(&*cfg).map_err(|e| ApiError::internal(e.to_string()))?;
    std::fs::write(&state.filter_toml_path, serialized).map_err(ApiError::from)?;
    Ok(Json(serde_json::json!({
        "drop_topics": cfg.drop_topics,
        "extra_guidance": cfg.extra_guidance,
    })))
}
