use crate::auth::chromium;
use crate::config::{self, FeedConfig};
use crate::error::{Error, Result};
use crate::gql::endpoints;
use crate::gql::query_ids::Operation;
use crate::gql::{GqlClient, QueryIdStore};
use crate::model::{Tweet, User};
use crate::parse::tweet as parse_tweet;
use crate::parse::user as parse_user;
use crate::store::about::{self, AboutFetcher, AboutStore};
use crate::store::community::{self, CommunityCache};
use crate::store::feed::FeedStore;
use crate::store::ingest::Activity;
use crate::tui::filter::{Classifier, FilterCache, FilterConfig};
use crate::tui::seen::SeenStore;
use serde_json::Value;
use std::num::NonZeroUsize;
use std::path::PathBuf;
use std::sync::{Arc, PoisonError};
use std::time::{Duration, Instant};
use tokio::sync::Mutex;
use unrager_model::SessionState;

/// How many tweets the server keeps from what it recently sent clients.
const RECENT_TWEETS: NonZeroUsize = NonZeroUsize::new(2000).unwrap();

pub struct AppState {
    /// `serve --filter-only`: no X session is loaded and only the filter
    /// routes answer (what the browser extension needs).
    pub filter_only: bool,
    /// Whether browser cookies were loaded at startup. Without them the
    /// background feed ingest stays off; X-backed routes still re-extract the
    /// session on first use, so a keyring that unlocks later self-heals.
    pub x_session_loaded: bool,
    pub gql: Arc<GqlClient>,
    pub filter_config: Mutex<FilterConfig>,
    /// `Arc` so the background ingest worker can share the exact same cache
    /// instance — verdicts it computes warm the cache the SSE filter reads.
    pub filter_cache: Arc<Mutex<FilterCache>>,
    pub classifier: Mutex<Classifier>,
    /// A cheaply-cloneable handle to the same classifier, shared with route
    /// handlers so `/api/classify` doesn't need to lock `classifier` just to
    /// clone a handle out of it on every request.
    pub classifier_handle: crate::tui::filter::ClassifierHandle,
    pub seen: Mutex<SeenStore>,
    pub session: Mutex<SessionState>,
    /// Read handle on the materialized Home buffer (`feed.db`). The ingest
    /// worker holds a separate write handle behind the single-writer lock.
    pub feed: Mutex<FeedStore>,
    /// Bumped on every feed read; the ingest worker uses it to gate polling.
    pub activity: Arc<Activity>,
    /// Cache over `about.db` — the same file the TUI uses, so flags a TUI
    /// session already resolved answer instantly here and vice versa.
    pub about: Mutex<AboutStore>,
    pub about_fetcher: AboutFetcher,
    /// When X last answered 404 for a first page of the full `Followers`
    /// GraphQL op (removed upstream in 2025), so `/api/users/{id}/followers`
    /// goes straight to the `BlueVerifiedFollowers` fallback for a while.
    pub followers_op_dead_since: std::sync::Mutex<Option<Instant>>,
    /// Tweets recently sent to a client, so a follow-up request about one of
    /// them (its filter verdict, ask, translate) is answered without another
    /// throttled GraphQL round trip to X.
    pub recent_tweets: std::sync::Mutex<lru::LruCache<String, Tweet>>,
    /// Lowercased handle → (numeric id, when it was looked up).
    user_ids: std::sync::Mutex<lru::LruCache<String, (String, Instant)>>,
    /// The signed-in account's (id, handle), so Mentions doesn't ask X who
    /// the user is on every load.
    viewer: std::sync::Mutex<Option<(String, String)>>,
    pub feed_cfg: FeedConfig,
    pub feed_db_path: PathBuf,
    pub lock_path: PathBuf,
    pub session_path: PathBuf,
    pub filter_toml_path: PathBuf,
    pub config_dir: PathBuf,
}

impl AppState {
    pub async fn build(filter_only: bool) -> Result<Self> {
        let session = if filter_only {
            None
        } else {
            match chromium::load_session().await {
                Ok(session) => Some(session),
                Err(e) => {
                    tracing::warn!(
                        "no X session ({e}); serving the filter, feed ingest off until restart"
                    );
                    None
                }
            }
        };
        let x_session_loaded = session.is_some();
        let session = session.unwrap_or_default();
        let config_dir = config::config_dir()?;
        let cache_dir = config::cache_dir()?;
        let app_config = config::AppConfig::load(&config_dir);
        let query_cache = cache_dir.join("query-ids.json");
        let mut store = QueryIdStore::with_fallbacks_and_cache(&query_cache);
        store.apply_config_overrides(&app_config.query_ids);
        let gql = Arc::new(GqlClient::new(session, store, query_cache)?);

        let filter_toml = config_dir.join("filter.toml");
        let filter_config = FilterConfig::load_or_init(&filter_toml)?;
        let filter_db = cache_dir.join("filter.db");
        let filter_cache = FilterCache::open(&filter_db, filter_config.rubric_hash())?;
        let mut classifier = Classifier::new(&filter_config);
        let _ = classifier.init().await;
        let classifier_handle = classifier.handle();

        let seen_db = cache_dir.join("seen.db");
        let seen = SeenStore::open(&seen_db)?;

        let feed_db_path = cache_dir.join("feed.db");
        let feed = FeedStore::open_reader(&feed_db_path)?;

        let about_store = AboutStore::open(&about::db_path(&cache_dir))?;
        let community = app_config.about.community_cache.then(|| {
            tracing::info!(
                "community flag cache on: handles in view are sent to {}",
                community::DEFAULT_URL
            );
            CommunityCache::new(community::DEFAULT_URL)
        });
        let about_fetcher = AboutFetcher::new(gql.clone()).with_community(community);

        let session_path = config_dir.join("server-session.json");
        let state: SessionState = load_session_state(&session_path).unwrap_or_default();

        Ok(Self {
            filter_only,
            x_session_loaded,
            gql,
            filter_config: Mutex::new(filter_config),
            filter_cache: Arc::new(Mutex::new(filter_cache)),
            classifier: Mutex::new(classifier),
            classifier_handle,
            seen: Mutex::new(seen),
            session: Mutex::new(state),
            feed: Mutex::new(feed),
            activity: Arc::new(Activity::idle()),
            about: Mutex::new(about_store),
            about_fetcher,
            followers_op_dead_since: std::sync::Mutex::new(None),
            recent_tweets: std::sync::Mutex::new(lru::LruCache::new(RECENT_TWEETS)),
            user_ids: std::sync::Mutex::new(lru::LruCache::new(USER_IDS)),
            viewer: std::sync::Mutex::new(None),
            feed_cfg: app_config.feed.clone(),
            feed_db_path,
            lock_path: cache_dir.join("server.lock"),
            session_path,
            filter_toml_path: filter_toml,
            config_dir,
        })
    }
}

impl AppState {
    /// Keeps tweets a client was just sent for [`tweet`](Self::tweet).
    pub fn remember<'a>(&self, tweets: impl IntoIterator<Item = &'a Tweet>) {
        let mut recent = self
            .recent_tweets
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        for tweet in tweets {
            recent.put(tweet.rest_id.clone(), tweet.clone());
        }
    }

    /// Whether `id` is a post the signed-in user wrote, going by what this
    /// server recently sent a client and the Home buffer; X is never asked.
    /// The filter never judges those.
    pub async fn is_own_post(&self, id: &str) -> bool {
        let Some(me) = self.gql.self_user_id() else {
            return false;
        };
        let recent = self
            .recent_tweets
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .peek(id)
            .map(|t| t.author.rest_id == me);
        match recent {
            Some(own) => own,
            None => self
                .feed
                .lock()
                .await
                .tweet(id)
                .is_some_and(|t| t.author.rest_id == me),
        }
    }

    /// A tweet by id: from what this server recently sent, then the Home
    /// buffer, and only then from X.
    pub async fn tweet(&self, id: &str) -> Result<Tweet> {
        let recent = self
            .recent_tweets
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(id)
            .cloned();
        if let Some(tweet) = recent {
            return Ok(tweet);
        }
        let stored = self.feed.lock().await.tweet(id);
        let tweet = match stored {
            Some(tweet) => tweet,
            None => fetch_tweet(&self.gql, id).await?,
        };
        self.remember([&tweet]);
        Ok(tweet)
    }

    /// An account by handle with its profile fields, fresh from X,
    /// remembering its id for
    /// [`user_id`](Self::user_id).
    pub async fn user(&self, handle: &str) -> Result<User> {
        let response = self
            .gql
            .get(
                Operation::UserByScreenName,
                &endpoints::user_by_screen_name_variables(handle),
                &endpoints::user_by_screen_name_features(),
            )
            .await?;
        let user = user_from_response(&response, handle)?;
        self.user_ids
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .put(handle_key(handle), (user.rest_id.clone(), Instant::now()));
        Ok(user)
    }

    /// An account's numeric id by handle. Handles rarely change hands, so a
    /// profile's every page and a brief don't each cost a lookup on X first.
    pub async fn user_id(&self, handle: &str) -> Result<String> {
        let cached = self
            .user_ids
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(&handle_key(handle))
            .filter(|(_, at)| at.elapsed() < USER_ID_TTL)
            .map(|(id, _)| id.clone());
        match cached {
            Some(id) => Ok(id),
            None => Ok(self.user(handle).await?.rest_id),
        }
    }

    /// The signed-in account's handle, asked of X once per session.
    pub async fn viewer_handle(&self) -> Result<String> {
        let me = self.gql.self_user_id();
        let cached = self
            .viewer
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone();
        if let Some((id, handle)) = cached
            && me.as_ref() == Some(&id)
        {
            return Ok(handle);
        }
        let handle = crate::cli::common::current_handle(&self.gql).await?;
        if let Some(id) = me {
            *self.viewer.lock().unwrap_or_else(PoisonError::into_inner) =
                Some((id, handle.clone()));
        }
        Ok(handle)
    }
}

/// How long a handle's id is trusted before it's looked up again, in case
/// the account was renamed and the handle taken by someone else.
const USER_ID_TTL: Duration = Duration::from_secs(6 * 60 * 60);
const USER_IDS: NonZeroUsize = NonZeroUsize::new(512).unwrap();

fn handle_key(handle: &str) -> String {
    handle.trim_start_matches('@').to_ascii_lowercase()
}

/// A post by id from X, telling a deleted or withheld post apart from a
/// failed request.
pub async fn fetch_tweet(gql: &GqlClient, id: &str) -> Result<Tweet> {
    let response = gql
        .get(
            Operation::TweetResultByRestId,
            &endpoints::tweet_by_rest_id_variables(id),
            &endpoints::tweet_read_features(),
        )
        .await?;
    if let Some(gone) = tweet_unavailability(&response) {
        return Err(gone);
    }
    parse_tweet::parse_tweet_result_by_rest_id(&response)
}

/// Why X won't show a post, read from a `TweetResultByRestId` answer: no
/// result at all (deleted, or never existed), a tombstone, or
/// `TweetUnavailable` with its reason. `None` for a post X does show.
fn tweet_unavailability(response: &Value) -> Option<Error> {
    let wrapper = response.pointer("/data/tweetResult")?;
    let Some(result) = wrapper.get("result") else {
        return Some(Error::NotFound("post not found or deleted".into()));
    };
    match result.get("__typename").and_then(Value::as_str) {
        Some("TweetTombstone") => {
            let text = result
                .pointer("/tombstone/text/text")
                .and_then(Value::as_str)
                .unwrap_or("");
            Some(Error::Unavailable {
                reason: unavailable_reason(text, "deleted").into(),
            })
        }
        Some("TweetUnavailable") => {
            let reason = result.get("reason").and_then(Value::as_str).unwrap_or("");
            Some(Error::Unavailable {
                reason: unavailable_reason(reason, "unavailable").into(),
            })
        }
        _ => None,
    }
}

/// An account from a `UserByScreenName` answer: no result means no such
/// account (or one deactivated or renamed), `UserUnavailable` one X
/// withholds, with its reason.
fn user_from_response(response: &Value, handle: &str) -> Result<User> {
    let Some(node) = response
        .pointer("/data/user/result")
        .or_else(|| response.pointer("/data/user_v2/result"))
    else {
        return Err(Error::NotFound(format!("no account @{handle}")));
    };
    if node.get("__typename").and_then(Value::as_str) == Some("UserUnavailable") {
        let said = [node.get("reason"), node.get("message")]
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .collect::<Vec<_>>()
            .join(" ");
        return Err(Error::Unavailable {
            reason: unavailable_reason(&said, "unavailable").into(),
        });
    }
    parse_user::parse_profile_result(node)
        .ok_or_else(|| Error::GraphqlShape(format!("@{handle} missing required user fields")))
}

/// Maps X's own wording (a reason code or a tombstone sentence) onto the
/// small set clients understand: `suspended`, `protected`, `deleted` or
/// `unavailable`; `fallback` when the wording names none of them.
fn unavailable_reason(said: &str, fallback: &'static str) -> &'static str {
    let lowered = said.to_ascii_lowercase();
    if lowered.contains("suspend") {
        "suspended"
    } else if lowered.contains("protect") || lowered.contains("limits who can view") {
        "protected"
    } else if lowered.contains("delet") {
        "deleted"
    } else if lowered.is_empty() {
        fallback
    } else {
        "unavailable"
    }
}

fn load_session_state(path: &std::path::Path) -> Option<SessionState> {
    let txt = std::fs::read_to_string(path).ok()?;
    serde_json::from_str(&txt).ok()
}

pub fn save_session_state(path: &std::path::Path, state: &SessionState) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let txt = serde_json::to_string_pretty(state).unwrap_or_else(|_| "{}".into());
    std::fs::write(path, txt)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn reason(error: Option<Error>) -> Option<String> {
        match error {
            Some(Error::Unavailable { reason }) => Some(reason),
            _ => None,
        }
    }

    #[test]
    fn a_missing_account_is_not_found() {
        let response = json!({"data": {"user": {}}});
        assert!(matches!(
            user_from_response(&response, "nobody"),
            Err(Error::NotFound(_))
        ));
        assert!(matches!(
            user_from_response(&json!({"data": {}}), "nobody"),
            Err(Error::NotFound(_))
        ));
    }

    #[test]
    fn a_withheld_account_says_why() {
        let suspended = json!({"data": {"user": {"result": {
            "__typename": "UserUnavailable",
            "reason": "Suspended",
            "message": "User is suspended"
        }}}});
        assert_eq!(
            reason(user_from_response(&suspended, "gone").err()).as_deref(),
            Some("suspended")
        );
        let unexplained = json!({"data": {"user": {"result": {"__typename": "UserUnavailable"}}}});
        assert_eq!(
            reason(user_from_response(&unexplained, "gone").err()).as_deref(),
            Some("unavailable")
        );
    }

    #[test]
    fn a_withheld_post_says_why() {
        let deleted = json!({"data": {"tweetResult": {"result": {
            "__typename": "TweetTombstone",
            "tombstone": {"text": {"text": "This Post was deleted by the Post author. Learn more"}}
        }}}});
        assert_eq!(
            reason(tweet_unavailability(&deleted)).as_deref(),
            Some("deleted")
        );
        let protected = json!({"data": {"tweetResult": {"result": {
            "__typename": "TweetTombstone",
            "tombstone": {"text": {"text": "You're unable to view this Post because this account owner limits who can view their Posts."}}
        }}}});
        assert_eq!(
            reason(tweet_unavailability(&protected)).as_deref(),
            Some("protected")
        );
        let suspended = json!({"data": {"tweetResult": {"result": {
            "__typename": "TweetUnavailable",
            "reason": "Suspended"
        }}}});
        assert_eq!(
            reason(tweet_unavailability(&suspended)).as_deref(),
            Some("suspended")
        );
        let odd = json!({"data": {"tweetResult": {"result": {
            "__typename": "TweetUnavailable",
            "reason": "NsfwLoggedOut"
        }}}});
        assert_eq!(
            reason(tweet_unavailability(&odd)).as_deref(),
            Some("unavailable")
        );
    }

    #[test]
    fn a_vanished_post_is_not_found_and_a_shown_one_passes() {
        let vanished = json!({"data": {"tweetResult": {}}});
        assert!(matches!(
            tweet_unavailability(&vanished),
            Some(Error::NotFound(_))
        ));
        let shown = json!({"data": {"tweetResult": {"result": {"__typename": "Tweet"}}}});
        assert!(tweet_unavailability(&shown).is_none());
        let wrapped = json!({"data": {"tweetResult": {"result": {
            "__typename": "TweetWithVisibilityResults",
            "tweet": {}
        }}}});
        assert!(tweet_unavailability(&wrapped).is_none());
    }

    #[test]
    fn handles_are_cached_case_insensitively() {
        assert_eq!(handle_key("@MiraKoski"), handle_key("mirakoski"));
    }
}
