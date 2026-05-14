use crate::error::Result;
use crate::model::AboutProfile;
use rusqlite::{Connection, params};
use std::collections::HashMap;
use std::path::Path;

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

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Utc;
    use tempfile::NamedTempFile;

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
}
