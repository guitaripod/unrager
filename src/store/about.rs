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

        let mut stmt = conn.prepare("SELECT rest_id, payload FROM about")?;
        let rows = stmt.query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?))
        })?;
        let mut cache: HashMap<String, Option<AboutProfile>> = HashMap::new();
        for r in rows {
            let (rest_id, payload) = r?;
            let parsed = payload
                .as_deref()
                .and_then(|s| serde_json::from_str(s).ok());
            cache.insert(rest_id, parsed);
        }
        drop(stmt);
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
/// `Err(())` — transport, rate-limit, or parse failure. **Don't** cache:
///   we'd otherwise mistake a 429 for "this user has no location" and
///   hide their flag for the entire negative-TTL window.
pub type FetchOutcome = std::result::Result<Option<AboutProfile>, ()>;

#[derive(Clone)]
pub struct AboutFetcher {
    client: Arc<GqlClient>,
    sem: Arc<Semaphore>,
}

impl AboutFetcher {
    pub fn new(client: Arc<GqlClient>) -> Self {
        Self {
            client,
            sem: Arc::new(Semaphore::new(1)),
        }
    }

    /// One single-flighted `AboutAccountQuery` round-trip. The semaphore
    /// serializes upstream calls across every clone of this fetcher so
    /// concurrent callers never burst the AboutAccountQuery rate limit.
    pub async fn fetch(&self, screen_name: &str) -> FetchOutcome {
        let _permit = match self.sem.acquire().await {
            Ok(p) => p,
            Err(_) => return Err(()),
        };
        fetch_one(&self.client, screen_name).await
    }

    /// Cache-through resolution for inline callers (the server route):
    /// answer from `store` when the user is already known, otherwise
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
        if self.client.about_rate_limit_remaining().is_some() {
            return Err(());
        }
        let _permit = match self.sem.acquire().await {
            Ok(p) => p,
            Err(_) => return Err(()),
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
            return Err(());
        }
    };
    match about::parse(&response) {
        Ok(p) if has_any_about_data(&p) => Ok(Some(p)),
        Ok(_) => Ok(None),
        Err(e) => {
            tracing::debug!("AboutAccountQuery parse failed for {screen_name}: {e}");
            Err(())
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
