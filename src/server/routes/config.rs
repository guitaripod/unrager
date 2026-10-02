use crate::server::error::ApiError;
use crate::server::state::AppState;
use crate::tui::filter::{FilterConfig, Strictness, built_in_rule_labels};
use axum::Json;
use axum::extract::State;
use serde::Deserialize;
use std::sync::Arc;

pub async fn get_filter(
    State(state): State<Arc<AppState>>,
) -> std::result::Result<Json<serde_json::Value>, ApiError> {
    let cfg = state.filter_config.lock().await;
    let filter_llm = cfg.llm.for_filter();
    Ok(Json(serde_json::json!({
        "drop_topics": cfg.drop_topics,
        "extra_guidance": cfg.extra_guidance,
        "strictness": cfg.strictness,
        "built_in_rules": built_in_rule_labels(),
        "ollama": {
            "backend": filter_llm.backend,
            "model": filter_llm.model,
            "host": filter_llm.host,
        },
    })))
}

#[derive(Debug, Deserialize)]
pub struct FilterPatch {
    #[serde(default)]
    pub drop_topics: Option<Vec<String>>,
    #[serde(default)]
    pub extra_guidance: Option<String>,
    #[serde(default)]
    pub strictness: Option<Strictness>,
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
    if let Some(strictness) = patch.strictness {
        updated.strictness = strictness;
    }
    let toml_path = state.filter_toml_path.clone();
    let rules = updated.clone();
    tokio::task::spawn_blocking(move || -> std::result::Result<(), ApiError> {
        let raw = std::fs::read_to_string(&toml_path).unwrap_or_default();
        std::fs::write(&toml_path, rules.write_rules_into(&raw)?)?;
        Ok(())
    })
    .await
    .map_err(|e| ApiError::internal(e.to_string()))??;
    state
        .filter_cache
        .lock()
        .await
        .rekey(updated.rubric_hash())
        .map_err(|e| ApiError::internal(e.to_string()))?;
    state.classifier.lock().await.set_rubric(&updated);
    *cfg = updated;
    state.activity.touch();
    Ok(Json(rules_view(&cfg)))
}

fn rules_view(cfg: &FilterConfig) -> serde_json::Value {
    serde_json::json!({
        "drop_topics": cfg.drop_topics,
        "extra_guidance": cfg.extra_guidance,
        "strictness": cfg.strictness,
    })
}
