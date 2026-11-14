use crate::gql::query_ids::Operation;
use crate::server::error::ApiError;
use crate::server::state::{AppState, Setback};
use crate::store::insights::{self as cache, Cached, Part};
use crate::tui::focus::{self, Engagers};
use axum::Json;
use axum::extract::{Path, Query, State};
use serde::Deserialize;
use serde_json::Value;
use std::future::Future;
use std::sync::{Arc, PoisonError};
use std::time::Duration;
use unrager_model::{InsightPart, InsightsBatch, PostInsights, TimelinePage, UserListPage};

/// How many of the newest likers and reposters a glance brings: the faces on
/// a post and the top of its lists, which page on from there.
const GLANCE_COUNT: u32 = 20;
const ENGAGERS_COUNT: u32 = 50;
/// Posts one batch may ask about.
const MAX_BATCH: usize = 60;
/// A part another request fetched this recently is taken as it is rather
/// than asked of X again.
const JUST_FETCHED_MS: i64 = 5_000;
/// After X fails a part, it's answered with that failure for this long
/// instead of asked again.
const FAILURE_PAUSE: Duration = Duration::from_secs(60);

#[derive(Debug, Deserialize, Default)]
pub struct InsightsQuery {
    /// Comma-separated parts (`analytics`, `likers`, `reposters`); all of
    /// them when absent.
    #[serde(default)]
    pub parts: Option<String>,
    #[serde(default)]
    pub count: Option<u32>,
    /// The post's like and repost counts as the client sees them, so likers
    /// or reposters cached at a lower count are fetched again.
    #[serde(default)]
    pub likes: Option<u64>,
    #[serde(default)]
    pub reposts: Option<u64>,
    /// Off: answer at once, with parts X hasn't answered yet in
    /// `refreshing`.
    #[serde(default)]
    pub wait: Option<bool>,
}

#[derive(Debug, Deserialize, Default)]
pub struct EngagersQuery {
    #[serde(default)]
    pub cursor: Option<String>,
    #[serde(default)]
    pub count: Option<u32>,
}

#[derive(Debug, Deserialize)]
pub struct BatchRequest {
    pub posts: Vec<BatchPost>,
    #[serde(default)]
    pub parts: Option<Vec<InsightPart>>,
    #[serde(default)]
    pub count: Option<u32>,
}

#[derive(Debug, Deserialize)]
pub struct BatchPost {
    pub id: String,
    #[serde(default)]
    pub likes: Option<u64>,
    #[serde(default)]
    pub reposts: Option<u64>,
}

/// The counts a client sees on a post.
#[derive(Debug, Clone, Copy, Default)]
struct Hints {
    likes: Option<u64>,
    reposts: Option<u64>,
}

/// What became of one part of a glance.
#[derive(Debug)]
enum Outcome<T> {
    Got(T),
    /// Held back for this long, to leave X's budget alone.
    Deferred(Duration),
    Failed(ApiError),
    /// Being asked of X behind the answer.
    Pending,
}

/// A part as answered: X's payload, when X gave it, and whether a newer one
/// is on its way.
#[derive(Debug, Clone, PartialEq)]
struct Answer {
    payload: Value,
    fetched_at_ms: i64,
    refreshing: bool,
}

/// `GET /api/tweets/{tweet_id}/insights`: X's analytics for one of the
/// signed-in account's posts and the newest people who liked and reposted
/// it. Each part comes from the server's cache (`insights.db`) while it's
/// fresh; a stale one is answered at once and refreshed behind the answer
/// (`refreshing`), and only a missing one waits for X. A part whose budget
/// is down to its reserve is held back (`deferred`) rather than leave the
/// apps without; only when every part asked for failed is the answer an
/// error.
pub async fn insights(
    State(state): State<Arc<AppState>>,
    Path(tweet_id): Path<String>,
    Query(q): Query<InsightsQuery>,
) -> std::result::Result<Json<PostInsights>, ApiError> {
    let id = super::posts::numeric_id(&tweet_id)
        .ok_or_else(|| ApiError::bad_request("not a post id"))?;
    let parts = requested_parts(q.parts.as_deref())?;
    let count = super::timeline::page_count(q.count, GLANCE_COUNT);
    let hints = Hints {
        likes: q.likes,
        reposts: q.reposts,
    };
    glance_post(&state, id, &parts, count, hints, q.wait.unwrap_or(true))
        .await
        .map(Json)
}

/// `POST /api/insights`: glances at several posts at once (`{"posts":
/// [{"id", "likes", "reposts"}], "parts", "count"}`), each as [`insights`]
/// answers it with `wait` off, so a page of the user's posts takes one
/// request that never waits on X; ask again for what's `refreshing`. What
/// the cache lacks is asked of X likers first for every post, in the order
/// given, then analytics, then reposters, so a cold page shows its faces
/// before its numbers.
pub async fn batch(
    State(state): State<Arc<AppState>>,
    Json(req): Json<BatchRequest>,
) -> std::result::Result<Json<InsightsBatch>, ApiError> {
    if req.posts.len() > MAX_BATCH {
        return Err(ApiError::bad_request(format!(
            "at most {MAX_BATCH} posts at a time"
        )));
    }
    let parts = match req.parts.filter(|p| !p.is_empty()) {
        Some(mut parts) => {
            parts.dedup();
            parts
        }
        None => requested_parts(None)?,
    };
    let count = super::timeline::page_count(req.count, GLANCE_COUNT);
    let mut seen = std::collections::HashSet::new();
    let posts: Vec<(String, Hints)> = req
        .posts
        .iter()
        .filter_map(|p| {
            let id = super::posts::numeric_id(&p.id)?.to_string();
            seen.insert(id.clone()).then_some((
                id,
                Hints {
                    likes: p.likes,
                    reposts: p.reposts,
                },
            ))
        })
        .collect();
    let mut outcomes: Vec<Vec<(InsightPart, Option<Outcome<Answer>>)>> =
        posts.iter().map(|_| Vec::new()).collect();
    for part in [
        InsightPart::Likers,
        InsightPart::Analytics,
        InsightPart::Reposters,
    ] {
        for ((id, hints), got) in posts.iter().zip(outcomes.iter_mut()) {
            let ask = Ask {
                id,
                part,
                count,
                hint: match part {
                    InsightPart::Likers => hints.likes,
                    InsightPart::Reposters => hints.reposts,
                    InsightPart::Analytics => None,
                },
                wait: false,
                wanted: parts.contains(&part),
            };
            got.push((part, glance_part(&state, ask).await));
        }
    }
    let mut out = InsightsBatch::default();
    for ((id, _), got) in posts.into_iter().zip(outcomes) {
        match assemble(got) {
            Ok(insights) => {
                out.posts.insert(id, insights);
            }
            Err(e) => {
                out.errors.insert(id, e.kind.to_string());
            }
        }
    }
    Ok(Json(out))
}

/// Every part asked for of one post, each from the cache or from X. With
/// `wait`, a part the cache doesn't have yet is waited for; without, it's
/// asked of X behind the answer and named in `refreshing`, so a page of
/// posts is answered at once and fills in as X answers (every request to X
/// is spaced out, so a cold page takes a while). Likers go first, since
/// their faces are what a post shows.
async fn glance_post(
    state: &Arc<AppState>,
    id: &str,
    parts: &[InsightPart],
    count: u32,
    hints: Hints,
    wait: bool,
) -> std::result::Result<PostInsights, ApiError> {
    let ask = |part: InsightPart, hint| Ask {
        id,
        part,
        count,
        hint,
        wait,
        wanted: parts.contains(&part),
    };
    let (likers, analytics, reposters) = tokio::join!(
        glance_part(state, ask(InsightPart::Likers, hints.likes)),
        glance_part(state, ask(InsightPart::Analytics, None)),
        glance_part(state, ask(InsightPart::Reposters, hints.reposts)),
    );
    let answer = assemble(vec![
        (InsightPart::Analytics, analytics),
        (InsightPart::Likers, likers),
        (InsightPart::Reposters, reposters),
    ])?;
    tracing::debug!(
        post = %id,
        refreshing = ?answer.refreshing,
        deferred = ?answer.deferred,
        failed = ?answer.failed,
        "post insights"
    );
    Ok(answer)
}

/// One part of one post, as asked for.
#[derive(Debug, Clone, Copy)]
struct Ask<'a> {
    id: &'a str,
    part: InsightPart,
    count: u32,
    /// The count the client sees for the part (likes for likers).
    hint: Option<u64>,
    wait: bool,
    wanted: bool,
}

impl Ask<'_> {
    fn key(&self) -> String {
        format!("{}:{:?}", self.id, self.part)
    }
}

fn store_part(part: InsightPart) -> Part {
    match part {
        InsightPart::Analytics => Part::Analytics,
        InsightPart::Likers => Part::Likers,
        InsightPart::Reposters => Part::Reposters,
    }
}

fn now_ms() -> i64 {
    chrono::Utc::now().timestamp_millis()
}

/// How long ago a post went out, read from its id.
fn post_age(id: &str) -> Duration {
    crate::parse::activity::posted_at(id)
        .and_then(|at| (chrono::Utc::now() - at).to_std().ok())
        .unwrap_or_default()
}

fn cached(state: &AppState, id: &str, part: Part) -> Option<Cached> {
    state
        .insights
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .get(id, part)
}

/// One part from the cache when there is one (refreshing it behind the
/// answer once it's stale), otherwise from X: waited for, or with `wait`
/// off, asked for behind the answer. A part X just failed or held back is
/// answered with that until its pause is over, so asking again can't make
/// X fail again.
async fn glance_part(state: &Arc<AppState>, ask: Ask<'_>) -> Option<Outcome<Answer>> {
    if !ask.wanted {
        return None;
    }
    if ask.part != InsightPart::Analytics && ask.hint == Some(0) {
        return Some(Outcome::Got(Answer {
            payload: serde_json::json!({"users": [], "cursor": null}),
            fetched_at_ms: now_ms(),
            refreshing: false,
        }));
    }
    let key = store_part(ask.part);
    let hit = cached(state, ask.id, key)
        .filter(|c| ask.part == InsightPart::Analytics || cache::covers(c, ask.count));
    let hit = hit.or_else(|| {
        state
            .recent_setback(&ask.key())
            .and_then(|_| cached(state, ask.id, key))
    });
    if let Some(hit) = hit {
        let fresh = cache::is_fresh(key, &hit, now_ms(), post_age(ask.id), ask.hint);
        let refreshing = !fresh && state.recent_setback(&ask.key()).is_none();
        if refreshing {
            fetch_behind(state, ask);
        }
        return Some(Outcome::Got(Answer {
            payload: hit.payload,
            fetched_at_ms: hit.fetched_at_ms,
            refreshing,
        }));
    }
    if let Some(setback) = state.recent_setback(&ask.key()) {
        return Some(setback_outcome(setback));
    }
    if ask.wait {
        return Some(fetch_part(state, ask).await);
    }
    fetch_behind(state, ask);
    Some(Outcome::Pending)
}

/// What a remembered setback answers: the rest of the wait X asked for, or
/// the failure again.
fn setback_outcome(setback: Setback) -> Outcome<Answer> {
    match setback.error {
        None => Outcome::Deferred(setback.left),
        Some((status, kind, message)) => Outcome::Failed(ApiError::new(status, kind, message)),
    }
}

/// Fetches one part from X behind the answer already given, unless that
/// part is being fetched already.
fn fetch_behind(state: &Arc<AppState>, ask: Ask<'_>) {
    let key = ask.key();
    if !state.begin_refresh(&key) {
        return;
    }
    let state = Arc::clone(state);
    let id = ask.id.to_string();
    let (part, count, hint) = (ask.part, ask.count, ask.hint);
    tokio::spawn(async move {
        let _claim = Claim {
            state: Arc::clone(&state),
            key,
        };
        let ask = Ask {
            id: &id,
            part,
            count,
            hint,
            wait: false,
            wanted: true,
        };
        if let Outcome::Failed(e) = fetch_part(&state, ask).await {
            tracing::debug!(post = %id, ?part, "insights fetch behind failed: {}", e.message);
        }
    });
}

/// A background fetch's claim on its key, given up however the fetch ends
/// (a panic included), so the key can't stay "being fetched" for good.
struct Claim {
    state: Arc<AppState>,
    key: String,
}

impl Drop for Claim {
    fn drop(&mut self) {
        self.state.end_refresh(&self.key);
    }
}

/// One part from X, stored for the next ask. Requests for the same part
/// wait for one another, and one that finds it just fetched takes that. A
/// failure or a hold-back is remembered for a while (`note_setback`). Only
/// fetches behind an answer queue for `insight_fetches`; one a client is
/// waiting for goes straight to X's pacing.
async fn fetch_part(state: &Arc<AppState>, ask: Ask<'_>) -> Outcome<Answer> {
    let (id, part, count) = (ask.id, ask.part, ask.count);
    let key = store_part(part);
    let lock = state.insight_lock(&ask.key());
    let _turn = lock.lock().await;
    if let Some(setback) = state.recent_setback(&ask.key()) {
        return setback_outcome(setback);
    }
    if let Some(hit) = cached(state, id, key)
        && now_ms() - hit.fetched_at_ms < JUST_FETCHED_MS
        && (part == InsightPart::Analytics || cache::covers(&hit, count))
    {
        return Outcome::Got(Answer {
            payload: hit.payload,
            fetched_at_ms: hit.fetched_at_ms,
            refreshing: false,
        });
    }
    let _permit = if ask.wait {
        None
    } else {
        match state.insight_fetches.acquire().await {
            Ok(permit) => Some(permit),
            Err(_) => return Outcome::Failed(ApiError::internal("shutting down")),
        }
    };
    let outcome = match part {
        InsightPart::Analytics => {
            from_x(state, Operation::TweetActivityQuery, || {
                super::tweet::fetch_analytics(state, id)
            })
            .await
        }
        InsightPart::Likers => {
            from_x(state, Operation::Favoriters, || {
                engagers(state, Engagers::Likes, id, count, None)
            })
            .await
        }
        InsightPart::Reposters => {
            from_x(state, Operation::Retweeters, || {
                engagers(state, Engagers::Reposts, id, count, None)
            })
            .await
        }
    };
    match &outcome {
        Outcome::Got(answer) => {
            let entry = Cached {
                fetched_at_ms: answer.fetched_at_ms,
                seen_count: ask.hint,
                page_size: (part != InsightPart::Analytics).then_some(count),
                payload: answer.payload.clone(),
            };
            state
                .insights
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .put(id, key, &entry);
        }
        Outcome::Deferred(wait) => state.note_setback(&ask.key(), *wait, None),
        Outcome::Failed(e) => state.note_setback(
            &ask.key(),
            FAILURE_PAUSE,
            Some((e.status, e.kind, e.message.clone())),
        ),
        Outcome::Pending => {}
    }
    outcome
}

/// `GET /api/tweets/{id}/quotes`'s first page, cached like the parts of a
/// glance: X finds quotes with a search, whose budget is the smallest.
pub(super) async fn first_quotes_page(
    state: &Arc<AppState>,
    id: &str,
) -> std::result::Result<TimelinePage, ApiError> {
    let key = format!("{id}:quotes");
    if let Some(hit) = cached(state, id, Part::Quotes)
        && let Ok(page) = serde_json::from_value::<TimelinePage>(hit.payload.clone())
    {
        if !cache::is_fresh(Part::Quotes, &hit, now_ms(), post_age(id), None)
            && state.recent_setback(&key).is_none()
            && state.begin_refresh(&key)
        {
            let state = Arc::clone(state);
            let id = id.to_string();
            tokio::spawn(async move {
                let _claim = Claim {
                    state: Arc::clone(&state),
                    key,
                };
                if let Err(e) = fetch_quotes_into_cache(&state, &id).await {
                    tracing::debug!(post = %id, "quotes refresh failed: {}", e.message);
                }
            });
        }
        return Ok(page);
    }
    fetch_quotes_into_cache(state, id).await
}

async fn fetch_quotes_into_cache(
    state: &Arc<AppState>,
    id: &str,
) -> std::result::Result<TimelinePage, ApiError> {
    let key = format!("{id}:quotes");
    let lock = state.insight_lock(&key);
    let _turn = lock.lock().await;
    if let Some(setback) = state.recent_setback(&key) {
        return Err(match setback_outcome(setback) {
            Outcome::Failed(e) => e,
            _ => ApiError::rate_limited(60, "X asked to wait before searching for quotes again"),
        });
    }
    if let Some(hit) = cached(state, id, Part::Quotes)
        && now_ms() - hit.fetched_at_ms < JUST_FETCHED_MS
        && let Ok(page) = serde_json::from_value::<TimelinePage>(hit.payload)
    {
        return Ok(page);
    }
    let page = match super::posts::fetch_quotes(state, id, None).await {
        Ok(page) => page,
        Err(e) => {
            let pause = match e.kind {
                "rate_limited" => Duration::from_secs(e.retry_after_secs.unwrap_or(60)),
                _ => FAILURE_PAUSE,
            };
            state.note_setback(&key, pause, Some((e.status, e.kind, e.message.clone())));
            return Err(e);
        }
    };
    if let Ok(payload) = serde_json::to_value(&page) {
        state
            .insights
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .put(
                id,
                Part::Quotes,
                &Cached {
                    fetched_at_ms: now_ms(),
                    seen_count: None,
                    page_size: None,
                    payload,
                },
            );
    }
    Ok(page)
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

/// Asks X for one part, unless its budget should be left alone for now.
async fn from_x<T, F, Fut>(state: &AppState, op: Operation, fetch: F) -> Outcome<Answer>
where
    T: serde::Serialize,
    F: FnOnce() -> Fut,
    Fut: Future<Output = std::result::Result<T, ApiError>>,
{
    if let Some(wait) = state.gql.spare_budget_wait(op) {
        tracing::debug!(
            op = op.name(),
            wait_secs = wait.as_secs(),
            "glance held back"
        );
        return Outcome::Deferred(wait);
    }
    match fetch().await {
        Ok(value) => Outcome::Got(Answer {
            payload: serde_json::to_value(value).unwrap_or(Value::Null),
            fetched_at_ms: now_ms(),
            refreshing: false,
        }),
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
    }
}

/// Puts the parts' outcomes together. When every part asked for failed, the
/// first failure is the answer, so a signed-out or offline server says so
/// rather than answering with nothing.
fn assemble(
    outcomes: Vec<(InsightPart, Option<Outcome<Answer>>)>,
) -> std::result::Result<PostInsights, ApiError> {
    let mut answer = PostInsights::default();
    let mut asked = 0;
    let mut waits = Vec::new();
    let mut failures = Vec::new();
    for (part, outcome) in outcomes {
        let Some(outcome) = outcome else { continue };
        asked += 1;
        match outcome {
            Outcome::Got(got) => {
                answer.fetched_at.insert(part, got.fetched_at_ms);
                if got.refreshing {
                    answer.refreshing.push(part);
                }
                match part {
                    InsightPart::Analytics => {
                        answer.analytics = serde_json::from_value(got.payload).ok().flatten();
                    }
                    InsightPart::Likers => answer.likers = serde_json::from_value(got.payload).ok(),
                    InsightPart::Reposters => {
                        answer.reposters = serde_json::from_value(got.payload).ok();
                    }
                }
            }
            Outcome::Deferred(wait) => {
                answer.deferred.push(part);
                waits.push(wait);
            }
            Outcome::Failed(e) => {
                answer.failed.push(part);
                failures.push(e);
            }
            Outcome::Pending => answer.refreshing.push(part),
        }
    }
    if asked > 0 && failures.len() == asked {
        return Err(failures.remove(0));
    }
    answer.retry_after_secs = waits.iter().min().map(|w| w.as_secs().max(1));
    Ok(answer)
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

    fn got(payload: Value, at: i64, refreshing: bool) -> Option<Outcome<Answer>> {
        Some(Outcome::Got(Answer {
            payload,
            fetched_at_ms: at,
            refreshing,
        }))
    }

    fn json_page(cursor: &str) -> Value {
        serde_json::to_value(page(cursor)).unwrap()
    }

    #[test]
    fn fetched_parts_fill_in_and_absent_analytics_is_not_a_failure() {
        let answer = assemble(vec![
            (InsightPart::Analytics, got(Value::Null, 1, false)),
            (InsightPart::Likers, got(json_page("l"), 2, false)),
            (InsightPart::Reposters, None),
        ])
        .unwrap();
        assert_eq!(answer.analytics, None);
        assert_eq!(answer.likers, Some(page("l")));
        assert_eq!(answer.reposters, None);
        assert!(
            answer.deferred.is_empty() && answer.failed.is_empty() && answer.refreshing.is_empty()
        );
        assert_eq!(answer.retry_after_secs, None);
        assert_eq!(answer.fetched_at[&InsightPart::Likers], 2);
    }

    #[test]
    fn cached_parts_being_refreshed_are_named() {
        let analytics = serde_json::to_value(unrager_model::PostAnalytics {
            impressions: 9,
            ..Default::default()
        })
        .unwrap();
        let answer = assemble(vec![
            (InsightPart::Analytics, got(analytics, 5, true)),
            (InsightPart::Likers, got(json_page("l"), 6, false)),
        ])
        .unwrap();
        assert_eq!(answer.analytics.map(|a| a.impressions), Some(9));
        assert_eq!(answer.refreshing, [InsightPart::Analytics]);
    }

    #[test]
    fn held_back_parts_say_when_to_ask_again() {
        let answer = assemble(vec![
            (InsightPart::Analytics, got(Value::Null, 1, false)),
            (
                InsightPart::Likers,
                Some(Outcome::Deferred(Duration::from_secs(300))),
            ),
            (
                InsightPart::Reposters,
                Some(Outcome::Deferred(Duration::from_millis(400))),
            ),
        ])
        .unwrap();
        assert_eq!(
            answer.deferred,
            [InsightPart::Likers, InsightPart::Reposters]
        );
        assert_eq!(answer.retry_after_secs, Some(1));
    }

    #[test]
    fn one_failure_among_answers_is_reported_and_all_failing_is_an_error() {
        let answer = assemble(vec![
            (InsightPart::Analytics, Some(Outcome::Failed(auth()))),
            (InsightPart::Likers, got(json_page("l"), 1, false)),
        ])
        .unwrap();
        assert_eq!(answer.failed, [InsightPart::Analytics]);
        assert_eq!(answer.likers, Some(page("l")));

        let error = assemble(vec![
            (InsightPart::Analytics, Some(Outcome::Failed(auth()))),
            (
                InsightPart::Likers,
                Some(Outcome::Failed(ApiError::internal("x"))),
            ),
            (InsightPart::Reposters, None),
        ])
        .unwrap_err();
        assert_eq!(error.kind, "auth");
    }

    #[test]
    fn parts_asked_of_x_behind_the_answer_are_refreshing_and_absent() {
        let answer = assemble(vec![
            (InsightPart::Analytics, Some(Outcome::Pending)),
            (InsightPart::Likers, got(json_page("l"), 3, false)),
        ])
        .unwrap();
        assert_eq!(answer.refreshing, [InsightPart::Analytics]);
        assert!(
            answer.analytics.is_none() && !answer.fetched_at.contains_key(&InsightPart::Analytics)
        );
    }

    #[test]
    fn a_remembered_setback_answers_as_it_happened() {
        let held = setback_outcome(Setback {
            left: Duration::from_secs(30),
            error: None,
        });
        assert!(matches!(held, Outcome::Deferred(d) if d == Duration::from_secs(30)));
        let failed = setback_outcome(Setback {
            left: Duration::from_secs(30),
            error: Some((StatusCode::UNAUTHORIZED, "auth", "signed out".into())),
        });
        assert!(matches!(failed, Outcome::Failed(e) if e.kind == "auth"));
    }

    #[test]
    fn everything_held_back_is_still_an_answer() {
        let answer = assemble(vec![(
            InsightPart::Analytics,
            Some(Outcome::Deferred(Duration::from_secs(90))),
        )])
        .unwrap();
        assert_eq!(answer.deferred, [InsightPart::Analytics]);
        assert_eq!(answer.retry_after_secs, Some(90));
    }
}
