use crate::error::{Error, Result};
use crate::model::Tweet;
use crate::tui::event::{Event, EventTx};
use rusqlite::{Connection, params};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::Semaphore;
use tracing::{debug, warn};

const DEFAULT_CONFIG: &str = include_str!("filter_default.toml");
const SYSTEM_TEMPLATE: &str = "HIDE or KEEP? HIDE the tweet if it is about, or written by someone from, any of these categories. When in doubt, HIDE.
{TOPICS}
{GUIDANCE}
One word answer:";

const MAX_TEXT_CHARS: usize = 500;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FilterMode {
    On,
    Off,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FilterDecision {
    Keep,
    Hide,
}

#[derive(Debug, Clone)]
pub enum FilterState {
    Unclassified,
    Classified(FilterDecision),
    Unavailable,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FilterConfig {
    pub drop_topics: Vec<String>,
    #[serde(default)]
    pub extra_guidance: String,
    pub ollama: OllamaConfig,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OllamaConfig {
    pub model: String,
    pub host: String,
    pub timeout_seconds: u64,
}

impl FilterConfig {
    pub fn default_content() -> &'static str {
        DEFAULT_CONFIG
    }

    pub fn load_or_init(path: &Path) -> Result<Self> {
        if !path.exists() {
            if let Some(parent) = path.parent() {
                std::fs::create_dir_all(parent)
                    .map_err(|e| Error::Config(format!("create filter config dir: {e}")))?;
            }
            std::fs::write(path, DEFAULT_CONFIG)
                .map_err(|e| Error::Config(format!("write default filter.toml: {e}")))?;
        }
        let raw = std::fs::read_to_string(path)
            .map_err(|e| Error::Config(format!("read filter.toml: {e}")))?;
        let cfg: FilterConfig =
            toml::from_str(&raw).map_err(|e| Error::Config(format!("parse filter.toml: {e}")))?;
        Ok(cfg)
    }

    pub fn rubric_hash(&self) -> String {
        let mut topics: Vec<String> = self
            .drop_topics
            .iter()
            .map(|t| t.trim().to_ascii_lowercase())
            .filter(|t| !t.is_empty())
            .collect();
        topics.sort();
        let mut hasher = Sha256::new();
        for t in &topics {
            hasher.update(t.as_bytes());
            hasher.update(b"\n");
        }
        hasher.update(b"---\n");
        hasher.update(self.extra_guidance.trim().as_bytes());
        let digest = hasher.finalize();
        hex16(&digest[..8])
    }
}

fn hex16(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        out.push(HEX[(*b >> 4) as usize] as char);
        out.push(HEX[(*b & 0x0f) as usize] as char);
    }
    out
}

pub fn build_system_prompt(cfg: &FilterConfig) -> String {
    let mut topics = String::new();
    for t in &cfg.drop_topics {
        if t.trim().is_empty() {
            continue;
        }
        topics.push_str("- ");
        topics.push_str(t.trim());
        topics.push('\n');
    }
    let guidance = if cfg.extra_guidance.trim().is_empty() {
        String::new()
    } else {
        format!("\n{}\n", cfg.extra_guidance.trim())
    };
    SYSTEM_TEMPLATE
        .replace("{TOPICS}", topics.trim_end_matches('\n'))
        .replace("{GUIDANCE}", guidance.trim_end_matches('\n'))
}

pub fn build_classification_text(t: &Tweet) -> String {
    let mut s = format!("@{} ({}): {}", t.author.handle, t.author.name, t.text);
    if let Some(q) = &t.quoted_tweet {
        s.push('\n');
        for line in q.text.lines() {
            s.push_str("> ");
            s.push_str(line);
            s.push('\n');
        }
    }
    truncate_on_char_boundary(&s, MAX_TEXT_CHARS).to_string()
}

fn truncate_on_char_boundary(s: &str, max_chars: usize) -> &str {
    match s.char_indices().nth(max_chars) {
        Some((idx, _)) => &s[..idx],
        None => s,
    }
}

pub fn parse_verdict(raw: &str) -> FilterDecision {
    for token in raw.split(|c: char| !c.is_ascii_alphabetic()) {
        if token.is_empty() {
            continue;
        }
        let upper = token.to_ascii_uppercase();
        if upper == "HIDE" {
            return FilterDecision::Hide;
        }
        if upper == "KEEP" {
            return FilterDecision::Keep;
        }
    }
    FilterDecision::Keep
}

pub struct FilterCache {
    conn: Connection,
    rubric_hash: String,
    mem: HashMap<String, FilterDecision>,
}

impl FilterCache {
    pub fn open(path: &Path, rubric_hash: String) -> Result<Self> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|e| Error::Config(format!("create filter cache dir: {e}")))?;
        }
        let conn =
            Connection::open(path).map_err(|e| Error::Config(format!("open filter.db: {e}")))?;
        conn.pragma_update(None, "journal_mode", "WAL")
            .map_err(|e| Error::Config(format!("set WAL: {e}")))?;
        conn.pragma_update(None, "synchronous", "NORMAL")
            .map_err(|e| Error::Config(format!("set sync: {e}")))?;
        conn.execute(
            "CREATE TABLE IF NOT EXISTS verdicts (
                tweet_id      TEXT NOT NULL,
                rubric_hash   TEXT NOT NULL,
                verdict       INTEGER NOT NULL,
                classified_at INTEGER NOT NULL,
                PRIMARY KEY (tweet_id, rubric_hash)
            )",
            [],
        )
        .map_err(|e| Error::Config(format!("create verdicts table: {e}")))?;
        let mut mem: HashMap<String, FilterDecision> = HashMap::new();
        {
            let mut stmt = conn
                .prepare("SELECT tweet_id, verdict FROM verdicts WHERE rubric_hash = ?1")
                .map_err(|e| Error::Config(format!("prepare load: {e}")))?;
            let rows = stmt
                .query_map(params![&rubric_hash], |row| {
                    let id: String = row.get(0)?;
                    let v: i64 = row.get(1)?;
                    let decision = if v == 1 {
                        FilterDecision::Hide
                    } else {
                        FilterDecision::Keep
                    };
                    Ok((id, decision))
                })
                .map_err(|e| Error::Config(format!("query verdicts: {e}")))?;
            for row in rows {
                let (id, decision) = row.map_err(|e| Error::Config(format!("row decode: {e}")))?;
                mem.insert(id, decision);
            }
        }
        debug!(
            rubric_hash = %rubric_hash,
            loaded = mem.len(),
            "filter cache opened",
        );
        Ok(Self {
            conn,
            rubric_hash,
            mem,
        })
    }

    pub fn get(&self, tweet_id: &str) -> Option<FilterDecision> {
        self.mem.get(tweet_id).copied()
    }

    pub fn put(&mut self, tweet_id: &str, decision: FilterDecision) {
        let verdict_int: i64 = match decision {
            FilterDecision::Keep => 0,
            FilterDecision::Hide => 1,
        };
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);
        if let Err(e) = self.conn.execute(
            "INSERT OR REPLACE INTO verdicts (tweet_id, rubric_hash, verdict, classified_at) VALUES (?1, ?2, ?3, ?4)",
            params![tweet_id, &self.rubric_hash, verdict_int, now],
        ) {
            warn!("filter cache put failed: {e}");
        }
        self.mem.insert(tweet_id.to_string(), decision);
    }

    #[cfg(test)]
    pub fn contains(&self, tweet_id: &str) -> bool {
        self.mem.contains_key(tweet_id)
    }
}

pub struct Classifier {
    http: reqwest::Client,
    ollama: OllamaConfig,
    sem: Arc<Semaphore>,
    system_prompt: Arc<String>,
}

#[derive(Debug, Clone)]
pub struct TweetPayload {
    pub rest_id: String,
    pub text: String,
}

impl Classifier {
    pub fn new(cfg: &FilterConfig) -> Self {
        let http = reqwest::Client::builder()
            .timeout(Duration::from_secs(cfg.ollama.timeout_seconds))
            .build()
            .unwrap_or_else(|_| reqwest::Client::new());
        Self {
            http,
            ollama: cfg.ollama.clone(),
            sem: Arc::new(Semaphore::new(2)),
            system_prompt: Arc::new(build_system_prompt(cfg)),
        }
    }

    pub async fn health_check(&self) -> Result<()> {
        let url = format!("{}/api/tags", self.ollama.host.trim_end_matches('/'));
        let resp = self
            .http
            .get(&url)
            .timeout(Duration::from_secs(2))
            .send()
            .await
            .map_err(|e| Error::Config(format!("ollama /api/tags: {e}")))?;
        if !resp.status().is_success() {
            return Err(Error::Config(format!("ollama status {}", resp.status())));
        }
        Ok(())
    }

    pub fn classify_async(&self, payload: TweetPayload, tx: EventTx) {
        let http = self.http.clone();
        let ollama = self.ollama.clone();
        let sem = self.sem.clone();
        let system_prompt = self.system_prompt.clone();
        tokio::spawn(async move {
            let _permit = sem.acquire_owned().await.ok();
            let started = std::time::Instant::now();
            let url = format!("{}/api/chat", ollama.host.trim_end_matches('/'));
            let body = serde_json::json!({
                "model": ollama.model,
                "messages": [
                    { "role": "system", "content": *system_prompt },
                    { "role": "user", "content": payload.text },
                ],
                "stream": false,
                "think": false,
                "options": { "temperature": 0, "num_predict": 3 },
            });
            debug!(
                rest_id = %payload.rest_id,
                text_len = payload.text.len(),
                "filter dispatch",
            );
            let verdict = match http.post(&url).json(&body).send().await {
                Ok(resp) if resp.status().is_success() => {
                    match resp.json::<OllamaChatResponse>().await {
                        Ok(r) => {
                            let parsed = parse_verdict(&r.message.content);
                            debug!(
                                rest_id = %payload.rest_id,
                                raw = %r.message.content,
                                parsed = ?parsed,
                                elapsed_ms = started.elapsed().as_millis() as u64,
                                "filter verdict",
                            );
                            parsed
                        }
                        Err(e) => {
                            warn!("filter parse failed for {}: {e}", payload.rest_id);
                            FilterDecision::Keep
                        }
                    }
                }
                Ok(resp) => {
                    warn!(
                        "filter http status {} for {}",
                        resp.status(),
                        payload.rest_id
                    );
                    FilterDecision::Keep
                }
                Err(e) => {
                    warn!("filter http error for {}: {e}", payload.rest_id);
                    FilterDecision::Keep
                }
            };
            let _ = tx.send(Event::TweetClassified {
                rest_id: payload.rest_id,
                verdict,
            });
        });
    }
}

#[derive(Debug, Deserialize)]
struct OllamaChatResponse {
    message: OllamaChatMessage,
}

#[derive(Debug, Deserialize)]
struct OllamaChatMessage {
    content: String,
}

pub fn translate_async(rest_id: String, text: String, ollama: OllamaConfig, tx: EventTx) {
    tokio::spawn(async move {
        let http = reqwest::Client::builder()
            .timeout(Duration::from_secs(ollama.timeout_seconds))
            .build()
            .unwrap_or_else(|_| reqwest::Client::new());
        let url = format!("{}/api/chat", ollama.host.trim_end_matches('/'));
        let body = serde_json::json!({
            "model": ollama.model,
            "messages": [
                { "role": "system", "content": "Translate the following to English. Output ONLY the translation, nothing else." },
                { "role": "user", "content": text },
            ],
            "stream": false,
            "think": false,
            "options": { "temperature": 0, "num_predict": 512 },
        });
        match http.post(&url).json(&body).send().await {
            Ok(resp) if resp.status().is_success() => {
                match resp.json::<OllamaChatResponse>().await {
                    Ok(r) => {
                        let translated = r.message.content.trim().to_string();
                        let _ = tx.send(Event::TweetTranslated {
                            rest_id,
                            translated,
                        });
                    }
                    Err(e) => {
                        warn!("translate parse failed for {rest_id}: {e}");
                    }
                }
            }
            Ok(resp) => {
                warn!("translate http status {} for {rest_id}", resp.status());
            }
            Err(e) => {
                warn!("translate http error for {rest_id}: {e}");
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{Media, User};
    use chrono::Utc;

    fn tweet(text: &str) -> Tweet {
        Tweet {
            rest_id: "1".into(),
            author: User {
                rest_id: "u".into(),
                handle: "alice".into(),
                name: "Alice".into(),
                verified: false,
                followers: 0,
                following: 0,
            },
            created_at: Utc::now(),
            text: text.into(),
            reply_count: 0,
            retweet_count: 0,
            like_count: 0,
            quote_count: 0,
            view_count: None,
            lang: None,
            in_reply_to_tweet_id: None,
            quoted_tweet: None,
            media: Vec::<Media>::new(),
            url: "https://x.com/alice/status/1".into(),
        }
    }

    fn cfg(topics: Vec<&str>, guidance: &str) -> FilterConfig {
        FilterConfig {
            drop_topics: topics.into_iter().map(String::from).collect(),
            extra_guidance: guidance.into(),
            ollama: OllamaConfig {
                model: "gemma4:latest".into(),
                host: "http://localhost:11434".into(),
                timeout_seconds: 20,
            },
        }
    }

    #[test]
    fn rubric_hash_stable_across_ordering() {
        let a = cfg(vec!["war", "politics", "gender"], "");
        let b = cfg(vec!["gender", "WAR", " politics "], "");
        assert_eq!(a.rubric_hash(), b.rubric_hash());
    }

    #[test]
    fn rubric_hash_changes_on_topic_edit() {
        let a = cfg(vec!["war"], "");
        let b = cfg(vec!["war", "politics"], "");
        assert_ne!(a.rubric_hash(), b.rubric_hash());
    }

    #[test]
    fn rubric_hash_changes_on_guidance_edit() {
        let a = cfg(vec!["war"], "keep humor");
        let b = cfg(vec!["war"], "hide everything");
        assert_ne!(a.rubric_hash(), b.rubric_hash());
    }

    #[test]
    fn parse_verdict_hide() {
        assert_eq!(parse_verdict("HIDE"), FilterDecision::Hide);
        assert_eq!(parse_verdict(" HIDE\n"), FilterDecision::Hide);
        assert_eq!(parse_verdict("hide"), FilterDecision::Hide);
        assert_eq!(parse_verdict("Answer: HIDE"), FilterDecision::Hide);
    }

    #[test]
    fn parse_verdict_keep() {
        assert_eq!(parse_verdict("KEEP"), FilterDecision::Keep);
        assert_eq!(parse_verdict("keep."), FilterDecision::Keep);
        assert_eq!(parse_verdict(" answer: keep"), FilterDecision::Keep);
    }

    #[test]
    fn parse_verdict_ambiguous_defaults_keep() {
        assert_eq!(parse_verdict(""), FilterDecision::Keep);
        assert_eq!(parse_verdict("???"), FilterDecision::Keep);
        assert_eq!(parse_verdict("yes"), FilterDecision::Keep);
    }

    #[test]
    fn build_classification_text_plain() {
        let t = tweet("hello world");
        assert_eq!(build_classification_text(&t), "@alice (Alice): hello world");
    }

    #[test]
    fn build_classification_text_merges_quote() {
        let mut t = tweet("my take");
        t.quoted_tweet = Some(Box::new(tweet("original post\nwith two lines")));
        let merged = build_classification_text(&t);
        assert!(merged.contains("> original post"));
        assert!(merged.contains("> with two lines"));
        assert!(merged.starts_with("@alice (Alice): my take"));
    }

    #[test]
    fn build_classification_text_truncates_on_char_boundary() {
        let long = "a".repeat(2_000);
        let t = tweet(&long);
        let out = build_classification_text(&t);
        assert_eq!(out.chars().count(), MAX_TEXT_CHARS);
        assert!(out.is_char_boundary(out.len()));
    }

    #[test]
    fn build_classification_text_multibyte_truncation() {
        let text: String = "日本語".repeat(300);
        let t = tweet(&text);
        let out = build_classification_text(&t);
        assert!(out.chars().count() <= MAX_TEXT_CHARS);
        assert!(out.is_char_boundary(out.len()));
    }

    #[test]
    fn default_content_roundtrips() {
        let parsed: FilterConfig = toml::from_str(FilterConfig::default_content()).unwrap();
        assert!(!parsed.drop_topics.is_empty());
        assert_eq!(parsed.ollama.model, "gemma4:latest");
        assert!(parsed.rubric_hash().chars().count() == 16);
    }

    #[test]
    fn system_prompt_has_topics() {
        let c = cfg(vec!["war", "politics"], "keep humor");
        let prompt = build_system_prompt(&c);
        assert!(prompt.contains("- war"));
        assert!(prompt.contains("- politics"));
        assert!(prompt.contains("keep humor"));
        assert!(prompt.contains("HIDE or KEEP"));
    }

    #[test]
    fn cache_roundtrip_isolates_by_rubric_hash() {
        let tmp = tempfile::NamedTempFile::new().unwrap();
        let path = tmp.path().to_path_buf();
        {
            let mut a = FilterCache::open(&path, "hash-a".into()).unwrap();
            a.put("tweet1", FilterDecision::Hide);
            a.put("tweet2", FilterDecision::Keep);
        }
        {
            let mut b = FilterCache::open(&path, "hash-b".into()).unwrap();
            b.put("tweet1", FilterDecision::Keep);
        }
        let reopened_a = FilterCache::open(&path, "hash-a".into()).unwrap();
        assert_eq!(reopened_a.get("tweet1"), Some(FilterDecision::Hide));
        assert_eq!(reopened_a.get("tweet2"), Some(FilterDecision::Keep));
        let reopened_b = FilterCache::open(&path, "hash-b".into()).unwrap();
        assert_eq!(reopened_b.get("tweet1"), Some(FilterDecision::Keep));
        assert!(!reopened_b.contains("tweet2"));
    }
}
