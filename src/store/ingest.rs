//! The background ingest worker: keeps the materialized Home buffer fresh.
//!
//! Runs inside whichever process holds the `feed.db` writer lock (the serve
//! daemon, or the TUI when no serve is up). Each cycle fetches the latest Home
//! pages, upserts them into the capped ring buffer, classifies new tweets with
//! the rage filter, and trims to the cap. Polling is activity-gated: when no
//! client has touched the feed for a while the worker parks until woken, so an
//! unused app does no fetching and no GPU classification.

use crate::config::FeedConfig;
use crate::error::Result;
use crate::gql::GqlClient;
use crate::gql::endpoints;
use crate::gql::query_ids::Operation;
use crate::model::Tweet;
use crate::parse::timeline;
use crate::store::feed::{FeedStore, FeedVariant, now_secs};
use crate::tui::filter::{self, ClassifierHandle, FilterCache};
use std::sync::Arc;
use std::sync::atomic::{AtomicI64, Ordering};
use std::time::Duration;
use tokio::sync::{Mutex, Notify, watch};

const FETCH_COUNT: u32 = 40;
const SEEN_IDS_LIMIT: usize = 100;
/// Below this idle window a client is "active" and the worker polls briskly.
const ACTIVE_WINDOW_SECS: i64 = 900;
/// A parked worker re-checks at most this often even without a wake signal.
const PARK_CEILING: Duration = Duration::from_secs(3600);

/// Shared liveness signal: clients bump it on every feed read, the worker reads
/// it to decide how hard to poll (and parks entirely when it goes cold).
pub struct Activity {
    last: AtomicI64,
    wake: Notify,
}

impl Activity {
    /// Start cold — a fresh serve parks until the first client request wakes it,
    /// so booting the daemon and never connecting does zero work.
    pub fn idle() -> Self {
        Self {
            last: AtomicI64::new(0),
            wake: Notify::new(),
        }
    }

    /// Start warm — the TUI's self-ingest is active the moment it opens.
    pub fn active() -> Self {
        Self {
            last: AtomicI64::new(now_secs()),
            wake: Notify::new(),
        }
    }

    pub fn touch(&self) {
        self.last.store(now_secs(), Ordering::Relaxed);
        // `notify_one` stores a permit if the worker isn't parked yet, so a
        // request arriving in the gap before the worker awaits still wakes it.
        self.wake.notify_one();
    }

    fn idle_secs(&self) -> i64 {
        (now_secs() - self.last.load(Ordering::Relaxed)).max(0)
    }

    async fn woken(&self) {
        self.wake.notified().await;
    }
}

/// Drive the ingest loop until `shutdown` flips to `true`. Owns the writable
/// store for its whole lifetime (it holds the single-writer lock).
pub async fn run(
    gql: Arc<GqlClient>,
    classifier: ClassifierHandle,
    filter_cache: Arc<Mutex<FilterCache>>,
    mut store: FeedStore,
    cfg: FeedConfig,
    activity: Arc<Activity>,
    mut shutdown: watch::Receiver<bool>,
) {
    tracing::info!(buffer_cap = cfg.buffer_cap, "feed ingest worker started");
    loop {
        if *shutdown.borrow() {
            break;
        }
        let idle = activity.idle_secs();
        if idle >= cfg.idle_after_secs as i64 {
            tracing::debug!(idle_secs = idle, "feed ingest parked (idle)");
            tokio::select! {
                _ = activity.woken() => {}
                _ = tokio::time::sleep(PARK_CEILING) => {}
                res = shutdown.changed() => { if res.is_err() { break; } }
            }
            continue;
        }

        let classify_enabled = classifier.is_alive().await;
        if !classify_enabled {
            tracing::debug!("ollama unreachable; ingesting without classification this cycle");
        }
        let mut total = 0usize;
        for variant in [FeedVariant::ForYou, FeedVariant::Following] {
            if *shutdown.borrow() {
                break;
            }
            match run_cycle(
                &gql,
                &classifier,
                &filter_cache,
                &mut store,
                variant,
                cfg.buffer_cap,
                classify_enabled,
            )
            .await
            {
                Ok(n) => total += n,
                Err(e) => {
                    tracing::warn!(variant = variant.as_source(), error = %e, "feed ingest cycle failed")
                }
            }
        }

        let interval = if idle < ACTIVE_WINDOW_SECS {
            cfg.active_poll_secs
        } else {
            cfg.recent_poll_secs
        };
        let sleep_for = jittered(interval);
        tracing::debug!(
            new_rows = total,
            next_poll_secs = sleep_for.as_secs(),
            "feed ingest cycle complete"
        );
        // No early wake here: while active the worker is already polling on
        // cadence, so it just sleeps the interval (responding only to shutdown).
        tokio::select! {
            _ = tokio::time::sleep(sleep_for) => {}
            res = shutdown.changed() => { if res.is_err() { break; } }
        }
    }
    tracing::info!("feed ingest worker stopped");
}

async fn run_cycle(
    gql: &GqlClient,
    classifier: &ClassifierHandle,
    filter_cache: &Mutex<FilterCache>,
    store: &mut FeedStore,
    variant: FeedVariant,
    cap: usize,
    classify_enabled: bool,
) -> Result<usize> {
    let following = matches!(variant, FeedVariant::Following);
    let op = if following {
        Operation::HomeLatestTimeline
    } else {
        Operation::HomeTimeline
    };
    let seen_ids = store
        .recent_ids(variant, SEEN_IDS_LIMIT)
        .unwrap_or_default();
    let seen_refs: Vec<&str> = seen_ids.iter().map(String::as_str).collect();
    let response = gql
        .post_background(
            op,
            &endpoints::home_timeline_variables(FETCH_COUNT, None, &seen_refs),
            &endpoints::home_timeline_features(),
        )
        .await?;
    let instructions =
        timeline::extract_instructions(&response, "/data/home/home_timeline_urt/instructions")?;
    let page = timeline::walk(instructions);
    let fetched = page.tweets.len();

    let new_rows = store_tweets(store, variant, &page.tweets)?;

    for tweet in &page.tweets {
        let cached = filter_cache.lock().await.get(&tweet.rest_id);
        let verdict = match cached {
            Some(v) => Some(v),
            None if classify_enabled => {
                let text = filter::build_classification_text(tweet);
                let v = classifier.classify(&tweet.rest_id, &text).await;
                filter_cache.lock().await.put(&tweet.rest_id, v);
                Some(v)
            }
            None => None,
        };
        if let Some(v) = verdict {
            store.update_verdict(variant, &tweet.rest_id, v)?;
        }
    }

    store.trim_to_cap(variant, cap)?;
    store.record_poll(variant, new_rows as i64)?;
    tracing::info!(
        variant = variant.as_source(),
        fetched,
        new_rows,
        classified = classify_enabled,
        "feed ingest"
    );
    Ok(new_rows)
}

/// Upsert a fetched page into the store, returning the count of net-new rows.
/// Split out so it can be unit-tested without a live X / Ollama.
fn store_tweets(store: &mut FeedStore, variant: FeedVariant, tweets: &[Tweet]) -> Result<usize> {
    let mut new_rows = 0;
    for tweet in tweets {
        if store.upsert(variant, tweet)? {
            new_rows += 1;
        }
    }
    Ok(new_rows)
}

fn jittered(secs: u64) -> Duration {
    use rand::Rng;
    let base = secs.max(1) as f64;
    let factor = rand::rng().random_range(0.9..=1.1);
    Duration::from_secs_f64(base * factor)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::User;
    use chrono::DateTime;
    use tempfile::TempDir;

    fn tweet(rest_id: &str, created_ts: i64) -> Tweet {
        Tweet {
            rest_id: rest_id.into(),
            author: User {
                rest_id: "u".into(),
                handle: "a".into(),
                name: "A".into(),
                verified: false,
                followers: 0,
                following: 0,
                avatar_url: None,
            },
            created_at: DateTime::from_timestamp(created_ts, 0).unwrap(),
            text: "hi".into(),
            reply_count: 0,
            retweet_count: 0,
            like_count: 0,
            quote_count: 0,
            view_count: None,
            bookmark_count: 0,
            favorited: false,
            retweeted: false,
            bookmarked: false,
            lang: None,
            in_reply_to_tweet_id: None,
            quoted_tweet: None,
            media: Vec::new(),
            url: format!("https://x.com/a/status/{rest_id}"),
            urls: Vec::new(),
        }
    }

    #[test]
    fn store_tweets_counts_only_new_rows() {
        let dir = TempDir::new().unwrap();
        let mut store = FeedStore::open_writer(&dir.path().join("feed.db"))
            .unwrap()
            .unwrap();
        let batch = vec![tweet("1", 100), tweet("2", 200), tweet("3", 300)];
        assert_eq!(
            store_tweets(&mut store, FeedVariant::ForYou, &batch).unwrap(),
            3
        );
        let overlap = vec![tweet("3", 300), tweet("4", 400)];
        assert_eq!(
            store_tweets(&mut store, FeedVariant::ForYou, &overlap).unwrap(),
            1,
            "only the genuinely new tweet counts"
        );
        assert_eq!(store.count(FeedVariant::ForYou).unwrap(), 4);
    }

    #[test]
    fn jitter_stays_within_band() {
        for _ in 0..50 {
            let d = jittered(100).as_secs_f64();
            assert!((90.0..=110.0).contains(&d), "jittered {d} out of band");
        }
    }

    #[test]
    fn activity_idle_starts_cold_and_warms_on_touch() {
        let a = Activity::idle();
        assert!(a.idle_secs() > ACTIVE_WINDOW_SECS, "idle() starts parked");
        a.touch();
        assert!(a.idle_secs() < 5, "touch() marks freshly active");
    }
}
