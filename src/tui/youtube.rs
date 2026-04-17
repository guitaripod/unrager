use crate::model::{MediaKind, Tweet};
use crate::tui::event::{Event, EventTx};
use serde::Deserialize;
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::Semaphore;

const CACHE_CAPACITY: usize = 256;

#[derive(Debug, Clone)]
pub struct YoutubeMeta {
    pub title: String,
    pub author_name: String,
}

#[derive(Debug)]
pub enum MetaState {
    Loading,
    Ready(YoutubeMeta),
    Failed,
}

#[derive(Debug)]
pub struct YoutubeRegistry {
    entries: HashMap<String, MetaState>,
    order: Vec<String>,
    semaphore: Arc<Semaphore>,
}

impl Default for YoutubeRegistry {
    fn default() -> Self {
        Self {
            entries: HashMap::new(),
            order: Vec::new(),
            semaphore: Arc::new(Semaphore::new(2)),
        }
    }
}

impl YoutubeRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn get(&self, video_id: &str) -> Option<&MetaState> {
        self.entries.get(video_id)
    }

    pub fn ensure(&mut self, video_id: &str, tx: &EventTx) {
        if self.entries.contains_key(video_id) {
            return;
        }
        self.evict_if_needed();
        self.order.push(video_id.to_string());
        self.entries
            .insert(video_id.to_string(), MetaState::Loading);
        let id = video_id.to_string();
        let tx = tx.clone();
        let sem = self.semaphore.clone();
        tokio::spawn(async move {
            let _permit = sem.acquire_owned().await.ok();
            let result = fetch_oembed(&id).await;
            let _ = tx.send(Event::YoutubeMetaLoaded {
                video_id: id,
                result,
            });
        });
    }

    /// Queues oEmbed fetches for every YouTube embed attached to this tweet
    /// (and any quoted tweet). Idempotent across calls.
    pub fn ensure_tweet(&mut self, tweet: &Tweet, tx: &EventTx) {
        if let Some(qt) = &tweet.quoted_tweet {
            self.ensure_tweet(qt, tx);
        }
        for m in &tweet.media {
            if let MediaKind::YouTube { video_id } = &m.kind {
                self.ensure(video_id, tx);
            }
        }
    }

    pub fn apply_result(&mut self, video_id: &str, result: Result<YoutubeMeta, String>) {
        let state = match result {
            Ok(meta) => MetaState::Ready(meta),
            Err(e) => {
                tracing::debug!(%video_id, "youtube oembed failed: {e}");
                MetaState::Failed
            }
        };
        self.entries.insert(video_id.to_string(), state);
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

#[derive(Debug, Deserialize)]
struct OEmbed {
    title: Option<String>,
    author_name: Option<String>,
}

async fn fetch_oembed(video_id: &str) -> Result<YoutubeMeta, String> {
    let watch_url = format!("https://www.youtube.com/watch?v={video_id}");
    let oembed_url = format!("https://www.youtube.com/oembed?url={watch_url}&format=json",);
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(8))
        .build()
        .map_err(|e| format!("client: {e}"))?;
    let resp = client
        .get(&oembed_url)
        .send()
        .await
        .map_err(|e| format!("fetch: {e}"))?
        .error_for_status()
        .map_err(|e| format!("status: {e}"))?;
    let body: OEmbed = resp.json().await.map_err(|e| format!("decode: {e}"))?;
    Ok(YoutubeMeta {
        title: body.title.unwrap_or_default(),
        author_name: body.author_name.unwrap_or_default(),
    })
}
