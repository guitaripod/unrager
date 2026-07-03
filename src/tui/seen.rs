use crate::error::Result;
use rusqlite::{Connection, params};
use std::collections::HashSet;
use std::path::Path;

const RETENTION_DAYS: i64 = 2;

pub struct SeenStore {
    conn: Connection,
    cache: HashSet<String>,
}

impl SeenStore {
    pub fn open(path: &Path) -> Result<Self> {
        let conn = Connection::open(path)?;
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS seen (
                tweet_id TEXT PRIMARY KEY,
                seen_at INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS notification_seen (
                slot INTEGER PRIMARY KEY CHECK (slot = 0),
                marker TEXT NOT NULL,
                updated_at INTEGER NOT NULL
            );
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;",
        )?;

        let cutoff = chrono::Utc::now().timestamp() - RETENTION_DAYS * 86400;
        let pruned = conn.execute("DELETE FROM seen WHERE seen_at < ?1", params![cutoff])?;
        if pruned > 0 {
            tracing::info!(pruned, "seen.db: pruned old entries");
        }

        let mut stmt = conn.prepare("SELECT tweet_id FROM seen")?;
        let rows = stmt.query_map([], |row| row.get::<_, String>(0))?;
        let mut cache = HashSet::new();
        for r in rows {
            cache.insert(r?);
        }
        drop(stmt);
        Ok(Self { conn, cache })
    }

    pub fn is_seen(&self, tweet_id: &str) -> bool {
        self.cache.contains(tweet_id)
    }

    pub fn mark_seen(&mut self, tweet_id: &str) {
        if self.cache.insert(tweet_id.to_string()) {
            let now = chrono::Utc::now().timestamp();
            if let Err(e) = self.conn.execute(
                "INSERT OR IGNORE INTO seen (tweet_id, seen_at) VALUES (?1, ?2)",
                params![tweet_id, now],
            ) {
                tracing::warn!("seen db write failed: {e}");
            }
        }
    }

    pub fn mark_all(&mut self, tweet_ids: impl IntoIterator<Item = String>) {
        let now = chrono::Utc::now().timestamp();
        let tx = match self.conn.transaction() {
            Ok(tx) => tx,
            Err(e) => {
                tracing::warn!("seen db transaction failed: {e}");
                return;
            }
        };
        for id in tweet_ids {
            if self.cache.insert(id.clone()) {
                if let Err(e) = tx.execute(
                    "INSERT OR IGNORE INTO seen (tweet_id, seen_at) VALUES (?1, ?2)",
                    params![id, now],
                ) {
                    tracing::warn!("seen db batch write failed: {e}");
                }
            }
        }
        if let Err(e) = tx.commit() {
            tracing::warn!("seen db commit failed: {e}");
        }
    }

    pub fn count_unseen(&self, tweet_ids: &[String]) -> usize {
        tweet_ids.iter().filter(|id| !self.is_seen(id)).count()
    }

    /// The newest-seen notification marker (a timestamp-id string chosen by
    /// clients), persisted so badge state syncs across every client of this
    /// account. `None` until a client has ever marked notifications seen.
    pub fn notifications_marker(&self) -> Option<String> {
        self.conn
            .query_row(
                "SELECT marker FROM notification_seen WHERE slot = 0",
                [],
                |row| row.get::<_, String>(0),
            )
            .ok()
    }

    /// Advances the shared notification marker, but never regresses it: a
    /// slower or offline client pushing an older marker must not re-light
    /// badges on clients that already synced a newer one. Markers are
    /// `<timestamp_ms>-<id>`; freshness is the leading millisecond count.
    pub fn set_notifications_marker(&mut self, marker: &str) {
        if let Some(current) = self.notifications_marker() {
            if marker_millis(marker) < marker_millis(&current) {
                return;
            }
        }
        let now = chrono::Utc::now().timestamp();
        if let Err(e) = self.conn.execute(
            "INSERT INTO notification_seen (slot, marker, updated_at) VALUES (0, ?1, ?2)
             ON CONFLICT(slot) DO UPDATE SET marker = excluded.marker,
                                             updated_at = excluded.updated_at",
            params![marker, now],
        ) {
            tracing::warn!("notification seen marker write failed: {e}");
        }
    }
}

fn marker_millis(marker: &str) -> i64 {
    marker
        .split_once('-')
        .map(|(ms, _)| ms)
        .unwrap_or(marker)
        .parse()
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::NamedTempFile;

    fn fresh_store() -> (NamedTempFile, SeenStore) {
        let tmp = NamedTempFile::new().unwrap();
        let store = SeenStore::open(tmp.path()).unwrap();
        (tmp, store)
    }

    #[test]
    fn mark_and_is_seen_roundtrip() {
        let (_tmp, mut store) = fresh_store();
        assert!(!store.is_seen("1"));
        store.mark_seen("1");
        assert!(store.is_seen("1"));
    }

    #[test]
    fn persist_across_opens() {
        let tmp = NamedTempFile::new().unwrap();
        {
            let mut s = SeenStore::open(tmp.path()).unwrap();
            s.mark_seen("42");
        }
        let s = SeenStore::open(tmp.path()).unwrap();
        assert!(s.is_seen("42"));
        assert!(!s.is_seen("99"));
    }

    #[test]
    fn count_unseen_works() {
        let (_tmp, mut store) = fresh_store();
        store.mark_seen("1");
        store.mark_seen("2");
        let ids = vec!["1".to_string(), "2".to_string(), "3".to_string()];
        assert_eq!(store.count_unseen(&ids), 1);
    }

    #[test]
    fn mark_all_batch() {
        let (_tmp, mut store) = fresh_store();
        store.mark_all(vec!["a".into(), "b".into(), "c".into()]);
        assert!(store.is_seen("a"));
        assert!(store.is_seen("b"));
        assert!(store.is_seen("c"));
    }

    #[test]
    fn notifications_marker_starts_absent_and_upserts() {
        let (_tmp, mut store) = fresh_store();
        assert_eq!(store.notifications_marker(), None);
        store.set_notifications_marker("1700000000000-abc");
        assert_eq!(
            store.notifications_marker().as_deref(),
            Some("1700000000000-abc")
        );
        store.set_notifications_marker("1800000000000-def");
        assert_eq!(
            store.notifications_marker().as_deref(),
            Some("1800000000000-def")
        );
    }

    #[test]
    fn notifications_marker_never_regresses() {
        let (_tmp, mut store) = fresh_store();
        store.set_notifications_marker("1800000000000-def");
        store.set_notifications_marker("1700000000000-abc");
        assert_eq!(
            store.notifications_marker().as_deref(),
            Some("1800000000000-def")
        );
    }

    #[test]
    fn notifications_marker_persists_across_opens() {
        let tmp = NamedTempFile::new().unwrap();
        {
            let mut s = SeenStore::open(tmp.path()).unwrap();
            s.set_notifications_marker("m-1");
        }
        let s = SeenStore::open(tmp.path()).unwrap();
        assert_eq!(s.notifications_marker().as_deref(), Some("m-1"));
    }
}
