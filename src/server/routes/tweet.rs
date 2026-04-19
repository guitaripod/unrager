use crate::gql::endpoints;
use crate::gql::query_ids::Operation;
use crate::parse::timeline;
use crate::parse::tweet as parse_tweet;
use crate::server::error::ApiError;
use crate::server::state::AppState;
use axum::Json;
use axum::extract::{Path, Query, State};
use serde::Deserialize;
use std::sync::Arc;
use unrager_model::{ThreadView, Tweet};

pub async fn single(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> std::result::Result<Json<Tweet>, ApiError> {
    let response = state
        .gql
        .get(
            Operation::TweetResultByRestId,
            &endpoints::tweet_by_rest_id_variables(&id),
            &endpoints::tweet_read_features(),
        )
        .await?;
    let tweet = parse_tweet::parse_tweet_result_by_rest_id(&response)?;
    Ok(Json(tweet))
}

#[derive(Debug, Deserialize, Default)]
pub struct ThreadQuery {
    #[serde(default)]
    pub cursor: Option<String>,
}

pub async fn thread(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Query(q): Query<ThreadQuery>,
) -> std::result::Result<Json<ThreadView>, ApiError> {
    let response = state
        .gql
        .get(
            Operation::TweetDetail,
            &endpoints::tweet_detail_variables(&id, q.cursor.as_deref()),
            &endpoints::tweet_read_features(),
        )
        .await?;
    let instructions = timeline::extract_instructions(
        &response,
        "/data/threaded_conversation_with_injections_v2/instructions",
    )?;
    let page = timeline::walk(instructions);

    let mut focal: Option<Tweet> = None;
    let mut ancestors: Vec<Tweet> = Vec::new();
    let mut replies: Vec<Tweet> = Vec::new();

    for t in page.tweets.into_iter() {
        if t.rest_id == id {
            focal = Some(t);
        } else if focal.is_none() {
            ancestors.push(t);
        } else {
            replies.push(t);
        }
    }

    let focal = focal.ok_or_else(|| ApiError::not_found("focal tweet not in thread"))?;

    Ok(Json(ThreadView {
        focal,
        ancestors,
        replies,
        cursor: page.next_cursor,
    }))
}
