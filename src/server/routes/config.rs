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

/// Apply a rubric edit everywhere it matters, atomically from the client's
/// point of view: persist `filter.toml`, re-key the shared `FilterCache` to
/// the new rubric hash (old-rubric verdicts stop being served and new ones
/// are persisted under the right key), rebuild the classifier's system
/// prompt in place (the ingest worker's handle shares it), and wake the
/// ingest worker so it resets the stale `feed.db` verdicts immediately.
pub async fn patch_filter(
    State(state): State<Arc<AppState>>,
    Json(patch): Json<FilterPatch>,
) -> std::result::Result<Json<serde_json::Value>, ApiError> {
    let mut cfg = state.filter_config.lock().await;
    let mut updated = cfg.clone();
    if let Some(topics) = patch.drop_topics {
        updated.drop_topics = topics;
    }
    if let Some(guidance) = patch.extra_guidance {
        updated.extra_guidance = guidance;
    }
    let serialized =
        toml::to_string_pretty(&updated).map_err(|e| ApiError::internal(e.to_string()))?;
    let toml_path = state.filter_toml_path.clone();
    tokio::task::spawn_blocking(move || std::fs::write(&toml_path, serialized))
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .map_err(ApiError::from)?;
    state
        .filter_cache
        .lock()
        .await
        .rekey(updated.rubric_hash())
        .map_err(|e| ApiError::internal(e.to_string()))?;
    state.classifier.lock().await.set_rubric(&updated);
    *cfg = updated;
    state.activity.touch();
    Ok(Json(serde_json::json!({
        "drop_topics": cfg.drop_topics,
        "extra_guidance": cfg.extra_guidance,
    })))
}
