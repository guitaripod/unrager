//! song.link (Odesli) URL conversion + rich metadata.
//!
//! Twitter posts often contain a link to one specific music streaming service
//! (Spotify, Apple Music, YouTube Music, ...) that won't open for readers who
//! use a different service. song.link returns a universal landing page that
//! offers every available service for the same track / album / artist, plus
//! a title, artist name, and thumbnail we can render as an inline card so the
//! feed isn't littered with truncated `open.spotify.com/track/3CxJwO1l…`
//! strings.
//!
//! The classifier in `is_music_url` runs on every URL we look at, so it's
//! intentionally allocation-free: scheme strip, byte-scan to the first `/`,
//! `www.` strip, single `matches!` against a fixed host list.

use crate::model::Tweet;
use crate::tui::event::{Event, EventTx};
use serde::Deserialize;
use serde_json::Value;
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::Semaphore;

const API_BASE: &str = "https://api.song.link/v1-alpha.1/links";
const CACHE_CAPACITY: usize = 256;

pub fn is_music_url(url: &str) -> bool {
    let Some(host) = host_of(url) else {
        return false;
    };
    let host = host.strip_prefix("www.").unwrap_or(host);
    if host.starts_with("music.amazon.") {
        return true;
    }
    matches!(
        host,
        "open.spotify.com"
            | "spotify.link"
            | "music.apple.com"
            | "music.youtube.com"
            | "soundcloud.com"
            | "on.soundcloud.com"
            | "tidal.com"
            | "deezer.com"
            | "music.pandora.com"
    )
}

fn host_of(url: &str) -> Option<&str> {
    let rest = url
        .strip_prefix("https://")
        .or_else(|| url.strip_prefix("http://"))?;
    let end = rest.find('/').unwrap_or(rest.len());
    Some(&rest[..end])
}

#[derive(Debug, Clone, Default)]
pub struct SongLinkMeta {
    pub title: String,
    pub artist_name: String,
    pub thumbnail_url: String,
    pub page_url: String,
}

#[derive(Debug)]
pub enum MetaState {
    Loading,
    Ready(SongLinkMeta),
    Failed,
}

#[derive(Debug)]
pub struct SongLinkRegistry {
    entries: HashMap<String, MetaState>,
    order: Vec<String>,
    semaphore: Arc<Semaphore>,
}

impl Default for SongLinkRegistry {
    fn default() -> Self {
        Self {
            entries: HashMap::new(),
            order: Vec::new(),
            semaphore: Arc::new(Semaphore::new(2)),
        }
    }
}

impl SongLinkRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn get(&self, source_url: &str) -> Option<&MetaState> {
        self.entries.get(source_url)
    }

    pub fn ensure(&mut self, source_url: &str, tx: &EventTx) {
        if self.entries.contains_key(source_url) {
            return;
        }
        self.evict_if_needed();
        self.order.push(source_url.to_string());
        self.entries
            .insert(source_url.to_string(), MetaState::Loading);
        let url = source_url.to_string();
        let tx = tx.clone();
        let sem = self.semaphore.clone();
        tokio::spawn(async move {
            let _permit = sem.acquire_owned().await.ok();
            let result = fetch_meta(&url).await;
            let _ = tx.send(Event::SongLinkMetaLoaded {
                source_url: url,
                result,
            });
        });
    }

    pub fn ensure_tweet(&mut self, tweet: &Tweet, tx: &EventTx) {
        if let Some(qt) = &tweet.quoted_tweet {
            self.ensure_tweet(qt, tx);
        }
        for u in &tweet.urls {
            if is_music_url(&u.expanded_url) {
                self.ensure(&u.expanded_url, tx);
            }
        }
    }

    pub fn apply_result(&mut self, source_url: &str, result: Result<SongLinkMeta, String>) {
        let state = match result {
            Ok(meta) => MetaState::Ready(meta),
            Err(e) => {
                tracing::debug!(%source_url, "song.link fetch failed: {e}");
                MetaState::Failed
            }
        };
        self.entries.insert(source_url.to_string(), state);
    }

    fn evict_if_needed(&mut self) {
        while self.entries.len() >= CACHE_CAPACITY {
            let Some(oldest) = self.order.first().cloned() else {
                break;
            };
            self.order.remove(0);
            self.entries.remove(&oldest);
        }
    }
}

#[derive(Deserialize)]
struct LinksResponse {
    #[serde(rename = "pageUrl")]
    page_url: String,
    #[serde(rename = "entityUniqueId")]
    entity_unique_id: Option<String>,
    #[serde(rename = "entitiesByUniqueId")]
    entities_by_unique_id: Option<HashMap<String, Value>>,
}

async fn fetch_meta(url: &str) -> Result<SongLinkMeta, String> {
    let api_url = format!("{API_BASE}?url={}", urlencoding::encode(url));
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(8))
        .build()
        .map_err(|e| format!("client: {e}"))?;
    let resp = client
        .get(&api_url)
        .send()
        .await
        .map_err(|e| format!("fetch: {e}"))?
        .error_for_status()
        .map_err(|e| format!("status: {e}"))?;
    let body: LinksResponse = resp.json().await.map_err(|e| format!("decode: {e}"))?;
    if body.page_url.is_empty() {
        return Err("empty pageUrl".into());
    }
    let (title, artist_name, thumbnail_url) = primary_entity(&body);
    Ok(SongLinkMeta {
        title,
        artist_name,
        thumbnail_url,
        page_url: body.page_url,
    })
}

fn primary_entity(body: &LinksResponse) -> (String, String, String) {
    let map = match &body.entities_by_unique_id {
        Some(m) if !m.is_empty() => m,
        _ => return Default::default(),
    };
    let primary = body
        .entity_unique_id
        .as_deref()
        .and_then(|id| map.get(id))
        .or_else(|| map.values().next());
    let Some(entity) = primary else {
        return Default::default();
    };
    let title = entity
        .get("title")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    let artist_name = entity
        .get("artistName")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    let thumbnail_url = entity
        .get("thumbnailUrl")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    (title, artist_name, thumbnail_url)
}

/// Backwards-compatible accessor for the `M` key path: returns the song.link
/// `pageUrl` if the API responded successfully, otherwise `None`.
pub async fn resolve_page_url(url: &str) -> Option<String> {
    match fetch_meta(url).await {
        Ok(meta) => Some(meta.page_url),
        Err(e) => {
            tracing::warn!(url, "song.link resolve failed: {e}");
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_streaming_hosts() {
        assert!(is_music_url("https://open.spotify.com/track/abc"));
        assert!(is_music_url("http://open.spotify.com/track/abc"));
        assert!(is_music_url("https://spotify.link/abc"));
        assert!(is_music_url("https://music.apple.com/us/album/xyz"));
        assert!(is_music_url("https://music.youtube.com/watch?v=q"));
        assert!(is_music_url("https://soundcloud.com/artist/song"));
        assert!(is_music_url("https://on.soundcloud.com/Abc"));
        assert!(is_music_url("https://tidal.com/track/123"));
        assert!(is_music_url("https://www.deezer.com/track/123"));
        assert!(is_music_url("https://deezer.com/track/123"));
        assert!(is_music_url("https://music.amazon.com/albums/B0XYZ"));
        assert!(is_music_url("https://music.amazon.co.uk/albums/B0XYZ"));
        assert!(is_music_url("https://music.amazon.de/albums/B0XYZ"));
        assert!(is_music_url("https://music.pandora.com/artist/foo"));
    }

    #[test]
    fn rejects_non_music_hosts() {
        assert!(!is_music_url("https://github.com/foo/bar"));
        assert!(!is_music_url("https://www.youtube.com/watch?v=abc"));
        assert!(!is_music_url("https://youtu.be/abc"));
        assert!(!is_music_url("https://example.com/spotify"));
        assert!(!is_music_url("https://amazon.com/dp/xyz"));
        assert!(!is_music_url("not-a-url"));
        assert!(!is_music_url(""));
    }

    #[test]
    fn host_of_handles_no_path() {
        assert_eq!(host_of("https://x.com"), Some("x.com"));
        assert_eq!(host_of("https://x.com/foo"), Some("x.com"));
        assert_eq!(host_of("ftp://x.com/foo"), None);
    }

    #[test]
    fn primary_entity_picks_entity_unique_id_first() {
        let body = LinksResponse {
            page_url: "https://song.link/s/abc".into(),
            entity_unique_id: Some("SPOTIFY_SONG::abc".into()),
            entities_by_unique_id: Some(HashMap::from([
                (
                    "SPOTIFY_SONG::abc".to_string(),
                    serde_json::json!({
                        "title": "Mr. Brightside",
                        "artistName": "The Killers",
                        "thumbnailUrl": "https://x/thumb.jpg"
                    }),
                ),
                (
                    "ITUNES_SONG::def".to_string(),
                    serde_json::json!({
                        "title": "wrong",
                        "artistName": "wrong",
                    }),
                ),
            ])),
        };
        let (t, a, th) = primary_entity(&body);
        assert_eq!(t, "Mr. Brightside");
        assert_eq!(a, "The Killers");
        assert_eq!(th, "https://x/thumb.jpg");
    }

    #[test]
    fn primary_entity_falls_back_when_id_missing() {
        let body = LinksResponse {
            page_url: "https://song.link/s/abc".into(),
            entity_unique_id: None,
            entities_by_unique_id: Some(HashMap::from([(
                "FOO::bar".to_string(),
                serde_json::json!({
                    "title": "Only One",
                    "artistName": "Solo",
                }),
            )])),
        };
        let (t, a, _) = primary_entity(&body);
        assert_eq!(t, "Only One");
        assert_eq!(a, "Solo");
    }
}
