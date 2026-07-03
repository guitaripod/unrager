use crate::server::error::ApiError;
use crate::server::state::AppState;
use axum::Json;
use axum::extract::{Path, Query, State};
use serde::Deserialize;
use std::sync::Arc;
use unrager_model::{AboutProfile, AboutView};

#[derive(Debug, Deserialize)]
pub struct AboutQuery {
    pub screen_name: String,
}

/// Country/flag lookup for one user. Answers from the shared `about.db`
/// cache when possible; otherwise single-flights an upstream
/// `AboutAccountQuery` inline. Rate-limited or failed fetches return a
/// `deferred` view that is never cached, so clients can retry later.
pub async fn about(
    State(state): State<Arc<AppState>>,
    Path(rest_id): Path<String>,
    Query(q): Query<AboutQuery>,
) -> std::result::Result<Json<AboutView>, ApiError> {
    if rest_id.trim().is_empty() {
        return Err(ApiError::bad_request("empty rest_id"));
    }
    let screen_name = q.screen_name.trim().trim_start_matches('@');
    if screen_name.is_empty() {
        return Err(ApiError::bad_request("empty screen_name"));
    }
    let view = match state
        .about_fetcher
        .resolve(&state.about, &rest_id, screen_name)
        .await
    {
        Ok(profile) => view_for(profile),
        Err(()) => AboutView::deferred(),
    };
    Ok(Json(view))
}

fn view_for(profile: Option<AboutProfile>) -> AboutView {
    let Some(profile) = profile else {
        return AboutView::none();
    };
    let country = profile.account_based_in.as_deref();
    let alpha2 = country
        .and_then(crate::flag::alpha2_for)
        .map(str::to_string);
    let flag = country.and_then(crate::flag::emoji_for);
    AboutView::resolved(profile, alpha2, flag)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use unrager_model::AboutStatus;

    fn profile(country: Option<&str>) -> AboutProfile {
        AboutProfile {
            rest_id: "42".into(),
            handle: "someone".into(),
            name: "Someone".into(),
            account_based_in: country.map(str::to_string),
            location_accurate: Some(true),
            source: Some("Web".into()),
            username_changes: None,
            affiliate_username: None,
            created_at: None,
            is_blue_verified: false,
            verified: false,
            verified_since: None,
        }
    }

    #[test]
    fn resolved_profile_derives_alpha2_and_flag() {
        let view = view_for(Some(profile(Some("United States"))));
        assert_eq!(view.status, AboutStatus::Resolved);
        assert_eq!(view.alpha2.as_deref(), Some("US"));
        assert_eq!(view.flag.as_deref(), Some("🇺🇸"));
        assert_eq!(
            view.profile.unwrap().account_based_in.as_deref(),
            Some("United States")
        );
    }

    #[test]
    fn resolved_profile_without_country_has_null_alpha2_and_flag() {
        let view = view_for(Some(profile(None)));
        assert_eq!(view.status, AboutStatus::Resolved);
        assert!(view.profile.is_some());
        assert!(view.alpha2.is_none());
        assert!(view.flag.is_none());
    }

    #[test]
    fn resolved_profile_with_unmappable_country_has_null_alpha2_and_flag() {
        let view = view_for(Some(profile(Some("Mordor"))));
        assert_eq!(view.status, AboutStatus::Resolved);
        assert!(view.alpha2.is_none());
        assert!(view.flag.is_none());
    }

    #[test]
    fn cached_negative_maps_to_none_status() {
        let view = view_for(None);
        assert_eq!(view, AboutView::none());
    }

    #[test]
    fn wire_json_for_resolved_matches_contract() {
        let view = view_for(Some(profile(Some("Japan"))));
        let v = serde_json::to_value(&view).unwrap();
        assert_eq!(v["status"], "resolved");
        assert_eq!(v["alpha2"], "JP");
        assert_eq!(v["flag"], "🇯🇵");
        assert_eq!(v["profile"]["rest_id"], "42");
        assert_eq!(v["profile"]["handle"], "someone");
        assert_eq!(v["profile"]["account_based_in"], "Japan");
    }

    #[test]
    fn wire_json_for_none_and_deferred_matches_contract() {
        assert_eq!(
            serde_json::to_value(view_for(None)).unwrap(),
            json!({"status": "none"})
        );
        assert_eq!(
            serde_json::to_value(AboutView::deferred()).unwrap(),
            json!({"status": "deferred"})
        );
    }
}
