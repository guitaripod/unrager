use crate::error::Error;
use crate::gql::endpoints;
use crate::gql::query_ids::Operation;
use crate::parse::timeline;
use crate::server::error::ApiError;
use crate::server::state::AppState;
use axum::Json;
use axum::extract::{Path, Query, State};
use serde::Deserialize;
use serde_json::{Value, json};
use std::sync::{Arc, PoisonError};
use unrager_model::TimelinePage;

const QUOTES_COUNT: u32 = 20;

/// X's code for a post that doesn't exist (any more).
const NO_SUCH_POST: i64 = 144;

/// `DELETE /api/tweets/{tweet_id}`: deletes one of the user's own posts and
/// forgets it here, so neither the Home buffer nor a follow-up request hands
/// it out again. A post that is already gone counts as deleted.
pub async fn delete(
    State(state): State<Arc<AppState>>,
    Path(tweet_id): Path<String>,
) -> std::result::Result<Json<Value>, ApiError> {
    let id = post_id(&tweet_id)?;
    let idempotent = match state
        .gql
        .post(
            Operation::DeleteTweet,
            &endpoints::delete_tweet_variables(id),
            &endpoints::mutation_features(),
        )
        .await
    {
        Ok(_) => false,
        Err(e) if x_error_code(&e) == Some(NO_SUCH_POST) => true,
        Err(e) => return Err(e.into()),
    };
    forget(&state, id).await;
    tracing::info!(post = %id, idempotent, "post deleted");
    Ok(Json(json!({ "ok": true, "idempotent": idempotent })))
}

async fn forget(state: &AppState, id: &str) {
    state
        .recent_tweets
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .pop(id);
    if let Err(e) = state.feed.lock().await.remove(id) {
        tracing::warn!(post = %id, "deleted post left in feed.db: {e}");
    }
}

#[derive(Debug, Deserialize, Default)]
pub struct QuotesQuery {
    #[serde(default)]
    pub cursor: Option<String>,
}

/// `GET /api/tweets/{tweet_id}/quotes`: the posts quoting one, newest first,
/// as X's own quotes view finds them (a Latest search for
/// `quoted_tweet_id:`).
pub async fn quotes(
    State(state): State<Arc<AppState>>,
    Path(tweet_id): Path<String>,
    Query(q): Query<QuotesQuery>,
) -> std::result::Result<Json<TimelinePage>, ApiError> {
    let id = post_id(&tweet_id)?;
    let cursor = q.cursor.as_deref().filter(|c| !c.is_empty());
    let response = state
        .gql
        .post(
            Operation::SearchTimeline,
            &endpoints::search_timeline_variables(
                &format!("quoted_tweet_id:{id}"),
                QUOTES_COUNT,
                "Latest",
                cursor,
            ),
            &endpoints::search_timeline_features(),
        )
        .await?;
    let instructions = timeline::extract_instructions(
        &response,
        "/data/search_by_raw_query/search_timeline/timeline/instructions",
    )?;
    let mut page = timeline::walk(instructions);
    state.hydrate_quotes(&mut page.tweets).await;
    state.remember(&page.tweets);
    Ok(Json(TimelinePage {
        tweets: page.tweets,
        cursor: page.next_cursor,
        pinned: None,
    }))
}

/// A path id that is a post's numeric id, or a 400.
fn post_id(raw: &str) -> std::result::Result<&str, ApiError> {
    numeric_id(raw).ok_or_else(|| ApiError::bad_request("not a post id"))
}

/// `raw` trimmed, when it is all ASCII digits.
pub(super) fn numeric_id(raw: &str) -> Option<&str> {
    let id = raw.trim();
    (!id.is_empty() && id.bytes().all(|b| b.is_ascii_digit())).then_some(id)
}

/// The numeric code X gave an error: from the typed error, or from an error
/// body carried as text.
pub(super) fn x_error_code(e: &Error) -> Option<i64> {
    if let Error::GraphqlApi {
        code: Some(code), ..
    } = e
    {
        return Some(*code);
    }
    let text = e.to_string();
    let after = text.split("\"code\":").nth(1)?;
    let digits: String = after
        .trim_start()
        .chars()
        .take_while(char::is_ascii_digit)
        .collect();
    digits.parse().ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_numeric_ids_pass() {
        assert_eq!(numeric_id("123"), Some("123"));
        assert_eq!(numeric_id(" 123 "), Some("123"));
        for bad in ["", "  ", "12a", "@bob", "-1", "1.5", "１２"] {
            assert_eq!(numeric_id(bad), None, "{bad:?}");
        }
        let err = post_id("abc").unwrap_err();
        assert_eq!((err.status.as_u16(), err.kind), (400, "bad_request"));
    }

    #[test]
    fn x_error_codes_are_read_from_typed_and_text_errors() {
        let typed = Error::GraphqlApi {
            status: Some(404),
            code: Some(144),
            message: "No status found with that ID.".into(),
        };
        assert_eq!(x_error_code(&typed), Some(144));
        let text = Error::GraphqlStatus {
            status: 404,
            body: r#"{"errors":[{"code": 144,"message":"No status found"}]}"#.into(),
        };
        assert_eq!(x_error_code(&text), Some(144));
        let other = Error::GraphqlStatus {
            status: 500,
            body: "oops".into(),
        };
        assert_eq!(x_error_code(&other), None);
        let uncoded = Error::GraphqlApi {
            status: None,
            code: None,
            message: "x".into(),
        };
        assert_eq!(x_error_code(&uncoded), None);
    }
}
