use crate::error::{Error, Result};
use crate::tui::filter::FilterDecision;
use fs2::FileExt;
use rusqlite::{Connection, params};
use std::fs::File;
use std::path::{Path, PathBuf};
use std::time::Duration;
use unrager_model::Tweet;

const BUSY_TIMEOUT: Duration = Duration::from_millis(5000);
const CURSOR_TAG: &str = "S1~";

/// Which standing Home feed a row belongs to. The two variants order
/// differently (Following chronologically, For You by X's per-batch rank), so
/// each is stored and paginated under its own `source` discriminator.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FeedVariant {
    ForYou,
    Following,
}

impl FeedVariant {
    pub fn from_following(following: bool) -> Self {
        if following {
            Self::Following
        } else {
            Self::ForYou
        }
    }

    pub fn as_source(self) -> &'static str {
        match self {
            Self::ForYou => "home_foryou",
            Self::Following => "home_following",
        }
    }

    fn order_by(self) -> &'static str {
        match self {
            Self::Following => "created_at DESC, rest_id DESC",
            Self::ForYou => "ingest_seq DESC",
        }
    }
}

/// A materialized tweet plus the rage-filter verdict computed at ingest time.
/// `verdict == None` means it has not been classified yet (treated as visible).
#[derive(Debug, Clone)]
pub struct StoredTweet {
    pub tweet: Tweet,
    pub verdict: Option<FilterDecision>,
}

/// One page of stored tweets plus the keyset cursor for the next page. A
/// `None` cursor means the buffer has no further rows for this variant.
#[derive(Debug, Clone, Default)]
pub struct FeedPage {
    pub items: Vec<StoredTweet>,
    pub next_cursor: Option<String>,
}

/// Per-variant freshness, surfaced to clients as the "updated Nm ago" signal.
#[derive(Debug, Clone, Copy)]
pub struct FeedMeta {
    pub last_poll_at: i64,
    pub last_ingest_count: i64,
}

/// The shared materialized-feed store (`feed.db`). Opened read-write by the one
/// process that holds the writer flock (the ingest worker), and read-only by
/// every other client. WAL mode lets readers run concurrently with the writer.
pub struct FeedStore {
    conn: Connection,
    seq: i64,
    writable: bool,
    _lock: Option<File>,
}

impl FeedStore {
    /// Open read-only. Never takes the writer lock; safe to call from any number
    /// of processes alongside the single writer.
    pub fn open_reader(path: &Path) -> Result<Self> {
        let conn = open_conn(path)?;
        let seq = max_seq(&conn);
        Ok(Self {
            conn,
            seq,
            writable: false,
            _lock: None,
        })
    }

    /// Try to open read-write. Returns `Ok(None)` when another process already
    /// holds the writer lock (the caller should fall back to `open_reader`).
    pub fn open_writer(path: &Path) -> Result<Option<Self>> {
        let lock_path = writer_lock_path(path);
        if let Some(parent) = lock_path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let lock_file = File::create(&lock_path)?;
        if lock_file.try_lock_exclusive().is_err() {
            return Ok(None);
        }
        let conn = open_conn(path)?;
        let seq = max_seq(&conn);
        Ok(Some(Self {
            conn,
            seq,
            writable: true,
            _lock: Some(lock_file),
        }))
    }

    pub fn is_writable(&self) -> bool {
        self.writable
    }

    /// Insert a freshly fetched tweet, or refresh an existing row's payload and
    /// engagement counts. `ingest_seq` and `first_seen` are assigned once and
    /// never rewritten — the For You rank stays stable across re-fetches.
    /// Returns `true` when the row was newly inserted.
    pub fn upsert(&mut self, variant: FeedVariant, tweet: &Tweet) -> Result<bool> {
        let payload = serde_json::to_string(tweet)?;
        let created = tweet.created_at.timestamp();
        let now = now_secs();
        let source = variant.as_source();
        let seq = self.seq + 1;
        let inserted = self.conn.execute(
            "INSERT OR IGNORE INTO tweets
                (rest_id, source, payload, created_at, ingest_seq, first_seen, filter_verdict)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'unclassified')",
            params![tweet.rest_id, source, payload, created, seq, now],
        )?;
        if inserted == 1 {
            self.seq = seq;
            Ok(true)
        } else {
            self.conn.execute(
                "UPDATE tweets SET payload = ?3, created_at = ?4 WHERE rest_id = ?1 AND source = ?2",
                params![tweet.rest_id, source, payload, created],
            )?;
            Ok(false)
        }
    }

    /// The rubric hash the stored verdicts were classified under, if any
    /// writer has recorded one. Readers compare it against their own live
    /// rubric hash before trusting `filter_verdict` values — a mismatch means
    /// every stored verdict predates the current rubric.
    pub fn rubric_hash(&self) -> Option<String> {
        self.conn
            .query_row("SELECT hash FROM rubric WHERE id = 1", [], |row| row.get(0))
            .ok()
    }

    /// Reconcile stored verdicts with the current rubric. When `hash` differs
    /// from the recorded one (the user edited `filter.toml` or patched the
    /// rubric over the API), every verdict is reset to unclassified so stale
    /// hide/keep decisions can never be served, seeded, or re-persisted under
    /// the new rubric. Returns `true` when the hash changed.
    pub fn ensure_rubric_hash(&mut self, hash: &str) -> Result<bool> {
        if self.rubric_hash().as_deref() == Some(hash) {
            return Ok(false);
        }
        let reset = self.conn.execute(
            "UPDATE tweets SET filter_verdict = 'unclassified' WHERE filter_verdict != 'unclassified'",
            [],
        )?;
        self.conn.execute(
            "INSERT INTO rubric (id, hash) VALUES (1, ?1)
             ON CONFLICT(id) DO UPDATE SET hash = excluded.hash",
            params![hash],
        )?;
        if reset > 0 {
            tracing::info!(
                reset,
                hash,
                "feed.db: rubric changed, stored verdicts reset to unclassified"
            );
        }
        Ok(true)
    }

    pub fn update_verdict(
        &mut self,
        variant: FeedVariant,
        rest_id: &str,
        decision: FilterDecision,
    ) -> Result<()> {
        self.conn.execute(
            "UPDATE tweets SET filter_verdict = ?3 WHERE rest_id = ?1 AND source = ?2",
            params![rest_id, variant.as_source(), verdict_to_str(Some(decision))],
        )?;
        Ok(())
    }

    /// Keep only the top-`cap` rows for a variant (newest by its ordering key),
    /// bounding both disk and the GPU classification work. `cap` is floored at 1
    /// so a misconfigured `buffer_cap = 0` can never wipe the whole buffer on
    /// every ingest cycle (`LIMIT 0` would make `NOT IN (…)` match every row).
    pub fn trim_to_cap(&mut self, variant: FeedVariant, cap: usize) -> Result<usize> {
        let cap = cap.max(1);
        let sql = format!(
            "DELETE FROM tweets WHERE source = ?1 AND rest_id NOT IN (
                SELECT rest_id FROM tweets WHERE source = ?1 ORDER BY {} LIMIT ?2
            )",
            variant.order_by()
        );
        let removed = self
            .conn
            .execute(&sql, params![variant.as_source(), cap as i64])?;
        Ok(removed)
    }

    pub fn record_poll(&mut self, variant: FeedVariant, ingest_count: i64) -> Result<()> {
        self.conn.execute(
            "INSERT INTO feed_meta (source, last_poll_at, last_ingest_count)
             VALUES (?1, ?2, ?3)
             ON CONFLICT(source) DO UPDATE SET
                last_poll_at = excluded.last_poll_at,
                last_ingest_count = excluded.last_ingest_count",
            params![variant.as_source(), now_secs(), ingest_count],
        )?;
        Ok(())
    }

    pub fn meta(&self, variant: FeedVariant) -> Option<FeedMeta> {
        self.conn
            .query_row(
                "SELECT last_poll_at, last_ingest_count FROM feed_meta WHERE source = ?1",
                params![variant.as_source()],
                |row| {
                    Ok(FeedMeta {
                        last_poll_at: row.get(0)?,
                        last_ingest_count: row.get(1)?,
                    })
                },
            )
            .ok()
    }

    pub fn count(&self, variant: FeedVariant) -> Result<i64> {
        let n = self.conn.query_row(
            "SELECT COUNT(*) FROM tweets WHERE source = ?1",
            params![variant.as_source()],
            |row| row.get(0),
        )?;
        Ok(n)
    }

    /// The most-recent tweet ids stored for a variant, passed back to X as
    /// `seenTweetIds` so the next poll returns fresher content.
    pub fn recent_ids(&self, variant: FeedVariant, limit: usize) -> Result<Vec<String>> {
        let sql = format!(
            "SELECT rest_id FROM tweets WHERE source = ?1 ORDER BY {} LIMIT ?2",
            variant.order_by()
        );
        let mut stmt = self.conn.prepare(&sql)?;
        let rows = stmt.query_map(params![variant.as_source(), limit as i64], |row| {
            row.get::<_, String>(0)
        })?;
        let mut ids = Vec::new();
        for r in rows {
            ids.push(r?);
        }
        Ok(ids)
    }

    /// Read one keyset page. `cursor` is an opaque token previously returned in
    /// `FeedPage::next_cursor`; `None` starts at the top of the buffer.
    pub fn read_page(
        &self,
        variant: FeedVariant,
        cursor: Option<&str>,
        limit: usize,
    ) -> Result<FeedPage> {
        let source = variant.as_source();
        let lim = limit as i64;
        let raw = match variant {
            FeedVariant::Following => {
                let after = cursor.and_then(decode_following_cursor);
                match after {
                    Some((created, rest)) => {
                        self.query_following_after(source, created, &rest, lim)
                    }
                    None => self.query_following_top(source, lim),
                }?
            }
            FeedVariant::ForYou => {
                let after = cursor.and_then(decode_foryou_cursor);
                match after {
                    Some(seq) => self.query_foryou_after(source, seq, lim),
                    None => self.query_foryou_top(source, lim),
                }?
            }
        };

        let next_cursor = if raw.len() as i64 == lim {
            raw.last().map(|r| match variant {
                FeedVariant::Following => encode_following_cursor(r.created_at, &r.rest_id),
                FeedVariant::ForYou => encode_foryou_cursor(r.ingest_seq),
            })
        } else {
            None
        };

        let items = raw
            .into_iter()
            .filter_map(|r| match serde_json::from_str::<Tweet>(&r.payload) {
                Ok(tweet) => Some(StoredTweet {
                    tweet,
                    verdict: verdict_from_str(&r.verdict),
                }),
                Err(e) => {
                    tracing::warn!(rest_id = %r.rest_id, error = %e, "feed.db: skipping undecodable row");
                    None
                }
            })
            .collect();

        Ok(FeedPage { items, next_cursor })
    }

    fn query_following_top(&self, source: &str, lim: i64) -> Result<Vec<RawRow>> {
        let mut stmt = self.conn.prepare(
            "SELECT payload, filter_verdict, created_at, ingest_seq, rest_id FROM tweets
             WHERE source = ?1 ORDER BY created_at DESC, rest_id DESC LIMIT ?2",
        )?;
        collect(stmt.query_map(params![source, lim], map_raw)?)
    }

    fn query_following_after(
        &self,
        source: &str,
        created: i64,
        rest: &str,
        lim: i64,
    ) -> Result<Vec<RawRow>> {
        let mut stmt = self.conn.prepare(
            "SELECT payload, filter_verdict, created_at, ingest_seq, rest_id FROM tweets
             WHERE source = ?1 AND (created_at < ?2 OR (created_at = ?2 AND rest_id < ?3))
             ORDER BY created_at DESC, rest_id DESC LIMIT ?4",
        )?;
        collect(stmt.query_map(params![source, created, rest, lim], map_raw)?)
    }

    fn query_foryou_top(&self, source: &str, lim: i64) -> Result<Vec<RawRow>> {
        let mut stmt = self.conn.prepare(
            "SELECT payload, filter_verdict, created_at, ingest_seq, rest_id FROM tweets
             WHERE source = ?1 ORDER BY ingest_seq DESC LIMIT ?2",
        )?;
        collect(stmt.query_map(params![source, lim], map_raw)?)
    }

    fn query_foryou_after(&self, source: &str, seq: i64, lim: i64) -> Result<Vec<RawRow>> {
        let mut stmt = self.conn.prepare(
            "SELECT payload, filter_verdict, created_at, ingest_seq, rest_id FROM tweets
             WHERE source = ?1 AND ingest_seq < ?2 ORDER BY ingest_seq DESC LIMIT ?3",
        )?;
        collect(stmt.query_map(params![source, seq, lim], map_raw)?)
    }
}

struct RawRow {
    payload: String,
    verdict: String,
    created_at: i64,
    ingest_seq: i64,
    rest_id: String,
}

fn map_raw(row: &rusqlite::Row<'_>) -> rusqlite::Result<RawRow> {
    Ok(RawRow {
        payload: row.get(0)?,
        verdict: row.get(1)?,
        created_at: row.get(2)?,
        ingest_seq: row.get(3)?,
        rest_id: row.get(4)?,
    })
}

fn collect(
    rows: rusqlite::MappedRows<'_, impl FnMut(&rusqlite::Row<'_>) -> rusqlite::Result<RawRow>>,
) -> Result<Vec<RawRow>> {
    let mut out = Vec::new();
    for r in rows {
        out.push(r?);
    }
    Ok(out)
}

fn open_conn(path: &Path) -> Result<Connection> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| Error::Config(format!("create feed db dir: {e}")))?;
    }
    let conn = Connection::open(path).map_err(|e| Error::Config(format!("open feed.db: {e}")))?;
    conn.pragma_update(None, "journal_mode", "WAL")
        .map_err(|e| Error::Config(format!("feed.db set WAL: {e}")))?;
    conn.pragma_update(None, "synchronous", "NORMAL")
        .map_err(|e| Error::Config(format!("feed.db set sync: {e}")))?;
    conn.busy_timeout(BUSY_TIMEOUT)
        .map_err(|e| Error::Config(format!("feed.db busy_timeout: {e}")))?;
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS tweets (
            rest_id        TEXT NOT NULL,
            source         TEXT NOT NULL,
            payload        TEXT NOT NULL,
            created_at     INTEGER NOT NULL,
            ingest_seq     INTEGER NOT NULL,
            first_seen     INTEGER NOT NULL,
            filter_verdict TEXT NOT NULL,
            PRIMARY KEY (rest_id, source)
        );
        CREATE INDEX IF NOT EXISTS idx_tweets_following ON tweets(source, created_at DESC, rest_id DESC);
        CREATE INDEX IF NOT EXISTS idx_tweets_foryou ON tweets(source, ingest_seq DESC);
        CREATE TABLE IF NOT EXISTS feed_meta (
            source            TEXT PRIMARY KEY,
            last_poll_at      INTEGER NOT NULL,
            last_ingest_count INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS rubric (id INTEGER PRIMARY KEY CHECK (id = 1), hash TEXT NOT NULL);",
    )
    .map_err(|e| Error::Config(format!("feed.db schema: {e}")))?;
    Ok(conn)
}

fn max_seq(conn: &Connection) -> i64 {
    conn.query_row(
        "SELECT COALESCE(MAX(ingest_seq), 0) FROM tweets",
        [],
        |row| row.get(0),
    )
    .unwrap_or(0)
}

fn writer_lock_path(path: &Path) -> PathBuf {
    let mut name = path.file_name().unwrap_or_default().to_os_string();
    name.push(".writer.lock");
    path.with_file_name(name)
}

pub(crate) fn now_secs() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

fn verdict_to_str(v: Option<FilterDecision>) -> &'static str {
    match v {
        Some(FilterDecision::Keep) => "keep",
        Some(FilterDecision::Hide) => "hide",
        None => "unclassified",
    }
}

fn verdict_from_str(s: &str) -> Option<FilterDecision> {
    match s {
        "keep" => Some(FilterDecision::Keep),
        "hide" => Some(FilterDecision::Hide),
        _ => None,
    }
}

/// Whether a cursor was minted by this store (vs a leftover X cursor). Lets the
/// TUI tell a store-paginated feed from a live one when deciding how to append.
pub fn is_store_cursor(s: &str) -> bool {
    s.starts_with(CURSOR_TAG)
}

/// The single routing rule for Home requests: first pages (no cursor) and
/// store-minted cursors belong to the materialized store; a live X cursor —
/// handed out while the buffer was still cold — must keep paginating the live
/// path, because `read_page` treats foreign cursors as "start from the top"
/// and would replay the buffer head as page 2. Used by both the server's
/// `/api/home` handler and the TUI's `try_fetch_from_store` guard.
pub fn cursor_belongs_to_store(cursor: Option<&str>) -> bool {
    cursor.is_none_or(is_store_cursor)
}

fn encode_following_cursor(created_at: i64, rest_id: &str) -> String {
    format!("{CURSOR_TAG}{created_at}:{rest_id}")
}

fn decode_following_cursor(s: &str) -> Option<(i64, String)> {
    let body = s.strip_prefix(CURSOR_TAG)?;
    let (created, rest) = body.split_once(':')?;
    Some((created.parse().ok()?, rest.to_string()))
}

fn encode_foryou_cursor(seq: i64) -> String {
    format!("{CURSOR_TAG}{seq}")
}

fn decode_foryou_cursor(s: &str) -> Option<i64> {
    s.strip_prefix(CURSOR_TAG)?.parse().ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::DateTime;
    use tempfile::TempDir;
    use unrager_model::User;

    fn tweet(rest_id: &str, created_ts: i64) -> Tweet {
        Tweet {
            rest_id: rest_id.into(),
            author: User {
                rest_id: "u".into(),
                handle: "alice".into(),
                name: "Alice".into(),
                verified: false,
                followers: 0,
                following: 0,
                avatar_url: None,
                followed_by_me: None,
            },
            created_at: DateTime::from_timestamp(created_ts, 0).unwrap(),
            text: format!("tweet {rest_id}"),
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
            url: format!("https://x.com/alice/status/{rest_id}"),
            urls: Vec::new(),
        }
    }

    fn writer(dir: &TempDir) -> FeedStore {
        FeedStore::open_writer(&dir.path().join("feed.db"))
            .unwrap()
            .expect("writer lock should be free")
    }

    #[test]
    fn upsert_dedupes_and_keeps_ingest_seq() {
        let dir = TempDir::new().unwrap();
        let mut s = writer(&dir);
        assert!(s.upsert(FeedVariant::ForYou, &tweet("1", 100)).unwrap());
        let first_seq = s.seq;
        let mut updated = tweet("1", 100);
        updated.like_count = 99;
        assert!(!s.upsert(FeedVariant::ForYou, &updated).unwrap());
        assert_eq!(
            s.seq, first_seq,
            "ingest_seq counter must not advance on re-upsert"
        );
        assert_eq!(s.count(FeedVariant::ForYou).unwrap(), 1);
        let page = s.read_page(FeedVariant::ForYou, None, 10).unwrap();
        assert_eq!(page.items.len(), 1);
        assert_eq!(page.items[0].tweet.like_count, 99, "payload should refresh");
    }

    #[test]
    fn following_orders_chronologically() {
        let dir = TempDir::new().unwrap();
        let mut s = writer(&dir);
        s.upsert(FeedVariant::Following, &tweet("a", 300)).unwrap();
        s.upsert(FeedVariant::Following, &tweet("b", 100)).unwrap();
        s.upsert(FeedVariant::Following, &tweet("c", 200)).unwrap();
        let page = s.read_page(FeedVariant::Following, None, 10).unwrap();
        let ids: Vec<&str> = page
            .items
            .iter()
            .map(|i| i.tweet.rest_id.as_str())
            .collect();
        assert_eq!(ids, vec!["a", "c", "b"]);
    }

    #[test]
    fn foryou_preserves_ingest_order() {
        let dir = TempDir::new().unwrap();
        let mut s = writer(&dir);
        s.upsert(FeedVariant::ForYou, &tweet("a", 300)).unwrap();
        s.upsert(FeedVariant::ForYou, &tweet("b", 100)).unwrap();
        s.upsert(FeedVariant::ForYou, &tweet("c", 200)).unwrap();
        let page = s.read_page(FeedVariant::ForYou, None, 10).unwrap();
        let ids: Vec<&str> = page
            .items
            .iter()
            .map(|i| i.tweet.rest_id.as_str())
            .collect();
        assert_eq!(
            ids,
            vec!["c", "b", "a"],
            "newest ingest first, ignoring created_at"
        );
    }

    #[test]
    fn keyset_pagination_is_a_strict_continuation() {
        let dir = TempDir::new().unwrap();
        let mut s = writer(&dir);
        for i in 0..10 {
            s.upsert(FeedVariant::Following, &tweet(&format!("{i:02}"), 100 + i))
                .unwrap();
        }
        let p1 = s.read_page(FeedVariant::Following, None, 4).unwrap();
        assert_eq!(p1.items.len(), 4);
        let cur = p1.next_cursor.clone().expect("more pages");
        let p2 = s.read_page(FeedVariant::Following, Some(&cur), 4).unwrap();
        let p1_ids: Vec<&str> = p1.items.iter().map(|i| i.tweet.rest_id.as_str()).collect();
        let p2_ids: Vec<&str> = p2.items.iter().map(|i| i.tweet.rest_id.as_str()).collect();
        for id in &p2_ids {
            assert!(!p1_ids.contains(id), "no overlap between pages");
        }
        // Inserting a new head row must not shift page 2.
        s.upsert(FeedVariant::Following, &tweet("99", 9_999))
            .unwrap();
        let p2_again = s.read_page(FeedVariant::Following, Some(&cur), 4).unwrap();
        let p2_again_ids: Vec<&str> = p2_again
            .items
            .iter()
            .map(|i| i.tweet.rest_id.as_str())
            .collect();
        assert_eq!(
            p2_ids, p2_again_ids,
            "head insert must not perturb keyset page"
        );
    }

    #[test]
    fn verdict_roundtrips() {
        let dir = TempDir::new().unwrap();
        let mut s = writer(&dir);
        s.upsert(FeedVariant::ForYou, &tweet("1", 100)).unwrap();
        let page = s.read_page(FeedVariant::ForYou, None, 10).unwrap();
        assert_eq!(page.items[0].verdict, None, "fresh rows are unclassified");
        s.update_verdict(FeedVariant::ForYou, "1", FilterDecision::Hide)
            .unwrap();
        let page = s.read_page(FeedVariant::ForYou, None, 10).unwrap();
        assert_eq!(page.items[0].verdict, Some(FilterDecision::Hide));
    }

    #[test]
    fn variants_are_isolated() {
        let dir = TempDir::new().unwrap();
        let mut s = writer(&dir);
        s.upsert(FeedVariant::ForYou, &tweet("1", 100)).unwrap();
        assert_eq!(s.count(FeedVariant::ForYou).unwrap(), 1);
        assert_eq!(s.count(FeedVariant::Following).unwrap(), 0);
        assert!(
            s.read_page(FeedVariant::Following, None, 10)
                .unwrap()
                .items
                .is_empty()
        );
    }

    #[test]
    fn same_tweet_lives_in_both_variants() {
        let dir = TempDir::new().unwrap();
        let mut s = writer(&dir);
        assert!(s.upsert(FeedVariant::ForYou, &tweet("1", 100)).unwrap());
        assert!(s.upsert(FeedVariant::Following, &tweet("1", 100)).unwrap());
        assert_eq!(s.count(FeedVariant::ForYou).unwrap(), 1);
        assert_eq!(s.count(FeedVariant::Following).unwrap(), 1);
    }

    #[test]
    fn trim_to_cap_zero_never_wipes_the_buffer() {
        let dir = TempDir::new().unwrap();
        let mut s = writer(&dir);
        for i in 0..5 {
            s.upsert(FeedVariant::ForYou, &tweet(&format!("{i}"), 100 + i))
                .unwrap();
        }
        s.trim_to_cap(FeedVariant::ForYou, 0).unwrap();
        assert!(
            s.count(FeedVariant::ForYou).unwrap() >= 1,
            "a misconfigured cap=0 must not delete the whole buffer"
        );
    }

    #[test]
    fn trim_to_cap_keeps_newest() {
        let dir = TempDir::new().unwrap();
        let mut s = writer(&dir);
        for i in 0..10 {
            s.upsert(FeedVariant::ForYou, &tweet(&format!("{i:02}"), 100 + i))
                .unwrap();
        }
        let removed = s.trim_to_cap(FeedVariant::ForYou, 3).unwrap();
        assert_eq!(removed, 7);
        let page = s.read_page(FeedVariant::ForYou, None, 100).unwrap();
        let ids: Vec<&str> = page
            .items
            .iter()
            .map(|i| i.tweet.rest_id.as_str())
            .collect();
        assert_eq!(ids, vec!["09", "08", "07"]);
    }

    #[test]
    fn writer_lock_is_exclusive_but_readers_are_not() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("feed.db");
        let w = FeedStore::open_writer(&path).unwrap();
        assert!(w.is_some(), "first writer wins the lock");
        let second = FeedStore::open_writer(&path).unwrap();
        assert!(second.is_none(), "second writer is locked out");
        let reader = FeedStore::open_reader(&path);
        assert!(reader.is_ok(), "readers never block on the writer lock");
    }

    #[test]
    fn ingest_seq_survives_reopen() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("feed.db");
        {
            let mut s = FeedStore::open_writer(&path).unwrap().unwrap();
            s.upsert(FeedVariant::ForYou, &tweet("1", 100)).unwrap();
            s.upsert(FeedVariant::ForYou, &tweet("2", 200)).unwrap();
        }
        let mut s = FeedStore::open_writer(&path).unwrap().unwrap();
        assert_eq!(s.seq, 2, "seq high-water reseeds from MAX(ingest_seq)");
        assert!(s.upsert(FeedVariant::ForYou, &tweet("3", 300)).unwrap());
        let page = s.read_page(FeedVariant::ForYou, None, 10).unwrap();
        assert_eq!(
            page.items[0].tweet.rest_id, "3",
            "new row outranks reopened rows"
        );
    }

    #[test]
    fn stale_foreign_cursor_falls_back_to_top() {
        let dir = TempDir::new().unwrap();
        let mut s = writer(&dir);
        s.upsert(FeedVariant::ForYou, &tweet("1", 100)).unwrap();
        let page = s
            .read_page(FeedVariant::ForYou, Some("some-old-x-cursor-blob"), 10)
            .unwrap();
        assert_eq!(
            page.items.len(),
            1,
            "an unrecognized cursor reads from the top"
        );
    }

    #[test]
    fn rubric_hash_starts_unset_and_persists() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("feed.db");
        {
            let mut s = FeedStore::open_writer(&path).unwrap().unwrap();
            assert_eq!(s.rubric_hash(), None, "fresh store has no rubric recorded");
            assert!(s.ensure_rubric_hash("hash-a").unwrap());
            assert_eq!(s.rubric_hash().as_deref(), Some("hash-a"));
        }
        let s = FeedStore::open_reader(&path).unwrap();
        assert_eq!(
            s.rubric_hash().as_deref(),
            Some("hash-a"),
            "readers see the writer's recorded rubric"
        );
    }

    #[test]
    fn same_rubric_hash_keeps_verdicts() {
        let dir = TempDir::new().unwrap();
        let mut s = writer(&dir);
        s.ensure_rubric_hash("hash-a").unwrap();
        s.upsert(FeedVariant::ForYou, &tweet("1", 100)).unwrap();
        s.update_verdict(FeedVariant::ForYou, "1", FilterDecision::Hide)
            .unwrap();
        assert!(!s.ensure_rubric_hash("hash-a").unwrap(), "no-op on match");
        let page = s.read_page(FeedVariant::ForYou, None, 10).unwrap();
        assert_eq!(page.items[0].verdict, Some(FilterDecision::Hide));
    }

    #[test]
    fn rubric_change_resets_all_verdicts_to_unclassified() {
        let dir = TempDir::new().unwrap();
        let mut s = writer(&dir);
        s.ensure_rubric_hash("hash-a").unwrap();
        s.upsert(FeedVariant::ForYou, &tweet("1", 100)).unwrap();
        s.upsert(FeedVariant::Following, &tweet("2", 200)).unwrap();
        s.update_verdict(FeedVariant::ForYou, "1", FilterDecision::Hide)
            .unwrap();
        s.update_verdict(FeedVariant::Following, "2", FilterDecision::Keep)
            .unwrap();
        assert!(s.ensure_rubric_hash("hash-b").unwrap());
        assert_eq!(s.rubric_hash().as_deref(), Some("hash-b"));
        let foryou = s.read_page(FeedVariant::ForYou, None, 10).unwrap();
        assert_eq!(
            foryou.items[0].verdict, None,
            "old-rubric Hide must not survive a rubric edit"
        );
        let following = s.read_page(FeedVariant::Following, None, 10).unwrap();
        assert_eq!(following.items[0].verdict, None);
    }

    #[test]
    fn first_page_belongs_to_the_store() {
        assert!(cursor_belongs_to_store(None));
    }

    #[test]
    fn store_cursor_stays_on_the_store() {
        assert!(cursor_belongs_to_store(Some("S1~1719000000:123456789")));
        assert!(cursor_belongs_to_store(Some("S1~42")));
    }

    #[test]
    fn live_x_cursor_routes_to_live_pagination() {
        assert!(!cursor_belongs_to_store(Some(
            "DAABCgABGKkX-qzAJxEKAAIYqRACRRrQAAgAAwAAAAEAAA"
        )));
    }

    #[test]
    fn meta_records_freshness() {
        let dir = TempDir::new().unwrap();
        let mut s = writer(&dir);
        assert!(s.meta(FeedVariant::ForYou).is_none());
        s.record_poll(FeedVariant::ForYou, 5).unwrap();
        let m = s.meta(FeedVariant::ForYou).unwrap();
        assert_eq!(m.last_ingest_count, 5);
        assert!(m.last_poll_at > 0);
    }
}
