//! The server's cache of what X said about the signed-in account's own posts
//! (`insights.db`): each post's analytics and the first page of its likers,
//! reposters and quotes, with when they were fetched and the count the
//! client saw then. The browser extension glances at every own post that
//! scrolls by, so answering from here, and asking X again only once a part
//! has gone stale, keeps both the answers instant and X's budget whole; it
//! survives restarts, so x.com opens on the numbers it last showed.

use crate::error::Result;
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// Rows older than this are dropped when the store opens.
const KEEP_DAYS: i64 = 30;
/// And beyond this many rows, the oldest go.
const MAX_ROWS: i64 = 8_000;

pub fn db_path(cache_dir: &Path) -> PathBuf {
    cache_dir.join("insights.db")
}

/// One cached part of what X says about a post.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Part {
    Analytics,
    Likers,
    Reposters,
    Quotes,
}

impl Part {
    fn key(self) -> &'static str {
        match self {
            Self::Analytics => "analytics",
            Self::Likers => "likers",
            Self::Reposters => "reposters",
            Self::Quotes => "quotes",
        }
    }
}

/// A part as it was fetched.
#[derive(Debug, Clone, PartialEq)]
pub struct Cached {
    pub fetched_at_ms: i64,
    /// The count the asking client saw when the part was fetched (likes for
    /// likers, reposts for reposters), so a rise past it makes the part stale.
    pub seen_count: Option<u64>,
    /// How many people the page was asked for, so a request for more isn't
    /// answered with a shorter page.
    pub page_size: Option<u32>,
    /// X's answer as the API sends it; `null` when X had none.
    pub payload: Value,
}

pub struct InsightsStore {
    conn: Connection,
}

impl InsightsStore {
    pub fn open(path: &Path) -> Result<Self> {
        let store = Self {
            conn: Connection::open(path)?,
        };
        store.init()?;
        store.prune(chrono::Utc::now().timestamp_millis());
        Ok(store)
    }

    pub fn open_in_memory() -> Result<Self> {
        let store = Self {
            conn: Connection::open_in_memory()?,
        };
        store.init()?;
        Ok(store)
    }

    fn init(&self) -> Result<()> {
        self.conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS insights (
                post_id TEXT NOT NULL,
                part TEXT NOT NULL,
                fetched_at INTEGER NOT NULL,
                seen_count INTEGER,
                page_size INTEGER,
                payload TEXT NOT NULL,
                PRIMARY KEY (post_id, part)
            );
            CREATE INDEX IF NOT EXISTS insights_fetched ON insights (fetched_at);
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;",
        )?;
        Ok(())
    }

    pub fn get(&self, post_id: &str, part: Part) -> Option<Cached> {
        self.conn
            .query_row(
                "SELECT fetched_at, seen_count, page_size, payload FROM insights
                 WHERE post_id = ?1 AND part = ?2",
                params![post_id, part.key()],
                |row| {
                    let payload: String = row.get(3)?;
                    Ok(Cached {
                        fetched_at_ms: row.get(0)?,
                        seen_count: row.get::<_, Option<i64>>(1)?.map(|n| n.max(0) as u64),
                        page_size: row.get::<_, Option<i64>>(2)?.map(|n| n.max(0) as u32),
                        payload: serde_json::from_str(&payload).unwrap_or(Value::Null),
                    })
                },
            )
            .optional()
            .unwrap_or_else(|e| {
                tracing::warn!(post = post_id, "insights.db read failed: {e}");
                None
            })
    }

    pub fn put(&self, post_id: &str, part: Part, cached: &Cached) {
        let payload = serde_json::to_string(&cached.payload).unwrap_or_else(|_| "null".into());
        if let Err(e) = self.conn.execute(
            "INSERT INTO insights (post_id, part, fetched_at, seen_count, page_size, payload)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)
             ON CONFLICT(post_id, part) DO UPDATE SET fetched_at = excluded.fetched_at,
               seen_count = excluded.seen_count, page_size = excluded.page_size,
               payload = excluded.payload",
            params![
                post_id,
                part.key(),
                cached.fetched_at_ms,
                cached.seen_count.map(|n| n as i64),
                cached.page_size.map(i64::from),
                payload
            ],
        ) {
            tracing::warn!(post = post_id, "insights.db write failed: {e}");
        }
    }

    fn prune(&self, now_ms: i64) {
        let cutoff = now_ms - KEEP_DAYS * 86_400_000;
        let old = self
            .conn
            .execute(
                "DELETE FROM insights WHERE fetched_at < ?1",
                params![cutoff],
            )
            .unwrap_or(0);
        let over = self
            .conn
            .execute(
                "DELETE FROM insights WHERE rowid IN (
                   SELECT rowid FROM insights ORDER BY fetched_at DESC LIMIT -1 OFFSET ?1)",
                params![MAX_ROWS],
            )
            .unwrap_or(0);
        if old + over > 0 {
            tracing::info!(dropped = old + over, "insights.db: pruned");
        }
    }
}

/// A part fetched further in the future than this means the clock went
/// back, and it's fetched again rather than trusted for that long.
const CLOCK_SLACK_MS: i64 = 60_000;

/// How long a part stays fresh for a post this old: a new post's numbers
/// move by the minute, a week-old one's barely. Quotes come from a search,
/// whose budget is small, so they're kept four times as long.
pub fn fresh_for(part: Part, post_age: Duration) -> Duration {
    let secs = match post_age.as_secs() {
        s if s < 2 * 3_600 => 60,
        s if s < 24 * 3_600 => 180,
        s if s < 7 * 86_400 => 900,
        _ => 7_200,
    };
    Duration::from_secs(if part == Part::Quotes { secs * 4 } else { secs })
}

/// Whether `cached` still stands: younger than `fresh_for`, and its count
/// not risen since (a like count above the one the likers were fetched at
/// means someone new is missing from them).
pub fn is_fresh(
    part: Part,
    cached: &Cached,
    now_ms: i64,
    post_age: Duration,
    count_now: Option<u64>,
) -> bool {
    if cached.fetched_at_ms > now_ms + CLOCK_SLACK_MS {
        return false;
    }
    let age_ms = now_ms.saturating_sub(cached.fetched_at_ms).max(0) as u128;
    if age_ms > fresh_for(part, post_age).as_millis() {
        return false;
    }
    !matches!((count_now, cached.seen_count), (Some(now), Some(then)) if now > then)
}

/// Whether a cached page holds at least as many people as asked for (or
/// all there were).
pub fn covers(cached: &Cached, wanted: u32) -> bool {
    let complete = cached
        .payload
        .get("cursor")
        .is_none_or(serde_json::Value::is_null);
    complete || cached.page_size.is_none_or(|size| size >= wanted)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn cached(at: i64, seen: Option<u64>) -> Cached {
        Cached {
            fetched_at_ms: at,
            seen_count: seen,
            page_size: Some(20),
            payload: json!({"users": [], "cursor": "c"}),
        }
    }

    #[test]
    fn parts_round_trip_and_replace() {
        let store = InsightsStore::open_in_memory().unwrap();
        assert_eq!(store.get("1", Part::Likers), None);
        store.put("1", Part::Likers, &cached(5, Some(3)));
        store.put(
            "1",
            Part::Analytics,
            &Cached {
                payload: Value::Null,
                ..cached(6, None)
            },
        );
        assert_eq!(store.get("1", Part::Likers), Some(cached(5, Some(3))));
        assert_eq!(
            store.get("1", Part::Analytics).unwrap().payload,
            Value::Null
        );
        store.put("1", Part::Likers, &cached(9, Some(4)));
        assert_eq!(store.get("1", Part::Likers).unwrap().fetched_at_ms, 9);
        assert_eq!(store.get("2", Part::Likers), None);
    }

    #[test]
    fn old_rows_and_the_overflow_are_pruned() {
        let store = InsightsStore::open_in_memory().unwrap();
        let now = 100 * 86_400_000;
        store.put("old", Part::Likers, &cached(now - 40 * 86_400_000, None));
        store.put("new", Part::Likers, &cached(now - 86_400_000, None));
        store.prune(now);
        assert!(store.get("old", Part::Likers).is_none());
        assert!(store.get("new", Part::Likers).is_some());
    }

    #[test]
    fn young_posts_go_stale_sooner_and_quotes_later() {
        let hour = Duration::from_secs(3_600);
        assert_eq!(fresh_for(Part::Analytics, hour), Duration::from_secs(60));
        assert_eq!(fresh_for(Part::Likers, hour * 5), Duration::from_secs(180));
        assert_eq!(fresh_for(Part::Likers, hour * 48), Duration::from_secs(900));
        assert_eq!(
            fresh_for(Part::Likers, hour * 24 * 30),
            Duration::from_secs(7_200)
        );
        assert_eq!(fresh_for(Part::Quotes, hour), Duration::from_secs(240));
    }

    #[test]
    fn a_part_is_stale_once_old_or_once_its_count_rose() {
        let day = Duration::from_secs(86_400);
        let c = cached(1_000_000, Some(10));
        assert!(is_fresh(
            Part::Likers,
            &c,
            1_000_000 + 170_000,
            day / 2,
            Some(10)
        ));
        assert!(!is_fresh(
            Part::Likers,
            &c,
            1_000_000 + 190_000,
            day / 2,
            Some(10)
        ));
        assert!(!is_fresh(Part::Likers, &c, 1_000_001, day / 2, Some(11)));
        assert!(is_fresh(Part::Likers, &c, 1_000_001, day / 2, Some(9)));
        assert!(is_fresh(Part::Likers, &c, 1_000_001, day / 2, None));
        assert!(
            is_fresh(Part::Likers, &c, 999_000, day / 2, None),
            "a moment's skew isn't staleness"
        );
        assert!(
            !is_fresh(Part::Likers, &c, 1_000_000 - 3_600_000, day / 2, None),
            "a clock an hour back can't keep a part fresh for that hour"
        );
    }

    #[test]
    fn a_short_page_only_covers_a_bigger_ask_when_it_was_everyone() {
        let mut c = cached(0, None);
        assert!(covers(&c, 20));
        assert!(!covers(&c, 50));
        c.payload = json!({"users": [], "cursor": null});
        assert!(covers(&c, 50));
    }
}
