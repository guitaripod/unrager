//! Shared about-profile machinery: the `about.db` verdict cache and the
//! single-flight `AboutAccountQuery` fetcher. The TUI drives it through its
//! pending-queue/event loop; the server resolves inline per request. Both
//! processes point at the same WAL sqlite file, which tolerates concurrent
//! readers and writers.

use crate::error::Result;
use crate::gql::GqlClient;
use crate::gql::endpoints;
use crate::gql::query_ids::Operation;
use crate::model::AboutProfile;
use crate::parse::about;
use crate::store::community::CommunityCache;
use rusqlite::{Connection, params};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use tokio::sync::{Mutex, Semaphore};

/// Negative entries (no `about_profile` data available for a user) are kept
/// only for this window so we periodically retry users who later fill in
/// their location. Positive entries are kept indefinitely — country rarely
/// changes and the disk cost is trivial.
const NEGATIVE_TTL_DAYS: i64 = 30;

/// Bumping this drops every existing row on next open. Use sparingly:
/// only when a buggy prior version polluted the cache in a way that
/// would otherwise stick around for `NEGATIVE_TTL_DAYS`.
///
/// `2`: clears entries written before the rate-limit-failures-as-None
/// fix shipped, since those would otherwise hide flags for 30 days.
const SCHEMA_VERSION: i64 = 2;

/// Entries filled from the community cache are partial and may be stale, so
/// they are looked up again after this many days.
const COMMUNITY_TTL_DAYS: i64 = 14;

/// The canonical `about.db` location inside the cache dir, shared by the TUI
/// and the server so both processes hit the same cache.
pub fn db_path(cache_dir: &Path) -> PathBuf {
    cache_dir.join("about.db")
}

pub struct AboutStore {
    conn: Connection,
    cache: HashMap<String, Option<AboutProfile>>,
}

impl AboutStore {
    pub fn open(path: &Path) -> Result<Self> {
        let conn = Connection::open(path)?;
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS about (
                rest_id TEXT PRIMARY KEY,
                fetched_at INTEGER NOT NULL,
                payload TEXT
            );
            CREATE TABLE IF NOT EXISTS meta (
                key TEXT PRIMARY KEY,
                value INTEGER NOT NULL
            );
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;",
        )?;

        let stored_version: Option<i64> = conn
            .query_row(
                "SELECT value FROM meta WHERE key = 'schema_version'",
                [],
                |row| row.get(0),
            )
            .ok();
        if stored_version != Some(SCHEMA_VERSION) {
            let dropped = conn.execute("DELETE FROM about", [])?;
            conn.execute(
                "INSERT INTO meta (key, value) VALUES ('schema_version', ?1)
                 ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                params![SCHEMA_VERSION],
            )?;
            tracing::info!(
                dropped,
                from = ?stored_version,
                to = SCHEMA_VERSION,
                "about.db: schema bumped, dropped legacy entries"
            );
        }

        let cutoff = chrono::Utc::now().timestamp() - NEGATIVE_TTL_DAYS * 86400;
        let pruned = conn.execute(
            "DELETE FROM about WHERE payload IS NULL AND fetched_at < ?1",
            params![cutoff],
        )?;
        if pruned > 0 {
            tracing::info!(pruned, "about.db: pruned stale negative entries");
        }

        let community_cutoff = chrono::Utc::now().timestamp() - COMMUNITY_TTL_DAYS * 86400;
        let mut stmt = conn.prepare("SELECT rest_id, fetched_at, payload FROM about")?;
        let rows = stmt.query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, i64>(1)?,
                row.get::<_, Option<String>>(2)?,
            ))
        })?;
        let mut cache: HashMap<String, Option<AboutProfile>> = HashMap::new();
        let mut expired: Vec<String> = Vec::new();
        for r in rows {
            let (rest_id, fetched_at, payload) = r?;
            let parsed: Option<AboutProfile> = payload
                .as_deref()
                .and_then(|s| serde_json::from_str(s).ok());
            if parsed.as_ref().is_some_and(|p| p.community) && fetched_at < community_cutoff {
                expired.push(rest_id);
                continue;
            }
            cache.insert(rest_id, parsed);
        }
        drop(stmt);
        for rest_id in &expired {
            conn.execute("DELETE FROM about WHERE rest_id = ?1", params![rest_id])?;
        }
        if !expired.is_empty() {
            tracing::info!(
                expired = expired.len(),
                "about.db: dropped stale community entries"
            );
        }
        tracing::debug!(entries = cache.len(), "about.db: loaded");
        Ok(Self { conn, cache })
    }

    pub fn get(&self, rest_id: &str) -> Option<&Option<AboutProfile>> {
        self.cache.get(rest_id)
    }

    pub fn has(&self, rest_id: &str) -> bool {
        self.cache.contains_key(rest_id)
    }

    pub fn put(&mut self, rest_id: &str, profile: Option<AboutProfile>) {
        let now = chrono::Utc::now().timestamp();
        let payload = profile.as_ref().and_then(|p| serde_json::to_string(p).ok());
        if let Err(e) = self.conn.execute(
            "INSERT INTO about (rest_id, fetched_at, payload) VALUES (?1, ?2, ?3)
             ON CONFLICT(rest_id) DO UPDATE SET fetched_at = excluded.fetched_at, payload = excluded.payload",
            params![rest_id, now, payload],
        ) {
            tracing::warn!("about db write failed for {rest_id}: {e}");
        }
        self.cache.insert(rest_id.to_string(), profile);
    }
}

/// Outcome of an `AboutAccountQuery` round-trip.
///
/// `Ok(Some(_))` — X returned a profile with usable fields.
/// `Ok(None)` — X returned a result but no `about_profile` block (user
///   hasn't set anything). Cache this so we don't refetch every page.
/// `Err(AboutUnavailable)` — transport, rate-limit, or parse failure. **Don't** cache:
///   we'd otherwise mistake a 429 for "this user has no location" and
///   hide their flag for the entire negative-TTL window.
/// Marker error for an about lookup that failed transiently and must stay
/// retryable rather than being cached as a negative result.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AboutUnavailable;

pub type FetchOutcome = std::result::Result<Option<AboutProfile>, AboutUnavailable>;

#[derive(Clone)]
pub struct AboutFetcher {
    client: Arc<GqlClient>,
    sem: Arc<Semaphore>,
    community: Option<Arc<CommunityCache>>,
}

impl AboutFetcher {
    pub fn new(client: Arc<GqlClient>) -> Self {
        Self {
            client,
            sem: Arc::new(Semaphore::new(1)),
            community: None,
        }
    }

    /// Asks the community cache before X in `resolve`.
    pub fn with_community(mut self, community: Option<Arc<CommunityCache>>) -> Self {
        self.community = community;
        self
    }

    /// One single-flighted `AboutAccountQuery` round-trip. The semaphore
    /// serializes upstream calls across every clone of this fetcher so
    /// concurrent callers never burst the AboutAccountQuery rate limit.
    pub async fn fetch(&self, screen_name: &str) -> FetchOutcome {
        let _permit = match self.sem.acquire().await {
            Ok(p) => p,
            Err(_) => return Err(AboutUnavailable),
        };
        fetch_one(&self.client, screen_name).await
    }

    /// Cache-through resolution for inline callers (the server route):
    /// answer from `store` when the user is already known, then from the
    /// community cache when one is configured (ahead of the rate-limit check,
    /// so flags keep coming while X refuses the query), otherwise
    /// single-flight an upstream fetch and cache only `Ok` outcomes —
    /// `Err` means rate-limited/transient, which must stay retryable.
    /// The store is re-checked after the permit is acquired so concurrent
    /// requests for the same user coalesce into one upstream call.
    pub async fn resolve(
        &self,
        store: &Mutex<AboutStore>,
        rest_id: &str,
        screen_name: &str,
    ) -> FetchOutcome {
        if let Some(entry) = store.lock().await.get(rest_id) {
            return Ok(entry.clone());
        }
        if let Some(community) = &self.community
            && let Some(profile) = community.lookup(rest_id, screen_name).await
        {
            store.lock().await.put(rest_id, Some(profile.clone()));
            return Ok(Some(profile));
        }
        if self.client.about_rate_limit_remaining().is_some() {
            return Err(AboutUnavailable);
        }
        let _permit = match self.sem.acquire().await {
            Ok(p) => p,
            Err(_) => return Err(AboutUnavailable),
        };
        if let Some(entry) = store.lock().await.get(rest_id) {
            return Ok(entry.clone());
        }
        let result = fetch_one(&self.client, screen_name).await;
        if let Ok(profile) = &result {
            store.lock().await.put(rest_id, profile.clone());
        }
        result
    }
}

async fn fetch_one(client: &GqlClient, screen_name: &str) -> FetchOutcome {
    let response = match client
        .get(
            Operation::AboutAccountQuery,
            &endpoints::about_account_variables(screen_name),
            &endpoints::about_account_features(),
        )
        .await
    {
        Ok(v) => v,
        Err(e) => {
            tracing::debug!("AboutAccountQuery failed for {screen_name}: {e}");
            return Err(AboutUnavailable);
        }
    };
    match about::parse(&response) {
        Ok(p) if has_any_about_data(&p) => Ok(Some(p)),
        Ok(_) => Ok(None),
        Err(e) => {
            tracing::debug!("AboutAccountQuery parse failed for {screen_name}: {e}");
            Err(AboutUnavailable)
        }
    }
}

fn has_any_about_data(p: &AboutProfile) -> bool {
    p.account_based_in.is_some()
        || p.source.is_some()
        || p.affiliate_username.is_some()
        || p.verified_since.is_some()
        || p.username_changes.is_some_and(|n| n > 0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::auth::XSession;
    use crate::gql::QueryIdStore;
    use chrono::Utc;
    use tempfile::{NamedTempFile, TempDir};

    fn sample_profile(rest_id: &str, country: Option<&str>) -> AboutProfile {
        AboutProfile {
            rest_id: rest_id.into(),
            handle: "someone".into(),
            name: "Someone".into(),
            account_based_in: country.map(str::to_string),
            location_accurate: Some(true),
            source: Some("Web".into()),
            username_changes: Some(0),
            affiliate_username: None,
            created_at: Some(Utc::now()),
            is_blue_verified: false,
            verified: false,
            verified_since: None,
            community: false,
        }
    }

    fn dummy_fetcher(tmp: &TempDir) -> AboutFetcher {
        let session = XSession {
            auth_token: "test".into(),
            ct0: "test".into(),
            twid: "test".into(),
        };
        let store = QueryIdStore::with_fallbacks();
        let client =
            Arc::new(GqlClient::new(session, store, tmp.path().join("qids.json")).unwrap());
        AboutFetcher::new(client)
    }

    #[test]
    fn put_and_get_roundtrip_positive() {
        let tmp = NamedTempFile::new().unwrap();
        let mut s = AboutStore::open(tmp.path()).unwrap();
        let p = sample_profile("100", Some("Japan"));
        s.put("100", Some(p.clone()));
        let got = s.get("100").unwrap().as_ref().unwrap();
        assert_eq!(got.rest_id, "100");
        assert_eq!(got.account_based_in.as_deref(), Some("Japan"));
    }

    #[test]
    fn put_and_get_roundtrip_negative() {
        let tmp = NamedTempFile::new().unwrap();
        let mut s = AboutStore::open(tmp.path()).unwrap();
        s.put("200", None);
        assert!(s.has("200"));
        assert!(s.get("200").unwrap().is_none());
    }

    #[test]
    fn persists_across_open() {
        let tmp = NamedTempFile::new().unwrap();
        {
            let mut s = AboutStore::open(tmp.path()).unwrap();
            s.put("300", Some(sample_profile("300", Some("Indonesia"))));
            s.put("301", None);
        }
        let s = AboutStore::open(tmp.path()).unwrap();
        assert_eq!(
            s.get("300")
                .unwrap()
                .as_ref()
                .unwrap()
                .account_based_in
                .as_deref(),
            Some("Indonesia")
        );
        assert!(s.has("301"));
        assert!(s.get("301").unwrap().is_none());
    }

    #[test]
    fn put_overwrites_existing() {
        let tmp = NamedTempFile::new().unwrap();
        let mut s = AboutStore::open(tmp.path()).unwrap();
        s.put("400", None);
        s.put("400", Some(sample_profile("400", Some("Canada"))));
        let got = s.get("400").unwrap().as_ref().unwrap();
        assert_eq!(got.account_based_in.as_deref(), Some("Canada"));
    }

    #[test]
    fn community_entries_expire_but_x_entries_stay() {
        let tmp = NamedTempFile::new().unwrap();
        {
            let mut s = AboutStore::open(tmp.path()).unwrap();
            let mut community = sample_profile("500", Some("Japan"));
            community.community = true;
            s.put("500", Some(community));
            s.put("501", Some(sample_profile("501", Some("Japan"))));
        }
        let old = chrono::Utc::now().timestamp() - (COMMUNITY_TTL_DAYS + 1) * 86400;
        Connection::open(tmp.path())
            .unwrap()
            .execute("UPDATE about SET fetched_at = ?1", params![old])
            .unwrap();
        let s = AboutStore::open(tmp.path()).unwrap();
        assert!(!s.has("500"));
        assert!(s.has("501"));
    }

    #[test]
    fn fresh_community_entries_are_kept() {
        let tmp = NamedTempFile::new().unwrap();
        {
            let mut s = AboutStore::open(tmp.path()).unwrap();
            let mut community = sample_profile("600", Some("Japan"));
            community.community = true;
            s.put("600", Some(community));
        }
        let s = AboutStore::open(tmp.path()).unwrap();
        assert!(s.get("600").unwrap().as_ref().unwrap().community);
    }

    #[cfg(feature = "server")]
    #[tokio::test]
    async fn resolve_answers_from_the_community_cache_and_stores_it() {
        use crate::store::community::test_support::serve;
        let tmp = TempDir::new().unwrap();
        let (community, service) = serve(serde_json::json!({
            "results": { "someone": {
                "l": "Japan", "d": "Japan App Store", "a": true,
                "t": chrono::Utc::now().timestamp() - 60, "id": "700",
            } },
        }))
        .await;
        let fetcher = dummy_fetcher(&tmp).with_community(Some(community));
        let store = Mutex::new(AboutStore::open(&tmp.path().join("about.db")).unwrap());

        let resolved = fetcher.resolve(&store, "700", "someone").await.unwrap();
        let profile = resolved.unwrap();
        assert_eq!(profile.account_based_in.as_deref(), Some("Japan"));
        assert!(profile.community);
        assert!(store.lock().await.has("700"));

        fetcher.resolve(&store, "700", "someone").await.unwrap();
        assert_eq!(service.requests.lock().unwrap().len(), 1);
    }

    #[test]
    fn db_path_is_stable() {
        assert_eq!(
            db_path(Path::new("/cache")),
            PathBuf::from("/cache/about.db")
        );
    }

    #[tokio::test]
    async fn resolve_answers_positive_hits_from_the_store_without_fetching() {
        let tmp = TempDir::new().unwrap();
        let fetcher = dummy_fetcher(&tmp);
        let store = Mutex::new(AboutStore::open(&tmp.path().join("about.db")).unwrap());
        store
            .lock()
            .await
            .put("500", Some(sample_profile("500", Some("Finland"))));

        let got = fetcher.resolve(&store, "500", "someone").await.unwrap();
        assert_eq!(got.unwrap().account_based_in.as_deref(), Some("Finland"));
    }

    #[tokio::test]
    async fn resolve_answers_negative_hits_from_the_store_without_fetching() {
        let tmp = TempDir::new().unwrap();
        let fetcher = dummy_fetcher(&tmp);
        let store = Mutex::new(AboutStore::open(&tmp.path().join("about.db")).unwrap());
        store.lock().await.put("600", None);

        let got = fetcher.resolve(&store, "600", "someone").await.unwrap();
        assert!(got.is_none());
    }

    #[tokio::test]
    async fn resolve_sees_entries_written_by_another_store_handle() {
        let tmp = TempDir::new().unwrap();
        let path = tmp.path().join("about.db");
        {
            let mut writer = AboutStore::open(&path).unwrap();
            writer.put("700", Some(sample_profile("700", Some("Japan"))));
        }
        let fetcher = dummy_fetcher(&tmp);
        let store = Mutex::new(AboutStore::open(&path).unwrap());

        let got = fetcher.resolve(&store, "700", "someone").await.unwrap();
        assert_eq!(got.unwrap().account_based_in.as_deref(), Some("Japan"));
    }
}
