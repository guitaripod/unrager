use crate::server::error::ApiError;
use crate::server::state::AppState;
use axum::Json;
use axum::extract::State;
use serde::Deserialize;
use std::sync::Arc;
use unrager_model::{FlagsResponse, UserFlag};

/// Accounts one request may ask about.
const MAX_USERS: usize = 200;

#[derive(Debug, Deserialize)]
pub struct FlagsRequest {
    pub users: Vec<FlagUser>,
}

#[derive(Debug, Deserialize)]
pub struct FlagUser {
    pub rest_id: String,
    pub handle: String,
}

/// `POST /api/flags`: where each of a list of accounts says it's based, as
/// a flag, for lists of people (who liked a post, who reposted it). Answers
/// from `about.db`, then the community cache when it's on (lookups made
/// together go out as one request), and never asks X: its about lookups
/// come 50 to a quarter hour, fewer than one list holds. An account whose
/// country isn't known is left out.
pub async fn flags(
    State(state): State<Arc<AppState>>,
    Json(req): Json<FlagsRequest>,
) -> std::result::Result<Json<FlagsResponse>, ApiError> {
    if req.users.len() > MAX_USERS {
        return Err(ApiError::bad_request(format!(
            "at most {MAX_USERS} accounts at a time"
        )));
    }
    let lookups = req.users.iter().filter(|u| is_id(&u.rest_id)).map(|u| {
        let state = &state;
        async move {
            let handle = u.handle.trim().trim_start_matches('@');
            let profile = state
                .about_fetcher
                .resolve_known(&state.about, &u.rest_id, handle)
                .await;
            (u.rest_id.clone(), profile)
        }
    });
    let mut answer = FlagsResponse::default();
    for (rest_id, profile) in futures::future::join_all(lookups).await {
        if let Some(flag) = profile
            .and_then(|p| p.account_based_in)
            .map(|c| flag_for(&c))
        {
            answer.flags.insert(rest_id, flag);
        }
    }
    Ok(Json(answer))
}

fn is_id(raw: &str) -> bool {
    !raw.is_empty() && raw.bytes().all(|b| b.is_ascii_digit())
}

fn flag_for(country: &str) -> UserFlag {
    UserFlag {
        country: country.to_string(),
        alpha2: crate::flag::alpha2_for(country).map(str::to_string),
        flag: crate::flag::emoji_for(country),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_country_becomes_its_code_and_flag() {
        let flag = flag_for("Finland");
        assert_eq!(flag.alpha2.as_deref(), Some("FI"));
        assert_eq!(flag.flag.as_deref(), Some("🇫🇮"));
        let unknown = flag_for("Atlantis");
        assert_eq!(unknown.country, "Atlantis");
        assert_eq!(unknown.alpha2, None);
        assert!(is_id("123") && !is_id("12a") && !is_id(""));
    }
}
