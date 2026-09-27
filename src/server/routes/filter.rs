use crate::server::error::ApiError;
use crate::server::state::AppState;
use crate::tui::filter::FilterDecision;
use axum::Json;
use axum::extract::State;
use axum::http::StatusCode;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use unrager_model::Verdict;

const MAX_OVERRIDE_IDS: usize = 20;

#[derive(Debug, Deserialize)]
pub struct OverrideRequest {
    pub ids: Vec<String>,
    /// `hide` or `keep`; `null` hands the posts back to the model.
    pub verdict: Option<Verdict>,
}

/// `POST /api/filter/overrides` — the user's own call on posts (the browser
/// extension's "Hide this post" and "Show this post"). It outranks the model
/// in every client and survives rule changes.
pub async fn set_overrides(
    State(state): State<Arc<AppState>>,
    Json(req): Json<OverrideRequest>,
) -> std::result::Result<StatusCode, ApiError> {
    if req.ids.is_empty() || req.ids.len() > MAX_OVERRIDE_IDS {
        return Err(ApiError::bad_request(format!(
            "send between 1 and {MAX_OVERRIDE_IDS} post ids"
        )));
    }
    if !req.ids.iter().all(|id| is_post_id(id)) {
        return Err(ApiError::bad_request("ids must be numeric post ids"));
    }
    let decision = req.verdict.map(|v| match v {
        Verdict::Hide => FilterDecision::Hide,
        Verdict::Keep => FilterDecision::Keep,
    });
    let ids: Vec<&str> = req.ids.iter().map(String::as_str).collect();
    state
        .filter_cache
        .lock()
        .await
        .set_override(&ids, decision)
        .map_err(|e| ApiError::internal(e.to_string()))?;
    tracing::info!(posts = ids.len(), verdict = ?decision, "filter override set");
    Ok(StatusCode::NO_CONTENT)
}

fn is_post_id(id: &str) -> bool {
    (1..=24).contains(&id.len()) && id.bytes().all(|b| b.is_ascii_digit())
}

#[derive(Debug, Serialize, PartialEq, Eq)]
pub struct RuleCount {
    /// A topic as the user wrote it, a built-in rule's name, or `null` for
    /// hidden posts whose rule the model didn't say.
    pub rule: Option<String>,
    pub hidden: u64,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
pub struct UserCounts {
    pub hidden: u64,
    pub shown: u64,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
pub struct FilterStatsResponse {
    pub checked: u64,
    pub hidden: u64,
    /// Unix seconds of the oldest verdict under the current rules.
    pub since: Option<i64>,
    pub rules: Vec<RuleCount>,
    /// Posts the user hid or showed themselves.
    pub you: UserCounts,
}

/// `GET /api/filter/stats` — how many posts the current rules checked and
/// hid, per rule, so the extension can show which rule does the hiding.
pub async fn stats(
    State(state): State<Arc<AppState>>,
) -> std::result::Result<Json<FilterStatsResponse>, ApiError> {
    let stats = state
        .filter_cache
        .lock()
        .await
        .stats()
        .map_err(|e| ApiError::internal(e.to_string()))?;
    Ok(Json(FilterStatsResponse {
        checked: stats.checked,
        hidden: stats.hidden,
        since: stats.since,
        rules: stats
            .hidden_by_reason
            .into_iter()
            .map(|(rule, hidden)| RuleCount { rule, hidden })
            .collect(),
        you: UserCounts {
            hidden: stats.hidden_by_user,
            shown: stats.shown_by_user,
        },
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_numeric_ids_count_as_posts() {
        assert!(is_post_id("1900000000000000001"));
        for id in ["", "12a", "../etc", &"1".repeat(25)] {
            assert!(!is_post_id(id), "{id}");
        }
    }
}
