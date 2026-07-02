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
    let tweet = fetch_tweet_by_rest_id(&state, &id).await?;
    Ok(Json(tweet))
}

async fn fetch_tweet_by_rest_id(
    state: &Arc<AppState>,
    id: &str,
) -> std::result::Result<Tweet, ApiError> {
    let response = state
        .gql
        .get(
            Operation::TweetResultByRestId,
            &endpoints::tweet_by_rest_id_variables(id),
            &endpoints::tweet_read_features(),
        )
        .await?;
    Ok(parse_tweet::parse_tweet_result_by_rest_id(&response)?)
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
    let continuation = q.cursor.is_some();
    let (focal, ancestors, replies) = split_thread(page.tweets, &id, continuation);

    if focal.is_none() && !continuation {
        return Err(ApiError::not_found("focal tweet not in thread"));
    }

    Ok(Json(ThreadView {
        focal,
        ancestors,
        replies,
        cursor: page.next_cursor,
    }))
}

/// Partition a TweetDetail page around the focal tweet. On the first page,
/// entries before the focal are ancestors and entries after it are replies.
/// A cursor continuation page carries only additional reply entries — X omits
/// the focal — so everything is a reply and `focal` stays `None`; the response
/// omits it rather than spending an extra upstream fetch on a tweet no client
/// reads on continuations (and whose deletion would otherwise dead-end
/// pagination).
fn split_thread(
    tweets: Vec<Tweet>,
    id: &str,
    continuation: bool,
) -> (Option<Tweet>, Vec<Tweet>, Vec<Tweet>) {
    let mut focal: Option<Tweet> = None;
    let mut ancestors: Vec<Tweet> = Vec::new();
    let mut replies: Vec<Tweet> = Vec::new();

    for t in tweets.into_iter() {
        if t.rest_id == id {
            focal = Some(t);
        } else if focal.is_none() && !continuation {
            ancestors.push(t);
        } else {
            replies.push(t);
        }
    }

    (focal, ancestors, replies)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tui::test_util::make_tweet;

    fn tweets(ids: &[&str]) -> Vec<Tweet> {
        ids.iter().map(|id| make_tweet(id, "text")).collect()
    }

    fn ids(v: &[Tweet]) -> Vec<&str> {
        v.iter().map(|t| t.rest_id.as_str()).collect()
    }

    #[test]
    fn first_page_splits_around_focal() {
        let (focal, ancestors, replies) = split_thread(tweets(&["1", "2", "3", "4"]), "2", false);
        assert_eq!(focal.map(|t| t.rest_id).as_deref(), Some("2"));
        assert_eq!(ids(&ancestors), ["1"]);
        assert_eq!(ids(&replies), ["3", "4"]);
    }

    #[test]
    fn first_page_without_focal_yields_none() {
        let (focal, ancestors, replies) = split_thread(tweets(&["1", "2"]), "9", false);
        assert!(focal.is_none());
        assert_eq!(ids(&ancestors), ["1", "2"]);
        assert!(replies.is_empty());
    }

    #[test]
    fn continuation_page_treats_all_tweets_as_replies() {
        let (focal, ancestors, replies) = split_thread(tweets(&["5", "6", "7"]), "9", true);
        assert!(focal.is_none());
        assert!(ancestors.is_empty());
        assert_eq!(ids(&replies), ["5", "6", "7"]);
    }

    #[test]
    fn continuation_page_containing_focal_still_splits_it_out() {
        let (focal, ancestors, replies) = split_thread(tweets(&["5", "9", "6"]), "9", true);
        assert_eq!(focal.map(|t| t.rest_id).as_deref(), Some("9"));
        assert!(ancestors.is_empty());
        assert_eq!(ids(&replies), ["5", "6"]);
    }

    #[test]
    fn thread_view_omits_focal_key_on_continuations() {
        let view = ThreadView {
            focal: None,
            ancestors: Vec::new(),
            replies: tweets(&["5", "6"]),
            cursor: Some("next".to_string()),
        };
        let json = serde_json::to_value(&view).unwrap();
        assert!(json.get("focal").is_none());
        assert_eq!(json["replies"].as_array().unwrap().len(), 2);
    }

    #[test]
    fn thread_view_serializes_focal_on_first_pages() {
        let view = ThreadView {
            focal: Some(make_tweet("2", "focal")),
            ancestors: tweets(&["1"]),
            replies: tweets(&["3"]),
            cursor: None,
        };
        let json = serde_json::to_value(&view).unwrap();
        assert_eq!(json["focal"]["rest_id"], "2");
    }

    #[test]
    fn thread_view_decodes_without_focal() {
        let view: ThreadView = serde_json::from_str(r#"{"replies":[],"cursor":"c"}"#).unwrap();
        assert!(view.focal.is_none());
        assert_eq!(view.cursor.as_deref(), Some("c"));
    }
}
