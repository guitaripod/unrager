use crate::server::state::AppState;
use crate::store::feed::{FeedVariant, now_secs};
use axum::Json;
use axum::extract::State;
use std::sync::Arc;
use unrager_model::{FeedStatus, FeedStatusResponse};

/// Freshness of the materialized Home buffer, so clients can render
/// "updated Nm ago" and know how stale what they're seeing is. Reads the
/// `feed_meta` rows the ingest worker stamps each cycle; `age_secs == -1`
/// means that variant has never been ingested (cold buffer).
pub async fn status(State(state): State<Arc<AppState>>) -> Json<FeedStatusResponse> {
    let now = now_secs();
    let store = state.feed.lock().await;
    let feeds = [FeedVariant::ForYou, FeedVariant::Following]
        .into_iter()
        .map(|variant| {
            let (last_ingest_at, last_ingest_count) = store
                .meta(variant)
                .map(|m| (m.last_poll_at, m.last_ingest_count))
                .unwrap_or((0, 0));
            FeedStatus {
                variant: variant.as_source().to_string(),
                last_ingest_at,
                last_ingest_count,
                age_secs: if last_ingest_at > 0 {
                    (now - last_ingest_at).max(0)
                } else {
                    -1
                },
            }
        })
        .collect();
    Json(FeedStatusResponse { feeds })
}
