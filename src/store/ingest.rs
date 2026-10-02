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
use crate::tui::filter::{self, ClassifierHandle, FilterCache, FilterDecision, Judgement};
use futures::StreamExt;
use std::sync::Arc;
use std::sync::atomic::{AtomicI64, Ordering};
use std::time::Duration;
use tokio::sync::{Mutex, Notify, watch};

const FETCH_COUNT: u32 = 40;
/// How many of a page's new tweets are classified at once. Half the shared
/// classifier's permits, so the extension's and apps' own requests never
/// queue behind a whole page of background work.
const INGEST_CLASSIFY_CONCURRENCY: usize = 4;
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
    // Whether the last Following poll surfaced anything new — a Following feed
    // that's caught up (but below the cap) still counts as "full enough" to park.
    let mut following_dry = false;
    let mut reconciled_rubric: Option<String> = None;
    loop {
        if *shutdown.borrow() {
            break;
        }
        reconcile_rubric(&filter_cache, &mut store, &mut reconciled_rubric).await;
        let idle = activity.idle_secs();
        let active = idle < ACTIVE_WINDOW_SECS;
        // Park on buffer fullness, not idle time: keep topping the buffer up in
        // the background until it's as full as it can get, then park (no polling)
        // until a client wakes us — so the buffer is already large when the app
        // is opened.
        if !active && buffer_saturated(&store, cfg.buffer_cap, following_dry) {
            tracing::debug!(idle_secs = idle, "feed ingest parked (buffer full)");
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
        let mut following_new = 0usize;
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
                Ok(n) => {
                    total += n;
                    if matches!(variant, FeedVariant::Following) {
                        following_new = n;
                    }
                }
                Err(e) => {
                    tracing::warn!(variant = variant.as_source(), error = %e, "feed ingest cycle failed")
                }
            }
        }
        following_dry = following_new == 0;

        let interval = if active {
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

/// True once the buffer is as full as it can usefully get, so there's no point
/// polling X: For You at the cap, and Following at the cap or "dry" (its last
/// poll surfaced nothing new — i.e. caught up with what's actually been posted,
/// which for Following is usually well below the cap).
fn buffer_saturated(store: &FeedStore, cap: usize, following_dry: bool) -> bool {
    let cap = cap as i64;
    let foryou = store.count(FeedVariant::ForYou).unwrap_or(0);
    let following = store.count(FeedVariant::Following).unwrap_or(0);
    foryou >= cap && (following >= cap || following_dry)
}

/// Reset stored feed verdicts when the rubric behind the shared filter cache
/// has changed — a live `PATCH /api/config/filter` re-keys the cache in place,
/// and a `filter.toml` edit lands here on the next process start. Without the
/// reset, the buffer would keep serving (and clients keep trusting) hide/keep
/// decisions computed under the previous rubric. `last_reconciled` memoizes the
/// hash this worker already pushed into the store: the rubric changes ~never,
/// so a matching memo skips the sqlite round-trip entirely (the cache lock is
/// held only long enough to copy the hash string).
async fn reconcile_rubric(
    filter_cache: &Mutex<FilterCache>,
    store: &mut FeedStore,
    last_reconciled: &mut Option<String>,
) {
    let hash = filter_cache.lock().await.rubric_hash().to_string();
    if last_reconciled.as_deref() == Some(hash.as_str()) {
        return;
    }
    match store.ensure_rubric_hash(&hash) {
        Ok(_) => *last_reconciled = Some(hash),
        Err(e) => tracing::warn!(error = %e, "feed.db rubric reconcile failed"),
    }
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
    let self_id = gql.self_user_id();
    let verdicts = classify_page(
        classifier,
        filter_cache,
        &page.tweets,
        classify_enabled,
        self_id.as_deref(),
    )
    .await;
    let verdicts: Vec<(&str, FilterDecision)> =
        verdicts.iter().map(|(id, v)| (id.as_str(), *v)).collect();
    store.update_verdicts(variant, &verdicts)?;

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
    store.upsert_page(variant, tweets)
}

/// Verdicts for a fetched page: keep for the user's own posts (`self_id`
/// wrote them), cached ones straight from the filter cache, the rest
/// classified [`INGEST_CLASSIFY_CONCURRENCY`] at a time. New verdicts are
/// persisted only if the rubric didn't change meanwhile, and dropped from the
/// result if it did (the next cycle's reconcile resets the page anyway).
async fn classify_page(
    classifier: &ClassifierHandle,
    filter_cache: &Mutex<FilterCache>,
    tweets: &[Tweet],
    classify_enabled: bool,
    self_id: Option<&str>,
) -> Vec<(String, FilterDecision)> {
    let (rubric, cached): (String, Vec<Option<FilterDecision>>) = {
        let mut cache = filter_cache.lock().await;
        if let Some(me) = self_id {
            cache.exempt(
                tweets
                    .iter()
                    .filter(|t| t.author.rest_id == me)
                    .map(|t| t.rest_id.as_str()),
            );
        }
        (
            cache.rubric_hash().to_string(),
            tweets.iter().map(|t| cache.get(&t.rest_id)).collect(),
        )
    };
    let mut verdicts: Vec<(String, FilterDecision)> = tweets
        .iter()
        .zip(&cached)
        .filter_map(|(t, v)| v.map(|v| (t.rest_id.clone(), v)))
        .collect();
    if !classify_enabled {
        return verdicts;
    }
    let jobs: Vec<(String, String)> = tweets
        .iter()
        .zip(&cached)
        .filter(|(_, v)| v.is_none())
        .map(|(t, _)| (t.rest_id.clone(), filter::build_classification_text(t)))
        .collect();
    let computed: Vec<Option<(String, Judgement)>> = futures::stream::iter(jobs)
        .map(|(id, text)| {
            let classifier = classifier.clone();
            async move { classifier.classify(&id, &text).await.map(|j| (id, j)) }
        })
        .buffer_unordered(INGEST_CLASSIFY_CONCURRENCY)
        .collect()
        .await;
    let computed: Vec<(String, Judgement)> = computed.into_iter().flatten().collect();
    if computed.is_empty() {
        return verdicts;
    }
    let mut cache = filter_cache.lock().await;
    if cache.rubric_hash() != rubric {
        return verdicts;
    }
    let batch: Vec<(&str, Judgement)> = computed
        .iter()
        .map(|(id, j)| (id.as_str(), j.clone()))
        .collect();
    cache.put_judgements(&batch);
    drop(cache);
    verdicts.extend(computed.into_iter().map(|(id, j)| (id, j.decision)));
    verdicts
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
                followed_by_me: None,
                banner_url: None,
                description: None,
                location: None,
                website: None,
                joined_at: None,
                protected: false,
                muting: None,
                blocking: None,
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
            in_reply_to_handle: None,
            quoted_tweet: None,
            media: Vec::new(),
            url: format!("https://x.com/a/status/{rest_id}"),
            urls: Vec::new(),
            retweeted_by: None,
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

    /// An OpenAI-compatible model stub that answers "HIDE 2" after `delay` and
    /// records the most requests it ever had in flight at once.
    async fn stub_model(delay: Duration) -> (String, Arc<std::sync::atomic::AtomicUsize>) {
        use std::sync::atomic::AtomicUsize;
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let in_flight = Arc::new(AtomicUsize::new(0));
        let peak = Arc::new(AtomicUsize::new(0));
        let peak_out = peak.clone();
        tokio::spawn(async move {
            loop {
                let (mut socket, _) = listener.accept().await.unwrap();
                let (in_flight, peak) = (in_flight.clone(), peak.clone());
                tokio::spawn(async move {
                    let mut buf = vec![0u8; 64 * 1024];
                    let mut read = 0;
                    loop {
                        let n = socket.read(&mut buf[read..]).await.unwrap_or(0);
                        if n == 0 {
                            return;
                        }
                        read += n;
                        let head = String::from_utf8_lossy(&buf[..read]).to_string();
                        if let Some(end) = head.find("\r\n\r\n") {
                            let length = head
                                .lines()
                                .find_map(|l| {
                                    l.to_ascii_lowercase()
                                        .strip_prefix("content-length:")
                                        .map(|v| v.trim().parse::<usize>().unwrap_or(0))
                                })
                                .unwrap_or(0);
                            if read >= end + 4 + length {
                                break;
                            }
                        }
                    }
                    let now = in_flight.fetch_add(1, Ordering::SeqCst) + 1;
                    peak.fetch_max(now, Ordering::SeqCst);
                    tokio::time::sleep(delay).await;
                    in_flight.fetch_sub(1, Ordering::SeqCst);
                    let body = r#"{"choices":[{"message":{"content":"HIDE 2"}}]}"#;
                    let response = format!(
                        "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
                        body.len()
                    );
                    let _ = socket.write_all(response.as_bytes()).await;
                });
            }
        });
        (format!("http://{addr}"), peak_out)
    }

    fn classifier_for(host: &str) -> ClassifierHandle {
        let mut cfg: crate::tui::filter::FilterConfig =
            toml::from_str(crate::tui::filter::FilterConfig::default_content()).unwrap();
        cfg.llm.backend = crate::tui::filter::LlmBackend::OpenAi;
        cfg.llm.host = host.into();
        cfg.llm.model = "stub".into();
        cfg.llm.timeout_seconds = 10;
        crate::tui::filter::Classifier::new(&cfg).handle()
    }

    #[tokio::test]
    async fn a_page_is_classified_concurrently_and_cached() {
        let (host, peak) = stub_model(Duration::from_millis(100)).await;
        let classifier = classifier_for(&host);
        let dir = TempDir::new().unwrap();
        let cache =
            Mutex::new(FilterCache::open(&dir.path().join("filter.db"), "rubric".into()).unwrap());
        cache.lock().await.put("0", FilterDecision::Keep);
        let page: Vec<Tweet> = (0..10).map(|i| tweet(&i.to_string(), 100 + i)).collect();

        let verdicts = classify_page(&classifier, &cache, &page, true, None).await;

        assert_eq!(verdicts.len(), 10);
        assert!(
            verdicts.contains(&("0".to_string(), FilterDecision::Keep)),
            "cached verdicts are reused"
        );
        assert_eq!(
            verdicts
                .iter()
                .filter(|(_, v)| *v == FilterDecision::Hide)
                .count(),
            9
        );
        let peak = peak.load(Ordering::SeqCst);
        assert!(
            (2..=INGEST_CLASSIFY_CONCURRENCY).contains(&peak),
            "{peak} requests in flight at once"
        );
        let cache = cache.lock().await;
        assert!((0..10).all(|i| cache.get(&i.to_string()).is_some()));
    }

    #[tokio::test]
    async fn verdicts_from_before_a_rubric_change_are_dropped() {
        let (host, _) = stub_model(Duration::from_millis(300)).await;
        let classifier = classifier_for(&host);
        let dir = TempDir::new().unwrap();
        let cache = Arc::new(Mutex::new(
            FilterCache::open(&dir.path().join("filter.db"), "old".into()).unwrap(),
        ));
        let page = vec![tweet("1", 100), tweet("2", 200)];
        let rekey = {
            let cache = cache.clone();
            tokio::spawn(async move {
                tokio::time::sleep(Duration::from_millis(50)).await;
                cache.lock().await.rekey("new".into()).unwrap();
            })
        };

        let verdicts = classify_page(&classifier, &cache, &page, true, None).await;
        rekey.await.unwrap();

        assert!(
            verdicts.is_empty(),
            "old-rubric verdicts are not used: {verdicts:?}"
        );
        let cache = cache.lock().await;
        assert!(cache.get("1").is_none() && cache.get("2").is_none());
    }

    #[tokio::test]
    async fn without_a_model_only_cached_verdicts_come_back() {
        let classifier = classifier_for("http://127.0.0.1:9");
        let dir = TempDir::new().unwrap();
        let cache =
            Mutex::new(FilterCache::open(&dir.path().join("filter.db"), "rubric".into()).unwrap());
        cache.lock().await.put("1", FilterDecision::Hide);
        let page = vec![tweet("1", 100), tweet("2", 200)];
        let verdicts = classify_page(&classifier, &cache, &page, false, None).await;
        assert_eq!(verdicts, [("1".to_string(), FilterDecision::Hide)]);
    }

    #[tokio::test]
    async fn the_users_own_posts_are_kept_without_asking_the_model() {
        let classifier = classifier_for("http://127.0.0.1:9");
        let dir = TempDir::new().unwrap();
        let cache =
            Mutex::new(FilterCache::open(&dir.path().join("filter.db"), "rubric".into()).unwrap());
        cache.lock().await.put("1", FilterDecision::Hide);
        let mut own = tweet("1", 100);
        own.author.rest_id = "me".into();
        let page = vec![own, tweet("2", 200)];

        let verdicts = classify_page(&classifier, &cache, &page, false, Some("me")).await;

        assert_eq!(
            verdicts,
            [("1".to_string(), FilterDecision::Keep)],
            "an earlier HIDE on the user's own post no longer counts"
        );
    }

    #[tokio::test]
    async fn the_rule_behind_a_hide_is_cached_with_it() {
        let (host, _) = stub_model(Duration::from_millis(10)).await;
        let classifier = classifier_for(&host);
        let dir = TempDir::new().unwrap();
        let cache =
            Mutex::new(FilterCache::open(&dir.path().join("filter.db"), "rubric".into()).unwrap());

        classify_page(&classifier, &cache, &[tweet("1", 100)], true, None).await;

        let cached = cache.lock().await.lookup("1").unwrap();
        assert_eq!(cached.decision, FilterDecision::Hide);
        assert!(
            cached
                .reason
                .as_deref()
                .is_some_and(|r| r.starts_with("war,")),
            "HIDE 2 names the second default topic: {:?}",
            cached.reason
        );
    }

    #[test]
    fn jitter_stays_within_band() {
        for _ in 0..50 {
            let d = jittered(100).as_secs_f64();
            assert!((90.0..=110.0).contains(&d), "jittered {d} out of band");
        }
    }

    #[tokio::test]
    async fn reconcile_rubric_resets_stale_verdicts() {
        use crate::tui::filter::FilterDecision;
        let dir = TempDir::new().unwrap();
        let mut store = FeedStore::open_writer(&dir.path().join("feed.db"))
            .unwrap()
            .unwrap();
        store.ensure_rubric_hash("old-hash").unwrap();
        store.upsert(FeedVariant::ForYou, &tweet("1", 100)).unwrap();
        store
            .update_verdict(FeedVariant::ForYou, "1", FilterDecision::Hide)
            .unwrap();
        let cache = Mutex::new(
            FilterCache::open(&dir.path().join("filter.db"), "new-hash".into()).unwrap(),
        );
        let mut memo = None;
        reconcile_rubric(&cache, &mut store, &mut memo).await;
        assert_eq!(store.rubric_hash().as_deref(), Some("new-hash"));
        assert_eq!(memo.as_deref(), Some("new-hash"));
        let page = store.read_page(FeedVariant::ForYou, None, 10).unwrap();
        assert_eq!(
            page.items[0].verdict, None,
            "old-rubric verdicts are unclassified after reconcile"
        );
        reconcile_rubric(&cache, &mut store, &mut memo).await;
        assert_eq!(store.rubric_hash().as_deref(), Some("new-hash"));
    }

    #[tokio::test]
    async fn reconcile_rubric_memoizes_unchanged_hash() {
        let dir = TempDir::new().unwrap();
        let mut store = FeedStore::open_writer(&dir.path().join("feed.db"))
            .unwrap()
            .unwrap();
        let cache =
            Mutex::new(FilterCache::open(&dir.path().join("filter.db"), "hash-a".into()).unwrap());
        let mut memo = None;
        reconcile_rubric(&cache, &mut store, &mut memo).await;
        assert_eq!(store.rubric_hash().as_deref(), Some("hash-a"));
        store.ensure_rubric_hash("sentinel").unwrap();
        reconcile_rubric(&cache, &mut store, &mut memo).await;
        assert_eq!(
            store.rubric_hash().as_deref(),
            Some("sentinel"),
            "a matching memo skips the sqlite reconcile entirely"
        );
        memo = None;
        reconcile_rubric(&cache, &mut store, &mut memo).await;
        assert_eq!(
            store.rubric_hash().as_deref(),
            Some("hash-a"),
            "a cleared memo (fresh worker) reconciles again"
        );
    }

    #[test]
    fn activity_idle_starts_cold_and_warms_on_touch() {
        let a = Activity::idle();
        assert!(a.idle_secs() > ACTIVE_WINDOW_SECS, "idle() starts parked");
        a.touch();
        assert!(a.idle_secs() < 5, "touch() marks freshly active");
    }
}
