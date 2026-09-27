use crate::server::error::ApiError;
use crate::server::state::AppState;
use crate::tui::filter::{ClassifierHandle, FilterCache, FilterDecision};
use axum::Json;
use axum::extract::State;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::Mutex;
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
    /// Answer from the verdict cache alone and leave out every tweet it
    /// hasn't judged, so the caller can act on those at once instead of
    /// waiting on the model, which may be a minute into loading.
    #[serde(default)]
    pub cached_only: bool,
}

#[derive(Debug, Serialize)]
pub struct ClassifyResponse {
    pub verdicts: Vec<FilterVerdictEvent>,
}

/// `POST /api/classify` — batch tweet classification for callers that
/// already have full tweet text, not just an id (the browser extension: it
/// walks X's own GraphQL responses and has the text right there, so sending
/// it directly skips a redundant GraphQL refetch through `llm::fetch_tweet`).
/// Reuses the exact same `FilterCache`/rate-limited `ClassifierHandle` the
/// TUI and background ingest worker share, so a verdict computed here is
/// visible everywhere else and vice versa. A tweet the backend failed to
/// classify is left out of `verdicts` entirely, so the caller keeps it
/// visible and can ask again later.
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

    let verdicts = judge(
        &state.filter_cache,
        &state.classifier_handle,
        &req.tweets,
        req.cached_only,
    )
    .await;
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

/// The cached verdicts for `tweets`, then, unless `cached_only`, the model's
/// for the rest, cached under the rubric they were asked under. A tweet the
/// model didn't answer for is left out.
async fn judge(
    cache: &Mutex<FilterCache>,
    handle: &ClassifierHandle,
    tweets: &[ClassifyItem],
    cached_only: bool,
) -> Vec<(String, FilterDecision)> {
    let mut verdicts: Vec<(String, FilterDecision)> = Vec::with_capacity(tweets.len());
    let mut misses: Vec<&ClassifyItem> = Vec::new();
    let rubric_snapshot = {
        let cache = cache.lock().await;
        for item in tweets {
            match cache.get(&item.id) {
                Some(d) => verdicts.push((item.id.clone(), d)),
                None => misses.push(item),
            }
        }
        cache.rubric_hash().to_string()
    };
    if cached_only || misses.is_empty() {
        return verdicts;
    }

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
        let batch: Vec<(&str, FilterDecision)> =
            computed.iter().map(|(id, d)| (id.as_str(), *d)).collect();
        cache
            .lock()
            .await
            .put_many_if_current_rubric(&rubric_snapshot, &batch);
    }
    verdicts.extend(computed);
    verdicts
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ModelState {
    Ready,
    ModelMissing,
    Unreachable,
}

#[derive(Debug, Serialize)]
pub struct FilterStatus {
    pub backend: &'static str,
    pub model: String,
    pub host: String,
    pub state: ModelState,
}

/// `GET /api/filter/status` — the model the filter actually runs on (after
/// any Ollama fallback) and whether its server answers right now, so the
/// extension can tell "unrager is down" apart from "your model is down".
/// A models listing, never a generation: it has to stay fast even while the
/// model itself is cold.
pub async fn status(State(state): State<Arc<AppState>>) -> Json<FilterStatus> {
    let llm = state.classifier_handle.llm();
    let model_state = match llm.list_models_within(Duration::from_secs(2)).await {
        Err(_) => ModelState::Unreachable,
        Ok(models) if llm.is_served_by(&models) => ModelState::Ready,
        Ok(_) => ModelState::ModelMissing,
    };
    Json(FilterStatus {
        backend: llm.backend.as_str(),
        model: llm.model.clone(),
        host: llm.host.clone(),
        state: model_state,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tui::filter::{Classifier, FilterConfig, LlmBackend};

    /// A model server that accepts connections and never answers, so a test
    /// that reaches it hangs instead of passing by accident.
    async fn silent_model() -> ClassifierHandle {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            let mut held = Vec::new();
            while let Ok((socket, _)) = listener.accept().await {
                held.push(socket);
            }
        });
        let mut cfg: FilterConfig = toml::from_str(FilterConfig::default_content()).unwrap();
        cfg.llm.backend = LlmBackend::OpenAi;
        cfg.llm.host = format!("http://{addr}");
        cfg.llm.model = "stub".into();
        Classifier::new(&cfg).handle()
    }

    fn item(id: &str) -> ClassifyItem {
        ClassifyItem {
            id: id.into(),
            text: format!("post {id}"),
        }
    }

    #[tokio::test]
    async fn cached_only_answers_at_once_without_asking_the_model() {
        let dir = tempfile::TempDir::new().unwrap();
        let cache =
            Mutex::new(FilterCache::open(&dir.path().join("filter.db"), "rubric".into()).unwrap());
        cache.lock().await.put("judged", FilterDecision::Hide);
        let handle = silent_model().await;
        let tweets = [item("judged"), item("new")];

        let verdicts = tokio::time::timeout(
            Duration::from_secs(1),
            judge(&cache, &handle, &tweets, true),
        )
        .await
        .expect("a cache-only answer never waits on the model");

        assert_eq!(verdicts, vec![("judged".to_string(), FilterDecision::Hide)]);
    }
}
