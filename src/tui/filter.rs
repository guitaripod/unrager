use crate::error::{Error, Result};
use crate::model::Tweet;
use crate::tui::event::{Event, EventTx};
use rusqlite::{Connection, params};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::path::Path;
use std::sync::{Arc, PoisonError, RwLock};
use std::time::Duration;
use tokio::sync::Semaphore;
use tracing::{debug, warn};

const DEFAULT_CONFIG: &str = include_str!("filter_default.toml");
const SYSTEM_TEMPLATE: &str = "HIDE or KEEP this tweet?

HIDE if it is about, or written by someone primarily known for, any of these topics:
{TOPICS}

ALSO HIDE, even if no topic above applies, when you would tap \"Not interested\", mute, block, or report the author after seeing this. Specifically:
- subtweets, vaguebooking, \"you know who you are\" callouts
- ratio bait, dunking, \"imagine being this person\" posts
- engagement farming: \"RT if you agree\", \"unpopular opinion: [bait]\", \"what is the most controversial...\"
- manufactured outrage with no information content beyond \"be mad\"
- doom-posting and vague moral panic with no specifics

KEEP technical, scientific, art, music, sports, personal-life, and humor tweets — including spicy opinions, frustration, trash talk, and sharp critique — as long as the post has actual content, not just an invitation to be angry.
{GUIDANCE}
When in doubt, HIDE.
One word answer:";

const PROMPT_VERSION: &str = "v2-mute-signals";
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
    /// `[llm]` in `filter.toml`; `[ollama]` (the pre-1.0 name) still loads.
    #[serde(alias = "ollama")]
    pub llm: LlmConfig,
}

/// Which local LLM server a `LlmConfig` talks to. Exactly one is active per
/// process, chosen once from `filter.toml` at startup — a small closed set
/// selected by data, not a plugin system needing runtime dispatch, hence a
/// plain enum rather than a trait (which would force `async fn` off plain
/// functions and boxed-future overhead for zero benefit here).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum LlmBackend {
    /// Ollama's native `/api/chat` API.
    #[default]
    Ollama,
    /// Any OpenAI-compatible `/v1/chat/completions` server: SGLang, vLLM,
    /// llama.cpp's `llama-server`, LM Studio, llama-swap, Ollama's `/v1`.
    OpenAi,
}

impl LlmBackend {
    /// The name `filter.toml` uses, stable across Rust renames (it feeds the
    /// rubric hash, so it must not drift).
    pub fn as_str(self) -> &'static str {
        match self {
            LlmBackend::Ollama => "ollama",
            LlmBackend::OpenAi => "openai",
        }
    }
}

#[derive(Clone, Serialize, Deserialize)]
pub struct LlmConfig {
    #[serde(default)]
    pub backend: LlmBackend,
    pub model: String,
    pub host: String,
    pub timeout_seconds: u64,
    /// Ollama-only model-residency control; never written into an
    /// OpenAI-compatible request body (those servers manage their own model
    /// lifecycle, e.g. llama-swap's `ttl`).
    #[serde(default = "default_keep_alive")]
    pub keep_alive: String,
    /// Sent as `Authorization: Bearer …` when set, for servers started with
    /// an API key (vLLM/llama-server `--api-key`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub api_key: Option<String>,
}

impl std::fmt::Debug for LlmConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("LlmConfig")
            .field("backend", &self.backend)
            .field("model", &self.model)
            .field("host", &self.host)
            .field("timeout_seconds", &self.timeout_seconds)
            .field("keep_alive", &self.keep_alive)
            .field("api_key", &self.api_key.as_ref().map(|_| "<redacted>"))
            .finish()
    }
}

fn default_keep_alive() -> String {
    "10s".to_string()
}

/// A backend-neutral chat request. `thinking` and `max_tokens` are translated
/// into whatever field names/shapes each backend's wire format actually uses
/// by `LlmConfig::build_body` — callers never see `think` vs
/// `chat_template_kwargs.enable_thinking`, or `num_predict` vs `max_tokens`.
#[derive(Debug, Clone)]
pub struct ChatRequest {
    pub messages: Vec<Value>,
    pub thinking: bool,
    pub temperature: f32,
    pub max_tokens: u32,
}

#[derive(Debug, Clone)]
pub struct ChatReply {
    pub content: String,
}

impl LlmConfig {
    pub fn chat_url(&self) -> String {
        let base = self.host.trim_end_matches('/');
        match self.backend {
            LlmBackend::Ollama => format!("{base}/api/chat"),
            LlmBackend::OpenAi => format!("{base}/v1/chat/completions"),
        }
    }

    fn models_url(&self) -> String {
        let base = self.host.trim_end_matches('/');
        match self.backend {
            LlmBackend::Ollama => format!("{base}/api/tags"),
            LlmBackend::OpenAi => format!("{base}/v1/models"),
        }
    }

    /// Vision (image-attached ask turns) stays Ollama-only: OpenAI-compatible
    /// servers disagree on multimodal message shapes and most local text
    /// models have no vision tower anyway.
    pub fn supports_vision(&self) -> bool {
        matches!(self.backend, LlmBackend::Ollama)
    }

    /// Applies the configured API key, if any.
    fn authorized(&self, request: reqwest::RequestBuilder) -> reqwest::RequestBuilder {
        match self.api_key.as_deref() {
            Some(key) if !key.is_empty() => request.bearer_auth(key),
            _ => request,
        }
    }

    pub fn build_client(&self) -> reqwest::Client {
        reqwest::Client::builder()
            .timeout(Duration::from_secs(self.timeout_seconds))
            .build()
            .unwrap_or_else(|_| reqwest::Client::new())
    }

    pub fn build_streaming_client(&self) -> reqwest::Client {
        reqwest::Client::builder()
            .timeout(Duration::from_secs(self.timeout_seconds.max(180)))
            .build()
            .unwrap_or_else(|_| reqwest::Client::new())
    }

    /// Build the wire body for `req`, backend-specific. Confirmed live against
    /// a real SGLang/Qwen3 server: `chat_template_kwargs` must be a top-level
    /// field (NOT nested under an `extra_body` wrapper — that's an
    /// OpenAI-Python-SDK-only client-side convention, not part of the wire
    /// format) for `enable_thinking` to actually take effect.
    fn build_body(&self, req: &ChatRequest, stream: bool) -> Value {
        match self.backend {
            LlmBackend::Ollama => serde_json::json!({
                "model": self.model,
                "messages": req.messages,
                "stream": stream,
                "think": req.thinking,
                "keep_alive": self.keep_alive,
                "options": { "temperature": req.temperature, "num_predict": req.max_tokens },
            }),
            LlmBackend::OpenAi => serde_json::json!({
                "model": self.model,
                "messages": req.messages,
                "stream": stream,
                "temperature": req.temperature,
                "max_tokens": req.max_tokens,
                "chat_template_kwargs": { "enable_thinking": req.thinking },
            }),
        }
    }

    /// One-shot, non-streaming chat call using a freshly built client (the
    /// configured `timeout_seconds`).
    pub async fn chat(&self, req: ChatRequest) -> std::result::Result<ChatReply, String> {
        let http = self.build_client();
        self.chat_with_client(req, &http).await
    }

    /// Same as `chat`, but against a caller-supplied client — used by
    /// `unrager doctor`'s generation smoke test, which needs a much longer
    /// timeout than normal classification traffic (a model that has to
    /// cold-load can take well over a minute to answer its first request).
    pub(crate) async fn chat_with_client(
        &self,
        req: ChatRequest,
        http: &reqwest::Client,
    ) -> std::result::Result<ChatReply, String> {
        let url = self.chat_url();
        let body = self.build_body(&req, false);
        let resp = self
            .authorized(http.post(&url))
            .json(&body)
            .send()
            .await
            .map_err(|e| format!("request failed: {e}"))?;
        let status = resp.status();
        if !status.is_success() {
            let preview = resp.text().await.unwrap_or_default();
            let trimmed: String = preview.chars().take(200).collect();
            return Err(format!("http {}: {trimmed}", status.as_u16()));
        }
        match self.backend {
            LlmBackend::Ollama => {
                let r: OllamaChatResponse = resp.json().await.map_err(|e| format!("parse: {e}"))?;
                Ok(ChatReply {
                    content: r.message.content,
                })
            }
            LlmBackend::OpenAi => {
                let r: OpenAiChatResponse = resp.json().await.map_err(|e| format!("parse: {e}"))?;
                let content = r
                    .choices
                    .into_iter()
                    .next()
                    .map(|c| c.message.content)
                    .unwrap_or_default();
                Ok(ChatReply { content })
            }
        }
    }

    pub async fn stream_chat(
        &self,
        req: ChatRequest,
        label: &str,
        on_token: impl FnMut(&str),
        on_thinking: impl FnMut(&str),
    ) -> std::result::Result<Option<String>, String> {
        let body = self.build_body(&req, true);
        match self.backend {
            LlmBackend::Ollama => self.stream_ndjson(body, label, on_token, on_thinking).await,
            LlmBackend::OpenAi => self.stream_sse(body, label, on_token, on_thinking).await,
        }
    }

    /// Ollama's native `/api/chat` streaming shape: one complete JSON object
    /// per line (NDJSON), terminated by a `"done": true` field.
    async fn stream_ndjson(
        &self,
        body: Value,
        label: &str,
        mut on_token: impl FnMut(&str),
        mut on_thinking: impl FnMut(&str),
    ) -> std::result::Result<Option<String>, String> {
        use futures::TryStreamExt;
        use tokio::io::AsyncBufReadExt;
        use tokio::io::BufReader;
        use tokio_util::io::StreamReader;

        let http = self.build_streaming_client();
        let url = self.chat_url();

        let response = self
            .authorized(http.post(&url))
            .json(&body)
            .send()
            .await
            .map_err(|e| format!("request failed: {e}"))?;

        let status = response.status();
        if !status.is_success() {
            let preview = response.text().await.unwrap_or_default();
            let trimmed: String = preview.chars().take(200).collect();
            tracing::warn!(label, status = status.as_u16(), body = %trimmed, "ollama http error");
            return Err(format!("http {}: {trimmed}", status.as_u16()));
        }

        let stream = response.bytes_stream().map_err(std::io::Error::other);
        let reader = StreamReader::new(stream);
        let mut lines = BufReader::new(reader).lines();
        let mut done_reason: Option<String> = None;

        loop {
            match lines.next_line().await {
                Ok(Some(line)) => {
                    if line.trim().is_empty() {
                        continue;
                    }
                    match serde_json::from_str::<Value>(&line) {
                        Ok(parsed) => {
                            if let Some(c) =
                                parsed.pointer("/message/content").and_then(|v| v.as_str())
                            {
                                if !c.is_empty() {
                                    on_token(c);
                                }
                            }
                            if let Some(t) =
                                parsed.pointer("/message/thinking").and_then(|v| v.as_str())
                            {
                                if !t.is_empty() {
                                    on_thinking(t);
                                }
                            }
                            if parsed.get("done").and_then(|v| v.as_bool()) == Some(true) {
                                done_reason = parsed
                                    .get("done_reason")
                                    .and_then(|v| v.as_str())
                                    .map(str::to_string);
                                break;
                            }
                        }
                        Err(e) => {
                            tracing::debug!(label, error = %e, "ollama json parse skip");
                        }
                    }
                }
                Ok(None) => break,
                Err(e) => {
                    return Err(format!("stream error: {e}"));
                }
            }
        }

        Ok(done_reason)
    }

    /// OpenAI-compatible streaming shape: Server-Sent Events, each
    /// chunk `data: {...}\n\n`, terminated by a literal `data: [DONE]` line.
    /// Confirmed live against a real SGLang server — content deltas can be
    /// empty strings mid-stream, and `finish_reason` arrives on the last
    /// content-bearing chunk rather than a separate empty one.
    async fn stream_sse(
        &self,
        body: Value,
        label: &str,
        mut on_token: impl FnMut(&str),
        mut on_thinking: impl FnMut(&str),
    ) -> std::result::Result<Option<String>, String> {
        use futures::TryStreamExt;
        use tokio::io::AsyncBufReadExt;
        use tokio::io::BufReader;
        use tokio_util::io::StreamReader;

        let http = self.build_streaming_client();
        let url = self.chat_url();

        let response = self
            .authorized(http.post(&url))
            .json(&body)
            .send()
            .await
            .map_err(|e| format!("request failed: {e}"))?;

        let status = response.status();
        if !status.is_success() {
            let preview = response.text().await.unwrap_or_default();
            let trimmed: String = preview.chars().take(200).collect();
            tracing::warn!(label, status = status.as_u16(), body = %trimmed, "openai-compatible http error");
            return Err(format!("http {}: {trimmed}", status.as_u16()));
        }

        let stream = response.bytes_stream().map_err(std::io::Error::other);
        let reader = StreamReader::new(stream);
        let mut lines = BufReader::new(reader).lines();
        let mut done_reason: Option<String> = None;

        loop {
            match lines.next_line().await {
                Ok(Some(line)) => match parse_sse_data_line(&line) {
                    SseLine::Token(t) => on_token(&t),
                    SseLine::Thinking(t) => on_thinking(&t),
                    SseLine::Done(reason) => {
                        done_reason = reason;
                        break;
                    }
                    SseLine::Ignore => {}
                },
                Ok(None) => break,
                Err(e) => {
                    return Err(format!("stream error: {e}"));
                }
            }
        }

        Ok(done_reason)
    }

    /// Whether `models` (a `list_models` result) includes the configured
    /// model. Ollama resolves an untagged name to `:latest`, so `gemma4`
    /// matches a listed `gemma4:latest`.
    pub fn is_served_by(&self, models: &[String]) -> bool {
        match self.backend {
            LlmBackend::Ollama => {
                let wanted = ollama_tagged(&self.model);
                models.iter().any(|m| ollama_tagged(m) == wanted)
            }
            LlmBackend::OpenAi => models.iter().any(|m| m == &self.model),
        }
    }

    /// List model names/ids the backend currently knows about. Ollama:
    /// `GET /api/tags` -> `{models:[{name}]}`. OpenAI-compatible:
    /// `GET /v1/models` -> `{data:[{id}]}`.
    pub async fn list_models(&self) -> std::result::Result<Vec<String>, String> {
        self.list_models_within(Duration::from_secs(5)).await
    }

    pub async fn list_models_within(
        &self,
        timeout: Duration,
    ) -> std::result::Result<Vec<String>, String> {
        let url = self.models_url();
        let resp = self
            .authorized(self.build_client().get(&url))
            .timeout(timeout)
            .send()
            .await
            .map_err(|e| format!("request failed: {e}"))?;
        if !resp.status().is_success() {
            return Err(format!("http {}", resp.status().as_u16()));
        }
        match self.backend {
            LlmBackend::Ollama => {
                let tags: OllamaTagsResponse =
                    resp.json().await.map_err(|e| format!("parse: {e}"))?;
                Ok(tags.models.into_iter().map(|m| m.name).collect())
            }
            LlmBackend::OpenAi => {
                let list: OpenAiModelsResponse =
                    resp.json().await.map_err(|e| format!("parse: {e}"))?;
                Ok(list.data.into_iter().map(|m| m.id).collect())
            }
        }
    }
}

/// One line's effect while parsing an OpenAI-compatible SSE chat stream.
#[derive(Debug, PartialEq)]
enum SseLine {
    Token(String),
    Thinking(String),
    Done(Option<String>),
    Ignore,
}

/// Pure parser for one raw line of an OpenAI-compatible SSE stream —
/// factored out of `stream_sse` so the trickiest new logic here is unit
/// testable without a live server.
fn parse_sse_data_line(line: &str) -> SseLine {
    let line = line.trim();
    if line.is_empty() {
        return SseLine::Ignore;
    }
    let Some(rest) = line.strip_prefix("data:") else {
        return SseLine::Ignore;
    };
    let rest = rest.trim();
    if rest == "[DONE]" {
        return SseLine::Done(None);
    }
    let Ok(parsed) = serde_json::from_str::<Value>(rest) else {
        return SseLine::Ignore;
    };
    if let Some(t) = parsed
        .pointer("/choices/0/delta/content")
        .and_then(|v| v.as_str())
    {
        if !t.is_empty() {
            return SseLine::Token(t.to_string());
        }
    }
    if let Some(t) = parsed
        .pointer("/choices/0/delta/reasoning_content")
        .and_then(|v| v.as_str())
    {
        if !t.is_empty() {
            return SseLine::Thinking(t.to_string());
        }
    }
    if let Some(reason) = parsed
        .pointer("/choices/0/finish_reason")
        .and_then(|v| v.as_str())
    {
        return SseLine::Done(Some(reason.to_string()));
    }
    SseLine::Ignore
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

    /// `raw` (the current `filter.toml`) with its rule keys replaced by this
    /// config's, one topic per line. Everything else in the file — comments,
    /// the `[llm]` table, keys this version doesn't know — survives an edit
    /// made from an app or the browser extension.
    pub fn write_rules_into(&self, raw: &str) -> Result<String> {
        let mut doc: toml_edit::DocumentMut = raw.parse().map_err(|e| {
            Error::Config(format!(
                "filter.toml doesn't parse, so it wasn't changed: {e}"
            ))
        })?;
        let mut topics = toml_edit::Array::new();
        for topic in &self.drop_topics {
            topics.push(topic.as_str());
        }
        for topic in topics.iter_mut() {
            topic.decor_mut().set_prefix("\n    ");
        }
        topics.set_trailing("\n");
        topics.set_trailing_comma(true);
        doc["drop_topics"] = toml_edit::value(topics);
        doc["extra_guidance"] = toml_edit::value(self.extra_guidance.as_str());
        Ok(doc.to_string())
    }

    /// Hashes the rubric AND the backend/model, so switching `[llm]
    /// backend`/`model` in `filter.toml` auto-invalidates cached verdicts
    /// instead of silently serving a different model's HIDE/KEEP calls as if
    /// the new one produced them. Uses the same invalidation mechanism as a
    /// rubric edit (orphaned rows, later swept by the retention prune) — no
    /// schema change, no explicit delete path.
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
        hasher.update(b"---\n");
        hasher.update(PROMPT_VERSION.as_bytes());
        hasher.update(b"---\n");
        hasher.update(self.llm.backend.as_str().as_bytes());
        hasher.update(b"\n");
        hasher.update(self.llm.model.as_bytes());
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

const RETENTION_DAYS: i64 = 7;

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
        prune_expired(&conn);
        let mem = load_verdicts(&conn, &rubric_hash)?;
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

    /// Switch this cache to a different rubric in place, reusing the
    /// already-open connection: drop the in-memory map, adopt the new hash,
    /// and reload whatever verdicts are already persisted under it. Much
    /// cheaper than `open` (no new connection, no schema DDL, no retention
    /// prune), so it's safe to call under a lock on a live rubric edit.
    pub fn rekey(&mut self, rubric_hash: String) -> Result<()> {
        if self.rubric_hash == rubric_hash {
            return Ok(());
        }
        let mem = load_verdicts(&self.conn, &rubric_hash)?;
        debug!(
            rubric_hash = %rubric_hash,
            loaded = mem.len(),
            "filter cache rekeyed",
        );
        self.rubric_hash = rubric_hash;
        self.mem = mem;
        Ok(())
    }

    pub fn get(&self, tweet_id: &str) -> Option<FilterDecision> {
        self.mem.get(tweet_id).copied()
    }

    pub fn rubric_hash(&self) -> &str {
        &self.rubric_hash
    }

    pub fn put(&mut self, tweet_id: &str, decision: FilterDecision) {
        self.put_many(&[(tweet_id, decision)]);
    }

    /// Persists verdicts in one transaction: a page of them costs one WAL
    /// commit, not one each. The in-memory map is updated even if the disk
    /// write fails, so the running process still benefits.
    pub fn put_many(&mut self, verdicts: &[(&str, FilterDecision)]) {
        if verdicts.is_empty() {
            return;
        }
        let now = unix_now();
        let written = self.conn.transaction().and_then(|tx| {
            {
                let mut insert = tx.prepare_cached(
                    "INSERT OR REPLACE INTO verdicts (tweet_id, rubric_hash, verdict, classified_at) VALUES (?1, ?2, ?3, ?4)",
                )?;
                for (tweet_id, decision) in verdicts {
                    let verdict_int: i64 = match decision {
                        FilterDecision::Keep => 0,
                        FilterDecision::Hide => 1,
                    };
                    insert.execute(params![tweet_id, &self.rubric_hash, verdict_int, now])?;
                }
            }
            tx.commit()
        });
        if let Err(e) = written {
            warn!("filter cache put failed: {e}");
        }
        for (tweet_id, decision) in verdicts {
            self.mem.insert((*tweet_id).to_string(), *decision);
        }
    }

    /// Persist a verdict only while `rubric_snapshot` still matches this
    /// cache's live rubric. A concurrent rubric edit rekeys the shared cache
    /// mid-request; writing under a stale snapshot would poison the new
    /// rubric's cache for the whole retention window. Shared by the SSE
    /// filter stream, the batch `/api/classify` route and the feed ingest.
    pub fn put_if_current_rubric(
        &mut self,
        rubric_snapshot: &str,
        tweet_id: &str,
        decision: FilterDecision,
    ) {
        self.put_many_if_current_rubric(rubric_snapshot, &[(tweet_id, decision)]);
    }

    /// [`put_if_current_rubric`](Self::put_if_current_rubric) for a batch.
    pub fn put_many_if_current_rubric(
        &mut self,
        rubric_snapshot: &str,
        verdicts: &[(&str, FilterDecision)],
    ) {
        if self.rubric_hash == rubric_snapshot {
            self.put_many(verdicts);
        }
    }

    /// Drops verdicts older than the retention window from disk and memory.
    /// `open` does this once; a process that stays up for weeks (the
    /// background server) calls it periodically so neither grows forever.
    pub fn prune(&mut self) -> Result<()> {
        if prune_expired(&self.conn) > 0 {
            self.mem = load_verdicts(&self.conn, &self.rubric_hash)?;
        }
        Ok(())
    }

    #[cfg(test)]
    pub fn contains(&self, tweet_id: &str) -> bool {
        self.mem.contains_key(tweet_id)
    }
}

fn unix_now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// Deletes verdicts past the retention window, returning how many went.
fn prune_expired(conn: &Connection) -> usize {
    let cutoff = unix_now() - RETENTION_DAYS * 86400;
    let pruned = conn
        .execute(
            "DELETE FROM verdicts WHERE classified_at < ?1",
            params![cutoff],
        )
        .unwrap_or(0);
    if pruned > 0 {
        tracing::info!(pruned, "filter.db: pruned old entries");
    }
    pruned
}

/// Load every persisted verdict for one rubric hash into a fresh in-memory
/// map. Shared by `FilterCache::open` and `FilterCache::rekey`.
fn load_verdicts(conn: &Connection, rubric_hash: &str) -> Result<HashMap<String, FilterDecision>> {
    let mut stmt = conn
        .prepare("SELECT tweet_id, verdict FROM verdicts WHERE rubric_hash = ?1")
        .map_err(|e| Error::Config(format!("prepare load: {e}")))?;
    let rows = stmt
        .query_map(params![rubric_hash], |row| {
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
    let mut mem = HashMap::new();
    for row in rows {
        let (id, decision) = row.map_err(|e| Error::Config(format!("row decode: {e}")))?;
        mem.insert(id, decision);
    }
    Ok(mem)
}

pub struct Classifier {
    http: reqwest::Client,
    llm: LlmConfig,
    sem: Arc<Semaphore>,
    system_prompt: Arc<RwLock<Arc<String>>>,
}

/// Grab the current system prompt out of the shared slot: an `Arc` clone,
/// not a copy of the multi-KB prompt string. Poisoning is impossible in
/// practice (writers only assign an `Arc`), but recover anyway rather than
/// panicking inside the classification path.
fn current_system_prompt(slot: &RwLock<Arc<String>>) -> Arc<String> {
    slot.read().unwrap_or_else(PoisonError::into_inner).clone()
}

#[derive(Debug, Clone)]
pub struct TweetPayload {
    pub rest_id: String,
    pub text: String,
}

impl Classifier {
    pub fn new(cfg: &FilterConfig) -> Self {
        Self {
            http: cfg.llm.build_client(),
            llm: cfg.llm.clone(),
            sem: Arc::new(Semaphore::new(8)),
            system_prompt: Arc::new(RwLock::new(Arc::new(build_system_prompt(cfg)))),
        }
    }

    /// Rebuild the classification system prompt from an edited config, in
    /// place. Every live `ClassifierHandle` shares the same prompt slot, so
    /// the background ingest worker and any in-flight handles pick up the
    /// new rubric on their next classification — no restart required.
    pub fn set_rubric(&self, cfg: &FilterConfig) {
        let prompt = Arc::new(build_system_prompt(cfg));
        *self
            .system_prompt
            .write()
            .unwrap_or_else(PoisonError::into_inner) = prompt;
    }

    pub async fn init(&mut self) -> Result<()> {
        let available = self
            .llm
            .list_models()
            .await
            .map_err(|e| Error::Config(format!("{} models: {e}", self.llm.backend.as_str())))?;
        match self.llm.backend {
            LlmBackend::Ollama => {
                if available.is_empty() {
                    return Err(Error::Config(
                        "ollama has no models installed (run `ollama pull gemma4`)".into(),
                    ));
                }
                if self.llm.is_served_by(&available) {
                    tracing::info!("filter using configured model {}", self.llm.model);
                    return Ok(());
                }
                let fallback = pick_fallback_model(&available).ok_or_else(|| {
                    Error::Config(
                        "no gemma4 model installed in ollama (run `ollama pull gemma4`)".into(),
                    )
                })?;
                tracing::warn!(
                    "configured model {:?} not installed; falling back to {:?}",
                    self.llm.model,
                    fallback
                );
                self.llm.model = fallback;
                Ok(())
            }
            LlmBackend::OpenAi => {
                if self.llm.is_served_by(&available) {
                    tracing::info!("filter using configured model {}", self.llm.model);
                    Ok(())
                } else {
                    Err(Error::Config(format!(
                        "configured model {:?} is not served at {} (available: {available:?})",
                        self.llm.model, self.llm.host
                    )))
                }
            }
        }
    }

    pub fn classify_async(&self, payload: TweetPayload, tx: EventTx) {
        let http = self.http.clone();
        let llm = self.llm.clone();
        let sem = self.sem.clone();
        let system_prompt = self.system_prompt.clone();
        tokio::spawn(async move {
            let _permit = sem.acquire_owned().await.ok();
            let prompt = current_system_prompt(&system_prompt);
            let verdict =
                classify_once(&http, &llm, &prompt, &payload.rest_id, &payload.text).await;
            let _ = tx.send(Event::TweetClassified {
                rest_id: payload.rest_id,
                verdict,
            });
        });
    }

    /// A cheaply-cloneable classification handle. The background ingest worker
    /// takes one (a brief lock, then released) so it can classify tweets
    /// awaitably without holding the shared `Classifier` mutex across requests —
    /// which would otherwise serialize and stall the interactive SSE filter.
    pub fn handle(&self) -> ClassifierHandle {
        ClassifierHandle {
            http: self.http.clone(),
            llm: self.llm.clone(),
            sem: self.sem.clone(),
            system_prompt: self.system_prompt.clone(),
        }
    }
}

#[derive(Clone)]
pub struct ClassifierHandle {
    http: reqwest::Client,
    llm: LlmConfig,
    sem: Arc<Semaphore>,
    system_prompt: Arc<RwLock<Arc<String>>>,
}

impl ClassifierHandle {
    /// Classify one tweet and return the verdict directly (no event channel).
    /// Shares the concurrency semaphore so it never overwhelms the backend.
    pub async fn classify(&self, rest_id: &str, text: &str) -> Option<FilterDecision> {
        let _permit = self.sem.acquire().await.ok();
        let prompt = current_system_prompt(&self.system_prompt);
        classify_once(&self.http, &self.llm, &prompt, rest_id, text).await
    }

    /// The backend this handle classifies with, including the model an
    /// Ollama fallback picked at init.
    pub fn llm(&self) -> &LlmConfig {
        &self.llm
    }

    #[cfg(test)]
    pub(crate) fn system_prompt_snapshot(&self) -> Arc<String> {
        current_system_prompt(&self.system_prompt)
    }

    /// Quick liveness probe so the ingest worker skips classification entirely
    /// (rather than eating a full timeout per tweet) when the backend is
    /// unreachable. Deliberately a cheap models-list GET for both backends,
    /// never a real generation — a cold model can take the better part of a minute
    /// to cold-start a model, which would make a "quick" probe anything but.
    pub async fn is_alive(&self) -> bool {
        let url = self.llm.models_url();
        matches!(
            self.llm.authorized(self.http.get(&url)).timeout(Duration::from_secs(2)).send().await,
            Ok(r) if r.status().is_success()
        )
    }
}

/// `None` when the backend never produced an answer (unreachable, timed out,
/// malformed reply). Callers show the tweet but must not cache anything: a
/// cold-loading model or a restart would otherwise pin a fake KEEP onto every
/// tweet in flight for the whole retention window.
async fn classify_once(
    http: &reqwest::Client,
    llm: &LlmConfig,
    system_prompt: &str,
    rest_id: &str,
    text: &str,
) -> Option<FilterDecision> {
    let started = std::time::Instant::now();
    let req = ChatRequest {
        messages: vec![
            serde_json::json!({ "role": "system", "content": system_prompt }),
            serde_json::json!({ "role": "user", "content": text }),
        ],
        thinking: false,
        temperature: 0.0,
        max_tokens: 3,
    };
    debug!(rest_id, text_len = text.len(), "filter dispatch");
    match llm.chat_with_client(req, http).await {
        Ok(reply) => {
            let parsed = parse_verdict(&reply.content);
            debug!(
                rest_id,
                raw = %reply.content,
                parsed = ?parsed,
                elapsed_ms = started.elapsed().as_millis() as u64,
                "filter verdict",
            );
            Some(parsed)
        }
        Err(e) => {
            warn!("filter classify failed for {rest_id}: {e}");
            None
        }
    }
}

#[derive(Debug, Deserialize)]
pub struct OllamaChatResponse {
    pub message: OllamaChatMessage,
}

#[derive(Debug, Deserialize)]
pub struct OllamaChatMessage {
    pub content: String,
}

#[derive(Debug, Deserialize)]
struct OllamaTagsResponse {
    #[serde(default)]
    models: Vec<OllamaTagsModel>,
}

#[derive(Debug, Deserialize)]
struct OllamaTagsModel {
    name: String,
}

#[derive(Debug, Deserialize)]
struct OpenAiChatResponse {
    #[serde(default)]
    choices: Vec<OpenAiChoice>,
}

#[derive(Debug, Deserialize)]
struct OpenAiChoice {
    message: OpenAiMessage,
}

#[derive(Debug, Deserialize)]
struct OpenAiMessage {
    #[serde(default)]
    content: String,
}

#[derive(Debug, Deserialize)]
struct OpenAiModelsResponse {
    #[serde(default)]
    data: Vec<OpenAiModelEntry>,
}

#[derive(Debug, Deserialize)]
struct OpenAiModelEntry {
    id: String,
}

fn ollama_tagged(name: &str) -> std::borrow::Cow<'_, str> {
    if name.contains(':') {
        std::borrow::Cow::Borrowed(name)
    } else {
        std::borrow::Cow::Owned(format!("{name}:latest"))
    }
}

fn pick_fallback_model(available: &[String]) -> Option<String> {
    available.iter().find(|n| n.starts_with("gemma4")).cloned()
}

pub fn translate_async(rest_id: String, text: String, llm: LlmConfig, tx: EventTx) {
    tokio::spawn(async move {
        let req = ChatRequest {
            messages: vec![
                serde_json::json!({ "role": "system", "content": "Translate the following to English. Output ONLY the translation, nothing else." }),
                serde_json::json!({ "role": "user", "content": text }),
            ],
            thinking: false,
            temperature: 0.0,
            max_tokens: 512,
        };
        match llm.chat(req).await {
            Ok(reply) => {
                let translated = reply.content.trim().to_string();
                let _ = tx.send(Event::TweetTranslated {
                    rest_id,
                    translated,
                });
            }
            Err(e) => {
                warn!("translate failed for {rest_id}: {e}");
                let _ = tx.send(Event::TweetTranslateFailed { rest_id, err: e });
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
                avatar_url: None,
                followed_by_me: None,
            },
            created_at: Utc::now(),
            text: text.into(),
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
            media: Vec::<Media>::new(),
            url: "https://x.com/alice/status/1".into(),
            urls: Vec::new(),
        }
    }

    fn ollama_cfg() -> LlmConfig {
        LlmConfig {
            backend: LlmBackend::Ollama,
            model: "gemma4:latest".into(),
            host: "http://localhost:11434".into(),
            timeout_seconds: 20,
            keep_alive: "30s".into(),
            api_key: None,
        }
    }

    fn openai_cfg() -> LlmConfig {
        LlmConfig {
            backend: LlmBackend::OpenAi,
            model: "qwen3".into(),
            host: "http://localhost:8081".into(),
            timeout_seconds: 20,
            keep_alive: "30s".into(),
            api_key: None,
        }
    }

    fn cfg(topics: Vec<&str>, guidance: &str) -> FilterConfig {
        FilterConfig {
            drop_topics: topics.into_iter().map(String::from).collect(),
            extra_guidance: guidance.into(),
            llm: ollama_cfg(),
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
    fn rubric_hash_changes_on_backend_change() {
        let mut a = cfg(vec!["war"], "");
        let mut b = a.clone();
        a.llm.backend = LlmBackend::Ollama;
        b.llm.backend = LlmBackend::OpenAi;
        assert_ne!(a.rubric_hash(), b.rubric_hash());
    }

    #[test]
    fn rubric_hash_changes_on_model_change() {
        let mut a = cfg(vec!["war"], "");
        let mut b = a.clone();
        a.llm.model = "gemma4:latest".into();
        b.llm.model = "gemma3:latest".into();
        assert_ne!(a.rubric_hash(), b.rubric_hash());
    }

    #[test]
    fn fallback_picks_gemma4_when_present() {
        let available = vec![
            "qwen3:7b".to_string(),
            "gemma4:e4b-it-q8_0".to_string(),
            "llama3.2:latest".to_string(),
        ];
        assert_eq!(
            pick_fallback_model(&available),
            Some("gemma4:e4b-it-q8_0".into())
        );
    }

    #[test]
    fn fallback_none_when_no_gemma4() {
        let available = vec!["qwen3:7b".to_string(), "llama3.2:latest".to_string()];
        assert_eq!(pick_fallback_model(&available), None);
    }

    #[test]
    fn fallback_none_when_empty() {
        assert_eq!(pick_fallback_model(&[]), None);
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
        assert_eq!(parsed.llm.model, "gemma4:latest");
        assert_eq!(parsed.llm.backend, LlmBackend::Ollama);
        assert!(parsed.rubric_hash().chars().count() == 16);
    }

    #[test]
    fn default_openai_example_parses_once_uncommented() {
        let example: String = DEFAULT_CONFIG
            .lines()
            .filter_map(|l| l.strip_prefix("#   "))
            .map(|l| l.split(" #").next().unwrap_or(l).trim_end())
            .filter(|l| !l.starts_with('#'))
            .collect::<Vec<_>>()
            .join("\n");
        let llm: LlmConfig = toml::from_str(&example).unwrap();
        assert_eq!(llm.backend, LlmBackend::OpenAi);
        assert_eq!(llm.timeout_seconds, 120);
    }

    #[test]
    fn writing_rules_keeps_comments_and_the_llm_table() {
        let mut edited: FilterConfig = toml::from_str(DEFAULT_CONFIG).unwrap();
        edited.drop_topics = vec!["war".into(), "tabs versus \"spaces\"".into()];
        edited.extra_guidance = "keep sports".into();
        let written = edited.write_rules_into(DEFAULT_CONFIG).unwrap();
        assert!(written.contains("# unrager's rules"));
        assert!(written.contains("# Any other server that speaks the OpenAI chat API"));
        assert!(written.contains("keep_alive = \"10s\""));
        assert!(
            written.contains("drop_topics = [\n    \"war\",\n    'tabs versus \"spaces\"',\n]")
        );
        let reparsed: FilterConfig = toml::from_str(&written).unwrap();
        assert_eq!(reparsed.drop_topics, edited.drop_topics);
        assert_eq!(reparsed.extra_guidance, "keep sports");
        assert_eq!(reparsed.llm.model, "gemma4:latest");
    }

    #[test]
    fn writing_rules_refuses_a_broken_file() {
        let cfg: FilterConfig = toml::from_str(DEFAULT_CONFIG).unwrap();
        assert!(cfg.write_rules_into("drop_topics = [").is_err());
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
    fn system_prompt_includes_negative_action_signals() {
        let prompt = build_system_prompt(&cfg(vec!["war"], ""));
        assert!(prompt.contains("Not interested"));
        assert!(prompt.contains("subtweets"));
        assert!(prompt.contains("ratio bait"));
        assert!(prompt.contains("engagement farming"));
    }

    #[test]
    fn rubric_hash_changes_when_prompt_version_changes() {
        let c = cfg(vec!["war"], "");
        let baseline = c.rubric_hash();
        let mut hasher = Sha256::new();
        hasher.update(b"war\n");
        hasher.update(b"---\n");
        hasher.update(b"");
        hasher.update(b"---\n");
        hasher.update(b"v1-different");
        hasher.update(b"---\n");
        hasher.update(b"ollama");
        hasher.update(b"\n");
        hasher.update(b"gemma4:latest");
        let alt = hex16(&hasher.finalize()[..8]);
        assert_ne!(baseline, alt);
    }

    #[test]
    fn set_rubric_propagates_to_existing_handles() {
        let classifier = Classifier::new(&cfg(vec!["war"], ""));
        let handle = classifier.handle();
        assert!(handle.system_prompt_snapshot().contains("- war"));
        assert!(!handle.system_prompt_snapshot().contains("- crypto"));
        classifier.set_rubric(&cfg(vec!["war", "crypto"], "keep humor"));
        let prompt = handle.system_prompt_snapshot();
        assert!(
            prompt.contains("- crypto") && prompt.contains("keep humor"),
            "a handle taken before the rubric edit must see the new prompt"
        );
    }

    #[test]
    fn cache_exposes_its_rubric_hash() {
        let tmp = tempfile::NamedTempFile::new().unwrap();
        let cache = FilterCache::open(tmp.path(), "hash-x".into()).unwrap();
        assert_eq!(cache.rubric_hash(), "hash-x");
    }

    #[test]
    fn prune_drops_expired_verdicts_from_disk_and_memory() {
        let tmp = tempfile::NamedTempFile::new().unwrap();
        let path = tmp.path().to_path_buf();
        let mut cache = FilterCache::open(&path, "r".into()).unwrap();
        cache.put_many(&[("old", FilterDecision::Hide), ("new", FilterDecision::Keep)]);
        cache
            .conn
            .execute(
                "UPDATE verdicts SET classified_at = 0 WHERE tweet_id = 'old'",
                [],
            )
            .unwrap();
        cache.prune().unwrap();
        assert!(cache.get("old").is_none());
        assert_eq!(cache.get("new"), Some(FilterDecision::Keep));
        let reopened = FilterCache::open(&path, "r".into()).unwrap();
        assert!(reopened.get("old").is_none());
        assert_eq!(reopened.get("new"), Some(FilterDecision::Keep));
    }

    #[test]
    fn put_many_persists_a_batch() {
        let tmp = tempfile::NamedTempFile::new().unwrap();
        let path = tmp.path().to_path_buf();
        {
            let mut cache = FilterCache::open(&path, "r".into()).unwrap();
            cache.put_many_if_current_rubric(
                "r",
                &[("1", FilterDecision::Hide), ("2", FilterDecision::Keep)],
            );
            cache.put_many_if_current_rubric("stale", &[("3", FilterDecision::Hide)]);
        }
        let reopened = FilterCache::open(&path, "r".into()).unwrap();
        assert_eq!(reopened.get("1"), Some(FilterDecision::Hide));
        assert_eq!(reopened.get("2"), Some(FilterDecision::Keep));
        assert!(reopened.get("3").is_none());
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

    #[test]
    fn rekey_switches_rubric_in_place() {
        let tmp = tempfile::NamedTempFile::new().unwrap();
        let path = tmp.path().to_path_buf();
        {
            let mut b = FilterCache::open(&path, "hash-b".into()).unwrap();
            b.put("tweet1", FilterDecision::Keep);
        }
        let mut cache = FilterCache::open(&path, "hash-a".into()).unwrap();
        cache.put("tweet1", FilterDecision::Hide);
        cache.put("tweet2", FilterDecision::Hide);
        cache.rekey("hash-b".into()).unwrap();
        assert_eq!(cache.rubric_hash(), "hash-b");
        assert_eq!(
            cache.get("tweet1"),
            Some(FilterDecision::Keep),
            "verdicts already persisted under the new hash are loaded"
        );
        assert!(
            !cache.contains("tweet2"),
            "old-rubric in-memory verdicts are dropped"
        );
        cache.put("tweet3", FilterDecision::Hide);
        let reopened_b = FilterCache::open(&path, "hash-b".into()).unwrap();
        assert_eq!(
            reopened_b.get("tweet3"),
            Some(FilterDecision::Hide),
            "post-rekey puts persist under the new hash"
        );
        let reopened_a = FilterCache::open(&path, "hash-a".into()).unwrap();
        assert!(!reopened_a.contains("tweet3"));
    }

    #[test]
    fn rekey_to_same_hash_is_a_noop() {
        let tmp = tempfile::NamedTempFile::new().unwrap();
        let mut cache = FilterCache::open(tmp.path(), "hash-a".into()).unwrap();
        cache.put("tweet1", FilterDecision::Hide);
        cache.rekey("hash-a".into()).unwrap();
        assert_eq!(cache.rubric_hash(), "hash-a");
        assert_eq!(cache.get("tweet1"), Some(FilterDecision::Hide));
    }

    #[test]
    fn put_if_current_rubric_persists_when_matching() {
        let tmp = tempfile::NamedTempFile::new().unwrap();
        let mut cache = FilterCache::open(tmp.path(), "hash-a".into()).unwrap();
        cache.put_if_current_rubric("hash-a", "tweet1", FilterDecision::Hide);
        assert_eq!(cache.get("tweet1"), Some(FilterDecision::Hide));
    }

    #[test]
    fn put_if_current_rubric_drops_when_stale() {
        let tmp = tempfile::NamedTempFile::new().unwrap();
        let mut cache = FilterCache::open(tmp.path(), "hash-a".into()).unwrap();
        cache.rekey("hash-b".into()).unwrap();
        cache.put_if_current_rubric("hash-a", "tweet1", FilterDecision::Hide);
        assert!(!cache.contains("tweet1"));
    }

    #[test]
    fn legacy_ollama_table_still_loads() {
        let parsed: FilterConfig = toml::from_str(
            "drop_topics = [\"war\"]\n[ollama]\nmodel = \"gemma4:latest\"\nhost = \"http://localhost:11434\"\ntimeout_seconds = 20\n",
        )
        .unwrap();
        assert_eq!(parsed.llm.backend, LlmBackend::Ollama);
        assert_eq!(parsed.llm.model, "gemma4:latest");
    }

    #[test]
    fn llm_table_selects_an_openai_compatible_server() {
        let parsed: FilterConfig = toml::from_str(
            "drop_topics = [\"war\"]\n[llm]\nbackend = \"openai\"\nmodel = \"qwen3\"\nhost = \"http://localhost:8000\"\ntimeout_seconds = 120\napi_key = \"sk-local\"\n",
        )
        .unwrap();
        assert_eq!(parsed.llm.backend, LlmBackend::OpenAi);
        assert_eq!(parsed.llm.api_key.as_deref(), Some("sk-local"));
        let written = toml::to_string_pretty(&parsed).unwrap();
        assert!(written.contains("[llm]") && written.contains("backend = \"openai\""));
    }

    #[test]
    fn api_key_is_sent_as_bearer_and_never_debug_printed() {
        let mut cfg = openai_cfg();
        cfg.api_key = Some("sk-secret".into());
        let request = cfg
            .authorized(reqwest::Client::new().get("http://localhost:8081/v1/models"))
            .build()
            .unwrap();
        assert_eq!(
            request.headers().get("authorization").unwrap(),
            "Bearer sk-secret"
        );
        assert!(!format!("{cfg:?}").contains("sk-secret"));
        let unkeyed = openai_cfg()
            .authorized(reqwest::Client::new().get("http://localhost:8081/v1/models"))
            .build()
            .unwrap();
        assert!(unkeyed.headers().get("authorization").is_none());
    }

    #[test]
    fn supports_vision_is_ollama_only() {
        assert!(ollama_cfg().supports_vision());
        assert!(!openai_cfg().supports_vision());
    }

    #[test]
    fn chat_url_dispatches_by_backend() {
        assert_eq!(ollama_cfg().chat_url(), "http://localhost:11434/api/chat");
        assert_eq!(
            openai_cfg().chat_url(),
            "http://localhost:8081/v1/chat/completions"
        );
    }

    #[test]
    fn models_url_dispatches_by_backend() {
        assert_eq!(ollama_cfg().models_url(), "http://localhost:11434/api/tags");
        assert_eq!(openai_cfg().models_url(), "http://localhost:8081/v1/models");
    }

    #[test]
    fn untagged_ollama_names_match_latest() {
        let listed = vec!["gemma4:latest".to_string(), "qwen3:8b".to_string()];
        let mut cfg = ollama_cfg();
        assert!(cfg.is_served_by(&listed));
        cfg.model = "gemma4".into();
        assert!(cfg.is_served_by(&listed));
        cfg.model = "qwen3".into();
        assert!(
            !cfg.is_served_by(&listed),
            "qwen3 means qwen3:latest, not qwen3:8b"
        );
        cfg.model = "qwen3:8b".into();
        assert!(cfg.is_served_by(&listed));
    }

    #[test]
    fn openai_model_ids_match_exactly() {
        let mut cfg = openai_cfg();
        assert!(cfg.is_served_by(&["qwen3".to_string()]));
        cfg.model = "qwen3:latest".into();
        assert!(!cfg.is_served_by(&["qwen3".to_string()]));
    }

    fn sample_request() -> ChatRequest {
        ChatRequest {
            messages: vec![serde_json::json!({"role": "user", "content": "hi"})],
            thinking: false,
            temperature: 0.0,
            max_tokens: 3,
        }
    }

    #[test]
    fn build_body_ollama_shape() {
        let body = ollama_cfg().build_body(&sample_request(), false);
        assert_eq!(body["model"], "gemma4:latest");
        assert_eq!(body["think"], false);
        assert_eq!(body["keep_alive"], "30s");
        assert_eq!(body["options"]["temperature"], 0.0);
        assert_eq!(body["options"]["num_predict"], 3);
        assert!(body.get("chat_template_kwargs").is_none());
    }

    #[test]
    fn build_body_openai_shape_puts_thinking_toggle_top_level() {
        // Confirmed against a real SGLang/Qwen3 server: this must be a
        // top-level `chat_template_kwargs` field, not nested under
        // `extra_body` (that's an OpenAI-Python-SDK client-side convention,
        // not part of the actual wire format).
        let mut req = sample_request();
        req.thinking = true;
        let body = openai_cfg().build_body(&req, true);
        assert_eq!(body["model"], "qwen3");
        assert_eq!(body["stream"], true);
        assert_eq!(body["max_tokens"], 3);
        assert_eq!(body["chat_template_kwargs"]["enable_thinking"], true);
        assert!(body.get("think").is_none());
        assert!(body.get("keep_alive").is_none());
        assert!(body.get("extra_body").is_none());
    }

    #[test]
    fn parse_sse_data_line_token() {
        let line = r#"data: {"choices":[{"delta":{"content":"hi","reasoning_content":null}}]}"#;
        assert_eq!(parse_sse_data_line(line), SseLine::Token("hi".into()));
    }

    #[test]
    fn parse_sse_data_line_thinking() {
        let line =
            r#"data: {"choices":[{"delta":{"content":"","reasoning_content":"pondering"}}]}"#;
        assert_eq!(
            parse_sse_data_line(line),
            SseLine::Thinking("pondering".into())
        );
    }

    #[test]
    fn parse_sse_data_line_empty_content_is_ignored() {
        let line = r#"data: {"choices":[{"delta":{"content":"","reasoning_content":null}}]}"#;
        assert_eq!(parse_sse_data_line(line), SseLine::Ignore);
    }

    #[test]
    fn parse_sse_data_line_finish_reason_is_done() {
        let line =
            r#"data: {"choices":[{"delta":{"reasoning_content":null},"finish_reason":"stop"}]}"#;
        assert_eq!(
            parse_sse_data_line(line),
            SseLine::Done(Some("stop".into()))
        );
    }

    #[test]
    fn parse_sse_data_line_done_sentinel() {
        assert_eq!(parse_sse_data_line("data: [DONE]"), SseLine::Done(None));
    }

    #[test]
    fn parse_sse_data_line_blank_and_non_data_lines_are_ignored() {
        assert_eq!(parse_sse_data_line(""), SseLine::Ignore);
        assert_eq!(parse_sse_data_line("   "), SseLine::Ignore);
        assert_eq!(parse_sse_data_line(": keep-alive comment"), SseLine::Ignore);
        assert_eq!(parse_sse_data_line("event: ping"), SseLine::Ignore);
    }

    #[test]
    fn parse_sse_data_line_malformed_json_is_ignored() {
        assert_eq!(parse_sse_data_line("data: not json"), SseLine::Ignore);
    }
}
