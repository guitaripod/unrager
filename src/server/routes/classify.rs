use crate::server::error::ApiError;
use crate::server::state::AppState;
use crate::tui::filter::FilterDecision;
use axum::Json;
use axum::extract::State;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use unrager_model::{FilterVerdictEvent, Verdict};

const MAX_BATCH: usize = 100;

#[derive(Debug, Deserialize)]
pub struct ClassifyItem {
    pub id: String,
    pub text: String,
}

#[derive(Debug, Deserialize)]
pub struct ClassifyRequest {
    pub tweets: Vec<ClassifyItem>,
}

#[derive(Debug, Serialize)]
pub struct ClassifyResponse {
    pub verdicts: Vec<FilterVerdictEvent>,
}

/// `POST /api/classify` — batch tweet classification for callers that
/// already have full tweet text, not just an id (the browser userscript
/// companion: it walks X's own GraphQL responses and has the text right
/// there, so sending it directly skips a redundant GraphQL refetch through
/// `llm::fetch_tweet`). Reuses the exact same `FilterCache`/rate-limited
/// `ClassifierHandle` the TUI and background ingest worker share, so a
/// verdict computed here is visible everywhere else and vice versa. A tweet
/// the backend failed to classify is left out of `verdicts` entirely, so the
/// caller keeps it visible and can ask again later.
pub async fn classify(
    State(state): State<Arc<AppState>>,
    Json(req): Json<ClassifyRequest>,
) -> std::result::Result<Json<ClassifyResponse>, ApiError> {
    if req.tweets.is_empty() {
        return Err(ApiError::bad_request("tweets must not be empty"));
    }
    if req.tweets.len() > MAX_BATCH {
        return Err(ApiError::bad_request(format!(
            "batch too large (max {MAX_BATCH})"
        )));
    }

    let mut verdicts: Vec<(String, FilterDecision)> = Vec::with_capacity(req.tweets.len());
    let mut misses: Vec<&ClassifyItem> = Vec::new();
    let rubric_snapshot = {
        let cache = state.filter_cache.lock().await;
        for item in &req.tweets {
            match cache.get(&item.id) {
                Some(d) => verdicts.push((item.id.clone(), d)),
                None => misses.push(item),
            }
        }
        cache.rubric_hash().to_string()
    };

    let handle = state.classifier_handle.clone();
    let computed = futures::future::join_all(misses.iter().map(|item| {
        let handle = handle.clone();
        async move { (item.id.clone(), handle.classify(&item.id, &item.text).await) }
    }))
    .await;

    let computed: Vec<(String, FilterDecision)> = computed
        .into_iter()
        .filter_map(|(id, decision)| decision.map(|d| (id, d)))
        .collect();
    if !computed.is_empty() {
        let mut cache = state.filter_cache.lock().await;
        for (id, decision) in &computed {
            cache.put_if_current_rubric(&rubric_snapshot, id, *decision);
        }
    }
    verdicts.extend(computed);

    Ok(Json(ClassifyResponse {
        verdicts: verdicts
            .into_iter()
            .map(|(id, d)| FilterVerdictEvent {
                id,
                verdict: match d {
                    FilterDecision::Hide => Verdict::Hide,
                    FilterDecision::Keep => Verdict::Keep,
                },
            })
            .collect(),
    }))
}
