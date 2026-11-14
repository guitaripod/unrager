use crate::gql::query_ids::Operation;
use crate::server::error::ApiError;
use crate::server::state::AppState;
use crate::tui::focus::{self, Engagers};
use axum::Json;
use axum::extract::{Path, Query, State};
use serde::Deserialize;
use std::future::Future;
use std::sync::Arc;
use std::time::Duration;
use unrager_model::{InsightPart, PostAnalytics, PostInsights, UserListPage};

/// How many of the newest likers and reposters a glance brings: the faces on
/// a post and the top of its lists, which page on from there.
const GLANCE_COUNT: u32 = 20;
const ENGAGERS_COUNT: u32 = 50;

#[derive(Debug, Deserialize, Default)]
pub struct InsightsQuery {
    /// Comma-separated parts (`analytics`, `likers`, `reposters`); all of
    /// them when absent.
    #[serde(default)]
    pub parts: Option<String>,
    #[serde(default)]
    pub count: Option<u32>,
}

#[derive(Debug, Deserialize, Default)]
pub struct EngagersQuery {
    #[serde(default)]
    pub cursor: Option<String>,
    #[serde(default)]
    pub count: Option<u32>,
}

/// What became of one part of a glance.
#[derive(Debug)]
enum Outcome<T> {
    Got(T),
    /// Held back for this long, to leave X's budget alone.
    Deferred(Duration),
    Failed(ApiError),
}

/// `GET /api/tweets/{tweet_id}/insights`: X's analytics for one of the
/// signed-in account's posts and the newest people who liked and reposted
/// it, asked of X together. The browser extension asks as the user's posts
/// scroll by, so a part whose budget is down to its reserve is held back
/// (`deferred`) rather than leave the apps without; only when every part
/// asked for failed is the answer an error.
pub async fn insights(
    State(state): State<Arc<AppState>>,
    Path(tweet_id): Path<String>,
    Query(q): Query<InsightsQuery>,
) -> std::result::Result<Json<PostInsights>, ApiError> {
    let id = super::posts::numeric_id(&tweet_id)
        .ok_or_else(|| ApiError::bad_request("not a post id"))?;
    let parts = requested_parts(q.parts.as_deref())?;
    let count = super::timeline::page_count(q.count, GLANCE_COUNT);
    let wants = |part| parts.contains(&part);
    let (analytics, likers, reposters) = tokio::join!(
        glance(
            &state,
            wants(InsightPart::Analytics),
            Operation::TweetActivityQuery,
            || super::tweet::fetch_analytics(&state, id),
        ),
        glance(
            &state,
            wants(InsightPart::Likers),
            Operation::Favoriters,
            || engagers(&state, Engagers::Likes, id, count, None),
        ),
        glance(
            &state,
            wants(InsightPart::Reposters),
            Operation::Retweeters,
            || engagers(&state, Engagers::Reposts, id, count, None),
        ),
    );
    let answer = assemble(analytics, likers, reposters)?;
    tracing::debug!(
        post = %id,
        deferred = ?answer.deferred,
        failed = ?answer.failed,
        "post insights"
    );
    Ok(Json(answer))
}

/// `GET /api/tweets/{tweet_id}/reposters`: who reposted a post, newest
/// first, a page at a time.
pub async fn reposters(
    State(state): State<Arc<AppState>>,
    Path(tweet_id): Path<String>,
    Query(q): Query<EngagersQuery>,
) -> std::result::Result<Json<UserListPage>, ApiError> {
    let id = super::posts::numeric_id(&tweet_id)
        .ok_or_else(|| ApiError::bad_request("not a post id"))?;
    let count = super::timeline::page_count(q.count, ENGAGERS_COUNT);
    let cursor = q.cursor.as_deref().filter(|c| !c.is_empty());
    engagers(&state, Engagers::Reposts, id, count, cursor)
        .await
        .map(Json)
}

/// One page of who liked or reposted a post, as the apps' user lists carry it.
pub(super) async fn engagers(
    state: &AppState,
    kind: Engagers,
    id: &str,
    count: u32,
    cursor: Option<&str>,
) -> std::result::Result<UserListPage, ApiError> {
    let page = focus::fetch_engagers(&state.gql, kind, id, count, cursor).await?;
    Ok(UserListPage {
        users: page.users,
        cursor: page.next_cursor,
        verified_only: false,
    })
}

/// The parts a request names, in the order given and without repeats; every
/// part when it names none (`?parts=` and `?parts=,` alike).
fn requested_parts(raw: Option<&str>) -> std::result::Result<Vec<InsightPart>, ApiError> {
    let mut parts = Vec::new();
    let names = raw.unwrap_or_default().split(',').map(str::trim);
    for name in names.filter(|n| !n.is_empty()) {
        let part = match name {
            "analytics" => InsightPart::Analytics,
            "likers" => InsightPart::Likers,
            "reposters" => InsightPart::Reposters,
            other => return Err(ApiError::bad_request(format!("unknown part {other:?}"))),
        };
        if !parts.contains(&part) {
            parts.push(part);
        }
    }
    if parts.is_empty() {
        parts = vec![
            InsightPart::Analytics,
            InsightPart::Likers,
            InsightPart::Reposters,
        ];
    }
    Ok(parts)
}

/// Asks X for one part of a glance, unless it wasn't asked for (`None`) or
/// its budget should be left alone for now.
async fn glance<T, F, Fut>(
    state: &AppState,
    wanted: bool,
    op: Operation,
    fetch: F,
) -> Option<Outcome<T>>
where
    F: FnOnce() -> Fut,
    Fut: Future<Output = std::result::Result<T, ApiError>>,
{
    if !wanted {
        return None;
    }
    if let Some(wait) = state.gql.spare_budget_wait(op) {
        tracing::debug!(
            op = op.name(),
            wait_secs = wait.as_secs(),
            "glance held back"
        );
        return Some(Outcome::Deferred(wait));
    }
    Some(match fetch().await {
        Ok(value) => Outcome::Got(value),
        Err(e) if e.kind == "rate_limited" => {
            Outcome::Deferred(Duration::from_secs(e.retry_after_secs.unwrap_or(60)))
        }
        Err(e) => {
            tracing::info!(
                op = op.name(),
                kind = e.kind,
                "glance failed: {}",
                e.message
            );
            Outcome::Failed(e)
        }
    })
}

/// Puts the parts' outcomes together. When every part asked for failed, the
/// first failure is the answer, so a signed-out or offline server says so
/// rather than answering with nothing.
fn assemble(
    analytics: Option<Outcome<Option<PostAnalytics>>>,
    likers: Option<Outcome<UserListPage>>,
    reposters: Option<Outcome<UserListPage>>,
) -> std::result::Result<PostInsights, ApiError> {
    let mut answer = PostInsights::default();
    let outcomes = [
        (
            InsightPart::Analytics,
            analytics.map(|o| take(o, &mut answer.analytics, |a| a)),
        ),
        (
            InsightPart::Likers,
            likers.map(|o| take(o, &mut answer.likers, Some)),
        ),
        (
            InsightPart::Reposters,
            reposters.map(|o| take(o, &mut answer.reposters, Some)),
        ),
    ];
    let mut asked = 0;
    let mut waits = Vec::new();
    let mut failures = Vec::new();
    for (part, outcome) in outcomes {
        let Some(outcome) = outcome else { continue };
        asked += 1;
        match outcome {
            Outcome::Got(()) => {}
            Outcome::Deferred(wait) => {
                answer.deferred.push(part);
                waits.push(wait);
            }
            Outcome::Failed(e) => {
                answer.failed.push(part);
                failures.push(e);
            }
        }
    }
    if asked > 0 && failures.len() == asked {
        return Err(failures.remove(0));
    }
    answer.retry_after_secs = waits.iter().min().map(|w| w.as_secs().max(1));
    Ok(answer)
}

/// Moves a fetched part into its slot of the answer, leaving what became of
/// it.
fn take<T, S>(
    outcome: Outcome<T>,
    slot: &mut Option<S>,
    fill: impl FnOnce(T) -> Option<S>,
) -> Outcome<()> {
    match outcome {
        Outcome::Got(value) => {
            *slot = fill(value);
            Outcome::Got(())
        }
        Outcome::Deferred(wait) => Outcome::Deferred(wait),
        Outcome::Failed(e) => Outcome::Failed(e),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::http::StatusCode;

    fn page(cursor: &str) -> UserListPage {
        UserListPage {
            users: Vec::new(),
            cursor: Some(cursor.into()),
            verified_only: false,
        }
    }

    fn auth() -> ApiError {
        ApiError::new(StatusCode::UNAUTHORIZED, "auth", "signed out")
    }

    #[test]
    fn parts_default_to_all_and_drop_repeats() {
        use InsightPart::*;
        assert_eq!(
            requested_parts(None).unwrap(),
            [Analytics, Likers, Reposters]
        );
        assert_eq!(
            requested_parts(Some(" ")).unwrap(),
            [Analytics, Likers, Reposters]
        );
        assert_eq!(
            requested_parts(Some(",")).unwrap(),
            [Analytics, Likers, Reposters]
        );
        assert_eq!(
            requested_parts(Some("likers, analytics,likers")).unwrap(),
            [Likers, Analytics]
        );
        assert_eq!(
            requested_parts(Some("views")).unwrap_err().kind,
            "bad_request"
        );
    }

    #[test]
    fn fetched_parts_fill_in_and_absent_analytics_is_not_a_failure() {
        let answer = assemble(
            Some(Outcome::Got(None)),
            Some(Outcome::Got(page("l"))),
            None,
        )
        .unwrap();
        assert_eq!(answer.analytics, None);
        assert_eq!(answer.likers, Some(page("l")));
        assert_eq!(answer.reposters, None);
        assert!(answer.deferred.is_empty() && answer.failed.is_empty());
        assert_eq!(answer.retry_after_secs, None);
    }

    #[test]
    fn held_back_parts_say_when_to_ask_again() {
        let answer = assemble(
            Some(Outcome::Got(Some(PostAnalytics::default()))),
            Some(Outcome::Deferred(Duration::from_secs(300))),
            Some(Outcome::Deferred(Duration::from_millis(400))),
        )
        .unwrap();
        assert_eq!(
            answer.deferred,
            [InsightPart::Likers, InsightPart::Reposters]
        );
        assert_eq!(answer.retry_after_secs, Some(1));
        assert!(answer.analytics.is_some());
    }

    #[test]
    fn one_failure_among_answers_is_reported_and_all_failing_is_an_error() {
        let answer = assemble(
            Some(Outcome::Failed(auth())),
            Some(Outcome::Got(page("l"))),
            None,
        )
        .unwrap();
        assert_eq!(answer.failed, [InsightPart::Analytics]);
        assert_eq!(answer.likers, Some(page("l")));

        let error = assemble(
            Some(Outcome::Failed(auth())),
            Some(Outcome::Failed(ApiError::internal("x"))),
            None,
        )
        .unwrap_err();
        assert_eq!(error.kind, "auth");
    }

    #[test]
    fn everything_held_back_is_still_an_answer() {
        let answer =
            assemble(Some(Outcome::Deferred(Duration::from_secs(90))), None, None).unwrap();
        assert_eq!(answer.deferred, [InsightPart::Analytics]);
        assert_eq!(answer.retry_after_secs, Some(90));
    }
}
