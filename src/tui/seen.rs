use crate::error::Result;
use rusqlite::{Connection, params};
use std::collections::HashSet;
use std::path::Path;

const RETENTION_DAYS: i64 = 30;

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
}
