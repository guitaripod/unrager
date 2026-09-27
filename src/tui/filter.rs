use crate::error::{Error, Result};
use crate::model::Tweet;
use crate::tui::event::{Event, EventTx};
use rusqlite::{Connection, params};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError, RwLock};
use std::time::{Duration, Instant};
use tokio::sync::Semaphore;
use tracing::{debug, warn};

const DEFAULT_CONFIG: &str = include_str!("filter_default.toml");
const KEEP_RULE: &str = "KEEP technical, scientific, art, music, sports, personal-life, and humor posts — including spicy opinions, frustration, trash talk, and sharp critique — as long as the post has actual content, not just an invitation to be angry.";
const KEEP_UNCLEAR: &str =
    "KEEP short replies and posts with too little text to tell what they are about.";
const ANSWER_FORMAT: &str = "Answer KEEP, or HIDE followed by the number of the rule, like HIDE 3.";

/// Rules every rubric but a relaxed one carries after the user's topics, as
/// (what the model reads, the name a post hidden for it is labeled with).
const RAGE_BAIT_RULES: [(&str, &str); 5] = [
    (
        "subtweets, vaguebooking, \"you know who you are\" callouts",
        "subtweets and callouts",
    ),
    (
        "ratio bait, dunking, \"imagine being this person\" posts",
        "ratio bait and dunking",
    ),
    (
        "engagement farming: \"RT if you agree\", \"unpopular opinion: [bait]\", \"what is the most controversial...\"",
        "engagement farming",
    ),
    (
        "manufactured outrage with no information beyond \"be mad\"",
        "manufactured outrage",
    ),
    (
        "doom-posting and vague moral panic with no specifics",
        "doom-posting",
    ),
];

const PROMPT_VERSION: &str = "v3-numbered-rules";
const MAX_TEXT_CHARS: usize = 500;
/// Room for "HIDE 12" and whatever spacing the model puts around it.
const ANSWER_MAX_TOKENS: u32 = 8;
/// A model that answered this recently is still loaded, so a warm-up then
/// would only take a turn from real posts.
const WARM_FOR: Duration = Duration::from_secs(60);
/// What a warm-up asks the model to judge; its answer is thrown away.
const WARM_TEXT: &str = "Good morning.";

/// How readily the filter hides a post: `strictness` in `filter.toml`. It is
/// part of the rubric hash, so changing it checks every post again.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum Strictness {
    /// Only posts clearly about one of the user's topics.
    Relaxed,
    /// The user's topics plus the built-in rage-bait rules; a post the model
    /// isn't sure about stays.
    #[default]
    Balanced,
    /// Also posts by people known for a topic, and anything the model isn't
    /// sure about.
    Strict,
}

impl std::str::FromStr for Strictness {
    type Err = String;

    fn from_str(s: &str) -> std::result::Result<Self, Self::Err> {
        match s.trim().to_ascii_lowercase().as_str() {
            "relaxed" => Ok(Strictness::Relaxed),
            "balanced" => Ok(Strictness::Balanced),
            "strict" => Ok(Strictness::Strict),
            other => Err(format!("{other:?} isn't relaxed, balanced or strict")),
        }
    }
}

impl Strictness {
    /// The name `filter.toml` uses; it feeds the rubric hash, so it must not
    /// drift with Rust renames.
    pub fn as_str(self) -> &'static str {
        match self {
            Strictness::Relaxed => "relaxed",
            Strictness::Balanced => "balanced",
            Strictness::Strict => "strict",
        }
    }

    /// The line the numbered rules hang under.
    fn rules_intro(self) -> &'static str {
        match self {
            Strictness::Relaxed => {
                "HIDE a post only when one of these rules is clearly its main subject:"
            }
            Strictness::Balanced => "HIDE a post when one of these rules is its main point:",
            Strictness::Strict => {
                "HIDE a post when it is about one of these rules, or written by someone primarily known for one:"
            }
        }
    }

    fn when_in_doubt(self) -> &'static str {
        match self {
            Strictness::Strict => "When in doubt, HIDE.",
            Strictness::Relaxed | Strictness::Balanced => "When in doubt, KEEP.",
        }
    }
}

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

/// A verdict plus, for a HIDE, the rule the model said it broke.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Judgement {
    pub decision: FilterDecision,
    /// The rule's label as users see it: a topic's own text, or the short
    /// name of a built-in rule.
    pub reason: Option<Arc<str>>,
}

impl From<FilterDecision> for Judgement {
    fn from(decision: FilterDecision) -> Self {
        Self {
            decision,
            reason: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FilterConfig {
    pub drop_topics: Vec<String>,
    #[serde(default)]
    pub extra_guidance: String,
    #[serde(default)]
    pub strictness: Strictness,
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

/// The model a fresh `filter.toml` points Ollama at, and the one `doctor`
/// and `setup` tell people to pull.
pub const DEFAULT_OLLAMA_MODEL: &str = "qwen3:4b-instruct";

/// Installed Ollama models the filter falls back to, in order, when the
/// configured one isn't pulled: the default, then the default before it.
const FALLBACK_MODEL_PREFIXES: [&str; 2] = ["qwen3:4b-instruct", "gemma4"];

#[derive(Clone, Serialize, Deserialize)]
pub struct LlmConfig {
    #[serde(default)]
    pub backend: LlmBackend,
    pub model: String,
    /// The model the rage filter uses when it should differ from `model`:
    /// a small, fast one for judging posts, while ask, brief and translate
    /// keep a bigger one. Same server, same backend.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub filter_model: Option<String>,
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
            .field("filter_model", &self.filter_model)
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

    /// This config pointed at the filter's model: `filter_model` when set,
    /// `model` otherwise.
    pub fn for_filter(&self) -> LlmConfig {
        let mut filter = self.clone();
        if let Some(model) = self
            .filter_model
            .as_deref()
            .map(str::trim)
            .filter(|m| !m.is_empty())
        {
            filter.model = model.to_string();
        }
        filter.filter_model = None;
        filter
    }

    /// Whether ask can attach a post's photos. Only Ollama gets images
    /// (OpenAI-compatible servers disagree on multimodal message shapes), and
    /// only for a model whose `/api/show` lists vision, so a text-only model
    /// like the default isn't sent pictures it can't read.
    pub async fn sees_images(&self) -> bool {
        if !matches!(self.backend, LlmBackend::Ollama) {
            return false;
        }
        let url = format!("{}/api/show", self.host.trim_end_matches('/'));
        let shown = self
            .authorized(self.build_client().post(&url))
            .timeout(Duration::from_secs(5))
            .json(&serde_json::json!({ "model": self.model }))
            .send()
            .await;
        match shown {
            Ok(resp) => match resp.json::<Value>().await {
                Ok(body) => shows_vision(&body),
                Err(_) => false,
            },
            Err(_) => false,
        }
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
        doc["strictness"] = toml_edit::value(self.strictness.as_str());
        Ok(doc.to_string())
    }

    /// Hashes the rubric AND the backend and the filter's model (its
    /// `filter_model` when set), so switching either in `filter.toml`
    /// auto-invalidates cached verdicts
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
        hasher.update(self.strictness.as_str().as_bytes());
        hasher.update(b"---\n");
        hasher.update(self.llm.backend.as_str().as_bytes());
        hasher.update(b"\n");
        hasher.update(self.llm.for_filter().model.as_bytes());
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

/// The classifier's system prompt and the rules it numbers, so the rule an
/// answer like "HIDE 3" cites can be named back to the user.
#[derive(Debug)]
pub struct Rubric {
    prompt: String,
    labels: Vec<Arc<str>>,
}

impl Rubric {
    pub fn new(cfg: &FilterConfig) -> Self {
        let mut rules: Vec<(&str, &str)> = cfg
            .drop_topics
            .iter()
            .map(|t| t.trim())
            .filter(|t| !t.is_empty())
            .map(|t| (t, t))
            .collect();
        if cfg.strictness != Strictness::Relaxed {
            rules.extend(RAGE_BAIT_RULES);
        }
        let numbered = rules
            .iter()
            .enumerate()
            .map(|(i, (text, _))| format!("{}. {text}", i + 1))
            .collect::<Vec<_>>()
            .join("\n");
        let unclear = match cfg.strictness {
            Strictness::Strict => String::new(),
            Strictness::Relaxed | Strictness::Balanced => format!("\n{KEEP_UNCLEAR}"),
        };
        let guidance = match cfg.extra_guidance.trim() {
            "" => String::new(),
            g => format!("\n{g}"),
        };
        let prompt = format!(
            "Decide whether to HIDE or KEEP this post.\n\n{}\n{numbered}\n\n{KEEP_RULE}{unclear}{guidance}\n{}\n{ANSWER_FORMAT}",
            cfg.strictness.rules_intro(),
            cfg.strictness.when_in_doubt(),
        );
        Self {
            prompt,
            labels: rules
                .into_iter()
                .map(|(_, label)| Arc::from(label))
                .collect(),
        }
    }

    pub fn prompt(&self) -> &str {
        &self.prompt
    }

    /// Whether there is anything to hide for at all: a relaxed rubric with
    /// no topics has no rules.
    fn has_rules(&self) -> bool {
        !self.labels.is_empty()
    }

    /// The verdict in a model's answer, with the label of the rule a HIDE
    /// cites when the number is one of this rubric's.
    fn judge(&self, answer: &str) -> Judgement {
        let (decision, rule) = parse_answer(answer);
        let reason = rule
            .and_then(|n| n.checked_sub(1))
            .and_then(|i| self.labels.get(i))
            .cloned();
        Judgement { decision, reason }
    }
}

pub fn build_system_prompt(cfg: &FilterConfig) -> String {
    Rubric::new(cfg).prompt
}

/// The names of the built-in rage-bait rules, which every rubric but a
/// relaxed one numbers after the user's topics.
pub fn built_in_rule_labels() -> Vec<&'static str> {
    RAGE_BAIT_RULES.iter().map(|(_, label)| *label).collect()
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

/// [`parse_verdict`], plus the number a HIDE is followed by ("HIDE 3",
/// "HIDE: 12"), which is the rule it cites.
fn parse_answer(raw: &str) -> (FilterDecision, Option<usize>) {
    let decision = parse_verdict(raw);
    if decision == FilterDecision::Keep {
        return (decision, None);
    }
    let after_hide = raw
        .to_ascii_uppercase()
        .find("HIDE")
        .map_or(raw, |at| &raw[at + "HIDE".len()..]);
    let rule = after_hide
        .split(|c: char| !c.is_ascii_digit())
        .find(|digits| !digits.is_empty())
        .and_then(|digits| digits.parse().ok());
    (decision, rule)
}

const RETENTION_DAYS: i64 = 7;
/// A post the user showed or hid by hand stays that way this long; the
/// timeline has long moved on by then.
const OVERRIDE_RETENTION_DAYS: i64 = 90;

pub struct FilterCache {
    conn: Connection,
    rubric_hash: String,
    mem: HashMap<String, FilterDecision>,
    /// The rule behind each HIDE the model named one for.
    reasons: HashMap<String, Arc<str>>,
    /// Verdicts the user set on single posts. They outrank the model's and
    /// outlive rule changes.
    overrides: HashMap<String, FilterDecision>,
    /// The user's own posts: always kept, never judged, never stored.
    exempt: HashSet<String>,
    /// `PRAGMA data_version` when `overrides` was last read, so overrides
    /// another process set (the server, for the browser extension) show up.
    overrides_version: i64,
}

/// What the cache knows about one post.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CachedVerdict {
    pub decision: FilterDecision,
    /// The rule a model's HIDE cited.
    pub reason: Option<Arc<str>>,
    /// Set by the user rather than the model.
    pub overridden: bool,
}

impl From<Judgement> for CachedVerdict {
    fn from(judged: Judgement) -> Self {
        Self {
            decision: judged.decision,
            reason: judged.reason,
            overridden: false,
        }
    }
}

/// Counts over the verdicts made under the current rules.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct FilterStats {
    pub checked: u64,
    pub hidden: u64,
    /// Hidden posts per rule label, most first; `None` for HIDEs whose rule
    /// isn't known.
    pub hidden_by_reason: Vec<(Option<String>, u64)>,
    /// When the oldest of those verdicts was made, in unix seconds.
    pub since: Option<i64>,
    pub hidden_by_user: u64,
    pub shown_by_user: u64,
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
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS verdicts (
                tweet_id      TEXT NOT NULL,
                rubric_hash   TEXT NOT NULL,
                verdict       INTEGER NOT NULL,
                classified_at INTEGER NOT NULL,
                reason        TEXT,
                PRIMARY KEY (tweet_id, rubric_hash)
            );
            CREATE TABLE IF NOT EXISTS overrides (
                tweet_id TEXT PRIMARY KEY,
                verdict  INTEGER NOT NULL,
                set_at   INTEGER NOT NULL
            );",
        )
        .map_err(|e| Error::Config(format!("create filter tables: {e}")))?;
        ensure_reason_column(&conn)?;
        prune_expired(&conn);
        let (mem, reasons) = load_verdicts(&conn, &rubric_hash)?;
        let overrides = load_overrides(&conn)?;
        let overrides_version = data_version(&conn);
        debug!(
            rubric_hash = %rubric_hash,
            loaded = mem.len(),
            overrides = overrides.len(),
            "filter cache opened",
        );
        Ok(Self {
            conn,
            rubric_hash,
            mem,
            reasons,
            overrides,
            exempt: HashSet::new(),
            overrides_version,
        })
    }

    /// Switch this cache to a different rubric in place, reusing the
    /// already-open connection: drop the in-memory map, adopt the new hash,
    /// and reload whatever verdicts are already persisted under it. Much
    /// cheaper than `open` (no new connection, no schema DDL, no retention
    /// prune), so it's safe to call under a lock on a live rubric edit. The
    /// user's own verdicts don't depend on the rubric and stay.
    pub fn rekey(&mut self, rubric_hash: String) -> Result<()> {
        if self.rubric_hash == rubric_hash {
            return Ok(());
        }
        let (mem, reasons) = load_verdicts(&self.conn, &rubric_hash)?;
        debug!(
            rubric_hash = %rubric_hash,
            loaded = mem.len(),
            "filter cache rekeyed",
        );
        self.rubric_hash = rubric_hash;
        self.mem = mem;
        self.reasons = reasons;
        Ok(())
    }

    /// The verdict to act on: keep for the user's own posts, the user's own
    /// call on a post if they made one, else the model's under the current
    /// rules.
    pub fn get(&self, tweet_id: &str) -> Option<FilterDecision> {
        self.lookup(tweet_id).map(|v| v.decision)
    }

    /// [`get`](Self::get), with the rule behind a HIDE and who made the call.
    pub fn lookup(&self, tweet_id: &str) -> Option<CachedVerdict> {
        if self.exempt.contains(tweet_id) {
            return Some(CachedVerdict {
                decision: FilterDecision::Keep,
                reason: None,
                overridden: false,
            });
        }
        if let Some(&decision) = self.overrides.get(tweet_id) {
            return Some(CachedVerdict {
                decision,
                reason: None,
                overridden: true,
            });
        }
        let decision = *self.mem.get(tweet_id)?;
        Some(CachedVerdict {
            decision,
            reason: self.reasons.get(tweet_id).cloned(),
            overridden: false,
        })
    }

    pub fn rubric_hash(&self) -> &str {
        &self.rubric_hash
    }

    pub fn put(&mut self, tweet_id: &str, decision: FilterDecision) {
        self.put_many(&[(tweet_id, decision)]);
    }

    /// [`put_judgements`](Self::put_judgements) for verdicts without a rule.
    pub fn put_many(&mut self, verdicts: &[(&str, FilterDecision)]) {
        let judged: Vec<(&str, Judgement)> = verdicts
            .iter()
            .map(|(id, decision)| (*id, Judgement::from(*decision)))
            .collect();
        self.put_judgements(&judged);
    }

    /// Persists verdicts in one transaction: a page of them costs one WAL
    /// commit, not one each. The in-memory map is updated even if the disk
    /// write fails, so the running process still benefits.
    pub fn put_judgements(&mut self, judged: &[(&str, Judgement)]) {
        if judged.is_empty() {
            return;
        }
        let now = unix_now();
        let written = self.conn.transaction().and_then(|tx| {
            {
                let mut insert = tx.prepare_cached(
                    "INSERT OR REPLACE INTO verdicts (tweet_id, rubric_hash, verdict, classified_at, reason) VALUES (?1, ?2, ?3, ?4, ?5)",
                )?;
                for (tweet_id, j) in judged {
                    insert.execute(params![
                        tweet_id,
                        &self.rubric_hash,
                        verdict_int(j.decision),
                        now,
                        j.reason.as_deref()
                    ])?;
                }
            }
            tx.commit()
        });
        if let Err(e) = written {
            warn!("filter cache put failed: {e}");
        }
        for (tweet_id, j) in judged {
            self.mem.insert((*tweet_id).to_string(), j.decision);
            match &j.reason {
                Some(reason) => {
                    self.reasons.insert((*tweet_id).to_string(), reason.clone());
                }
                None => {
                    self.reasons.remove(*tweet_id);
                }
            }
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

    /// [`put_judgements`](Self::put_judgements), only while `rubric_snapshot`
    /// is still the live rubric (see
    /// [`put_if_current_rubric`](Self::put_if_current_rubric)).
    pub fn put_judgements_if_current_rubric(
        &mut self,
        rubric_snapshot: &str,
        judged: &[(&str, Judgement)],
    ) {
        if self.rubric_hash == rubric_snapshot {
            self.put_judgements(judged);
        }
    }

    /// Fills in a verdict read from elsewhere (the Home buffer) without
    /// writing it back: whoever made it already stored it, with its rule.
    pub fn seed(&mut self, tweet_id: &str, decision: FilterDecision) {
        self.mem.entry(tweet_id.to_string()).or_insert(decision);
    }

    /// Marks posts as the user's own: always kept, never judged or stored.
    pub fn exempt<'a>(&mut self, tweet_ids: impl IntoIterator<Item = &'a str>) {
        for id in tweet_ids {
            if !self.exempt.contains(id) {
                self.exempt.insert(id.to_string());
            }
        }
    }

    /// Records the user's own verdict on posts, or with `None` hands them
    /// back to the model. It outranks the model's and survives rule changes.
    pub fn set_override(
        &mut self,
        tweet_ids: &[&str],
        decision: Option<FilterDecision>,
    ) -> Result<()> {
        let now = unix_now();
        let tx = self
            .conn
            .transaction()
            .map_err(|e| Error::Config(format!("begin override: {e}")))?;
        {
            let (sql, verdict) = match decision {
                Some(d) => (
                    "INSERT OR REPLACE INTO overrides (tweet_id, verdict, set_at) VALUES (?1, ?2, ?3)",
                    verdict_int(d),
                ),
                None => ("DELETE FROM overrides WHERE tweet_id = ?1", 0),
            };
            let mut stmt = tx
                .prepare_cached(sql)
                .map_err(|e| Error::Config(format!("prepare override: {e}")))?;
            for id in tweet_ids {
                let written = if decision.is_some() {
                    stmt.execute(params![id, verdict, now])
                } else {
                    stmt.execute(params![id])
                };
                written.map_err(|e| Error::Config(format!("write override: {e}")))?;
            }
        }
        tx.commit()
            .map_err(|e| Error::Config(format!("commit override: {e}")))?;
        for id in tweet_ids {
            match decision {
                Some(d) => {
                    self.overrides.insert((*id).to_string(), d);
                }
                None => {
                    self.overrides.remove(*id);
                }
            }
        }
        Ok(())
    }

    /// Picks up overrides another process set since they were last read.
    /// One pragma when nothing changed, so it's cheap to call per page.
    pub fn refresh_overrides(&mut self) {
        let version = data_version(&self.conn);
        if version == self.overrides_version {
            return;
        }
        match load_overrides(&self.conn) {
            Ok(overrides) => {
                self.overrides = overrides;
                self.overrides_version = version;
            }
            Err(e) => warn!("filter overrides reload failed: {e}"),
        }
    }

    /// How many posts the current rules checked and hid, and for which rule.
    pub fn stats(&self) -> Result<FilterStats> {
        let db = |e: rusqlite::Error| Error::Config(format!("filter stats: {e}"));
        let (checked, hidden, since): (i64, Option<i64>, Option<i64>) = self
            .conn
            .query_row(
                "SELECT COUNT(*), SUM(verdict = 1), MIN(classified_at) FROM verdicts WHERE rubric_hash = ?1",
                params![self.rubric_hash],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .map_err(db)?;
        let mut stmt = self
            .conn
            .prepare(
                "SELECT reason, COUNT(*) FROM verdicts WHERE rubric_hash = ?1 AND verdict = 1
                 GROUP BY reason ORDER BY COUNT(*) DESC, reason",
            )
            .map_err(db)?;
        let hidden_by_reason = stmt
            .query_map(params![self.rubric_hash], |r| {
                Ok((r.get::<_, Option<String>>(0)?, r.get::<_, i64>(1)? as u64))
            })
            .map_err(db)?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(db)?;
        let hidden_by_user = self
            .overrides
            .values()
            .filter(|d| **d == FilterDecision::Hide)
            .count() as u64;
        Ok(FilterStats {
            checked: checked as u64,
            hidden: hidden.unwrap_or(0) as u64,
            hidden_by_reason,
            since,
            hidden_by_user,
            shown_by_user: self.overrides.len() as u64 - hidden_by_user,
        })
    }

    /// Drops verdicts and overrides older than their retention windows from
    /// disk and memory. `open` does this once; a process that stays up for
    /// weeks (the background server) calls it periodically so neither grows
    /// forever.
    pub fn prune(&mut self) -> Result<()> {
        if prune_expired(&self.conn) > 0 {
            let (mem, reasons) = load_verdicts(&self.conn, &self.rubric_hash)?;
            self.mem = mem;
            self.reasons = reasons;
            self.overrides = load_overrides(&self.conn)?;
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

fn verdict_int(decision: FilterDecision) -> i64 {
    match decision {
        FilterDecision::Keep => 0,
        FilterDecision::Hide => 1,
    }
}

fn decision_from_int(v: i64) -> FilterDecision {
    if v == 1 {
        FilterDecision::Hide
    } else {
        FilterDecision::Keep
    }
}

/// Bumped by SQLite whenever another connection commits to the database.
fn data_version(conn: &Connection) -> i64 {
    conn.query_row("PRAGMA data_version", [], |r| r.get(0))
        .unwrap_or(0)
}

/// Adds the `reason` column to a `filter.db` from before HIDEs named their
/// rule. Another process opening the file may add it first, which is fine.
fn ensure_reason_column(conn: &Connection) -> Result<()> {
    let has_reason = |conn: &Connection| {
        conn.prepare("SELECT 1 FROM pragma_table_info('verdicts') WHERE name = 'reason'")
            .and_then(|mut stmt| stmt.exists([]))
            .unwrap_or(false)
    };
    if has_reason(conn) {
        return Ok(());
    }
    match conn.execute("ALTER TABLE verdicts ADD COLUMN reason TEXT", []) {
        Ok(_) => Ok(()),
        Err(_) if has_reason(conn) => Ok(()),
        Err(e) => Err(Error::Config(format!("add filter.db reason column: {e}"))),
    }
}

/// Deletes verdicts and overrides past their retention windows, returning
/// how many rows went.
fn prune_expired(conn: &Connection) -> usize {
    let now = unix_now();
    let verdicts = conn
        .execute(
            "DELETE FROM verdicts WHERE classified_at < ?1",
            params![now - RETENTION_DAYS * 86400],
        )
        .unwrap_or(0);
    let overrides = conn
        .execute(
            "DELETE FROM overrides WHERE set_at < ?1",
            params![now - OVERRIDE_RETENTION_DAYS * 86400],
        )
        .unwrap_or(0);
    if verdicts + overrides > 0 {
        tracing::info!(verdicts, overrides, "filter.db: pruned old entries");
    }
    verdicts + overrides
}

/// Verdicts by post id, and the rule behind each HIDE that named one.
type LoadedVerdicts = (HashMap<String, FilterDecision>, HashMap<String, Arc<str>>);

/// Every persisted verdict for one rubric hash, and the rules behind its
/// HIDEs, with equal rule labels sharing one allocation. Shared by
/// `FilterCache::open` and `FilterCache::rekey`.
fn load_verdicts(conn: &Connection, rubric_hash: &str) -> Result<LoadedVerdicts> {
    let mut stmt = conn
        .prepare("SELECT tweet_id, verdict, reason FROM verdicts WHERE rubric_hash = ?1")
        .map_err(|e| Error::Config(format!("prepare load: {e}")))?;
    let rows = stmt
        .query_map(params![rubric_hash], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, i64>(1)?,
                row.get::<_, Option<String>>(2)?,
            ))
        })
        .map_err(|e| Error::Config(format!("query verdicts: {e}")))?;
    let mut mem = HashMap::new();
    let mut reasons = HashMap::new();
    let mut labels: HashMap<String, Arc<str>> = HashMap::new();
    for row in rows {
        let (id, verdict, reason) = row.map_err(|e| Error::Config(format!("row decode: {e}")))?;
        if let Some(reason) = reason {
            let label = labels
                .entry(reason)
                .or_insert_with_key(|r| Arc::from(r.as_str()))
                .clone();
            reasons.insert(id.clone(), label);
        }
        mem.insert(id, decision_from_int(verdict));
    }
    Ok((mem, reasons))
}

fn load_overrides(conn: &Connection) -> Result<HashMap<String, FilterDecision>> {
    let mut stmt = conn
        .prepare("SELECT tweet_id, verdict FROM overrides")
        .map_err(|e| Error::Config(format!("prepare overrides: {e}")))?;
    let rows = stmt
        .query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
        })
        .map_err(|e| Error::Config(format!("query overrides: {e}")))?;
    rows.map(|row| {
        row.map(|(id, v)| (id, decision_from_int(v)))
            .map_err(|e| Error::Config(format!("override decode: {e}")))
    })
    .collect()
}

pub struct Classifier {
    http: reqwest::Client,
    llm: LlmConfig,
    sem: Arc<Semaphore>,
    rubric: Arc<RwLock<Arc<Rubric>>>,
    warmth: Arc<Warmth>,
}

/// When the filter's model last answered, shared by the classifier and every
/// handle, and whether a warm-up is already on its way to it.
#[derive(Default)]
struct Warmth {
    answered_at: Mutex<Option<Instant>>,
    warming: AtomicBool,
}

impl Warmth {
    fn note(&self, answered: bool) {
        if answered {
            *self
                .answered_at
                .lock()
                .unwrap_or_else(PoisonError::into_inner) = Some(Instant::now());
        }
    }

    fn fresh(&self) -> bool {
        self.answered_at
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .is_some_and(|at| at.elapsed() < WARM_FOR)
    }
}

/// Clears `Warmth::warming` however the warm-up ends.
struct WarmingUp<'a>(&'a AtomicBool);

impl Drop for WarmingUp<'_> {
    fn drop(&mut self) {
        self.0.store(false, Ordering::Release);
    }
}

/// Grab the current rubric out of the shared slot: an `Arc` clone, not a
/// copy of the multi-KB prompt. Poisoning is impossible in practice (writers
/// only assign an `Arc`), but recover anyway rather than panicking inside the
/// classification path.
fn current_rubric(slot: &RwLock<Arc<Rubric>>) -> Arc<Rubric> {
    slot.read().unwrap_or_else(PoisonError::into_inner).clone()
}

#[derive(Debug, Clone)]
pub struct TweetPayload {
    pub rest_id: String,
    pub text: String,
}

impl Classifier {
    pub fn new(cfg: &FilterConfig) -> Self {
        let llm = cfg.llm.for_filter();
        Self {
            http: llm.build_client(),
            llm,
            sem: Arc::new(Semaphore::new(8)),
            rubric: Arc::new(RwLock::new(Arc::new(Rubric::new(cfg)))),
            warmth: Arc::default(),
        }
    }

    /// Rebuild the rubric from an edited config, in place. Every live
    /// `ClassifierHandle` shares the same slot, so the background ingest
    /// worker and any in-flight handles pick up the new rubric on their next
    /// classification — no restart required.
    pub fn set_rubric(&self, cfg: &FilterConfig) {
        let rubric = Arc::new(Rubric::new(cfg));
        *self.rubric.write().unwrap_or_else(PoisonError::into_inner) = rubric;
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
                    return Err(Error::Config(format!(
                        "ollama has no models installed (run `ollama pull {DEFAULT_OLLAMA_MODEL}`)"
                    )));
                }
                if self.llm.is_served_by(&available) {
                    tracing::info!("filter using configured model {}", self.llm.model);
                    return Ok(());
                }
                let fallback = pick_fallback_model(&available).ok_or_else(|| {
                    Error::Config(format!(
                        "{} isn't installed in ollama (run `ollama pull {}`)",
                        self.llm.model, self.llm.model
                    ))
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
        let rubric = self.rubric.clone();
        let warmth = self.warmth.clone();
        tokio::spawn(async move {
            let _permit = sem.acquire_owned().await.ok();
            let rubric = current_rubric(&rubric);
            let verdict =
                classify_once(&http, &llm, &rubric, &payload.rest_id, &payload.text).await;
            warmth.note(verdict.is_some());
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
            rubric: self.rubric.clone(),
            warmth: self.warmth.clone(),
        }
    }
}

#[derive(Clone)]
pub struct ClassifierHandle {
    http: reqwest::Client,
    llm: LlmConfig,
    sem: Arc<Semaphore>,
    rubric: Arc<RwLock<Arc<Rubric>>>,
    warmth: Arc<Warmth>,
}

impl ClassifierHandle {
    /// Classify one tweet and return the verdict directly (no event channel).
    /// Shares the concurrency semaphore so it never overwhelms the backend.
    pub async fn classify(&self, rest_id: &str, text: &str) -> Option<Judgement> {
        let _permit = self.sem.acquire().await.ok();
        let rubric = current_rubric(&self.rubric);
        let judged = classify_once(&self.http, &self.llm, &rubric, rest_id, text).await;
        self.warmth.note(judged.is_some());
        judged
    }

    /// Loads the model before the posts it's about to judge arrive, so they
    /// don't wait out a cold start: the browser extension asks as x.com
    /// opens and whenever X fetches a Home timeline. One short generation
    /// with the filter's own prompt, which also leaves that prompt in the
    /// model server's cache. Returns whether it asked; it doesn't when the
    /// model answered within `WARM_FOR`, a warm-up is already running, or
    /// there are no rules to judge by.
    pub async fn warm(&self) -> bool {
        let rubric = current_rubric(&self.rubric);
        if !rubric.has_rules()
            || self.warmth.fresh()
            || self.warmth.warming.swap(true, Ordering::AcqRel)
        {
            return false;
        }
        let _warming = WarmingUp(&self.warmth.warming);
        let _permit = self.sem.acquire().await.ok();
        let started = Instant::now();
        let req = ChatRequest {
            messages: vec![
                serde_json::json!({ "role": "system", "content": rubric.prompt() }),
                serde_json::json!({ "role": "user", "content": WARM_TEXT }),
            ],
            thinking: false,
            temperature: 0.0,
            max_tokens: 1,
        };
        match self.llm.chat_with_client(req, &self.http).await {
            Ok(_) => {
                self.warmth.note(true);
                tracing::info!(
                    model = %self.llm.model,
                    elapsed_ms = started.elapsed().as_millis() as u64,
                    "filter model warmed up"
                );
            }
            Err(e) => warn!("filter warm-up failed: {e}"),
        }
        true
    }

    /// The backend this handle classifies with, including the model an
    /// Ollama fallback picked at init.
    pub fn llm(&self) -> &LlmConfig {
        &self.llm
    }

    #[cfg(test)]
    pub(crate) fn system_prompt_snapshot(&self) -> String {
        current_rubric(&self.rubric).prompt().to_string()
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
/// tweet in flight for the whole retention window. A rubric with no rules
/// keeps everything without asking.
async fn classify_once(
    http: &reqwest::Client,
    llm: &LlmConfig,
    rubric: &Rubric,
    rest_id: &str,
    text: &str,
) -> Option<Judgement> {
    if !rubric.has_rules() {
        return Some(FilterDecision::Keep.into());
    }
    let started = std::time::Instant::now();
    let req = ChatRequest {
        messages: vec![
            serde_json::json!({ "role": "system", "content": rubric.prompt() }),
            serde_json::json!({ "role": "user", "content": text }),
        ],
        thinking: false,
        temperature: 0.0,
        max_tokens: ANSWER_MAX_TOKENS,
    };
    debug!(rest_id, text_len = text.len(), "filter dispatch");
    match llm.chat_with_client(req, http).await {
        Ok(reply) => {
            let judged = rubric.judge(&reply.content);
            debug!(
                rest_id,
                raw = %reply.content,
                parsed = ?judged.decision,
                reason = judged.reason.as_deref().unwrap_or(""),
                elapsed_ms = started.elapsed().as_millis() as u64,
                "filter verdict",
            );
            Some(judged)
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

/// Whether an Ollama `/api/show` body says the model reads images. An
/// Ollama too old to list capabilities is trusted to, as before it did.
fn shows_vision(show: &Value) -> bool {
    match show.get("capabilities").and_then(Value::as_array) {
        Some(capabilities) => capabilities.iter().any(|c| c.as_str() == Some("vision")),
        None => true,
    }
}

/// The installed model the filter falls back to when the configured one
/// isn't pulled, if any.
pub fn pick_fallback_model(available: &[String]) -> Option<String> {
    FALLBACK_MODEL_PREFIXES
        .iter()
        .find_map(|prefix| available.iter().find(|n| n.starts_with(prefix)).cloned())
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
            filter_model: None,
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
            filter_model: None,
        }
    }

    fn cfg(topics: Vec<&str>, guidance: &str) -> FilterConfig {
        FilterConfig {
            drop_topics: topics.into_iter().map(String::from).collect(),
            extra_guidance: guidance.into(),
            strictness: Default::default(),
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
        assert_eq!(parsed.llm.model, DEFAULT_OLLAMA_MODEL);
        assert_eq!(parsed.llm.filter_model, None);
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
        assert!(written.contains("keep_alive = \"30m\""));
        assert!(
            written.contains("drop_topics = [\n    \"war\",\n    'tabs versus \"spaces\"',\n]")
        );
        let reparsed: FilterConfig = toml::from_str(&written).unwrap();
        assert_eq!(reparsed.drop_topics, edited.drop_topics);
        assert_eq!(reparsed.extra_guidance, "keep sports");
        assert_eq!(reparsed.llm.model, DEFAULT_OLLAMA_MODEL);
    }

    #[test]
    fn writing_rules_refuses_a_broken_file() {
        let cfg: FilterConfig = toml::from_str(DEFAULT_CONFIG).unwrap();
        assert!(cfg.write_rules_into("drop_topics = [").is_err());
    }

    #[test]
    fn system_prompt_numbers_the_topics() {
        let c = cfg(vec!["war", " ", "politics"], "keep humor");
        let prompt = build_system_prompt(&c);
        assert!(prompt.contains("\n1. war\n2. politics\n"), "{prompt}");
        assert!(prompt.contains("keep humor"));
        assert!(prompt.contains("HIDE or KEEP"));
        assert!(prompt.ends_with("like HIDE 3."));
    }

    #[test]
    fn balanced_adds_the_rage_bait_rules_and_keeps_what_it_is_unsure_of() {
        let prompt = build_system_prompt(&cfg(vec!["war"], ""));
        assert!(prompt.contains("\n2. subtweets"));
        assert!(prompt.contains("ratio bait"));
        assert!(prompt.contains("\n4. engagement farming"));
        assert!(prompt.contains("KEEP short replies"));
        assert!(prompt.contains("When in doubt, KEEP."));
        assert!(!prompt.contains("primarily known"));
    }

    #[test]
    fn relaxed_asks_about_the_topics_alone() {
        let mut c = cfg(vec!["war"], "");
        c.strictness = Strictness::Relaxed;
        let prompt = build_system_prompt(&c);
        assert!(
            prompt.contains("clearly its main subject:\n1. war\n\n"),
            "{prompt}"
        );
        assert!(!prompt.contains("subtweets"));
        assert!(prompt.contains("When in doubt, KEEP."));
    }

    #[test]
    fn strict_hides_what_it_is_unsure_of_and_judges_authors() {
        let mut c = cfg(vec!["war"], "");
        c.strictness = Strictness::Strict;
        let prompt = build_system_prompt(&c);
        assert!(prompt.contains("written by someone primarily known for one"));
        assert!(prompt.contains("subtweets"));
        assert!(!prompt.contains("KEEP short replies"));
        assert!(prompt.contains("When in doubt, HIDE."));
    }

    #[test]
    fn rubric_hash_changes_with_strictness() {
        let a = cfg(vec!["war"], "");
        let mut b = a.clone();
        b.strictness = Strictness::Strict;
        assert_ne!(a.rubric_hash(), b.rubric_hash());
    }

    #[test]
    fn strictness_defaults_to_balanced_and_is_written_back() {
        let older: String = DEFAULT_CONFIG
            .lines()
            .filter(|l| !l.starts_with("strictness"))
            .collect::<Vec<_>>()
            .join("\n");
        let parsed: FilterConfig = toml::from_str(&older).unwrap();
        assert_eq!(parsed.strictness, Strictness::Balanced);
        let mut edited = parsed.clone();
        edited.strictness = Strictness::Relaxed;
        let written = edited.write_rules_into(&older).unwrap();
        let reparsed: FilterConfig = toml::from_str(&written).unwrap();
        assert_eq!(reparsed.strictness, Strictness::Relaxed);
        assert!(
            written.find("strictness =").unwrap() < written.find("[llm]").unwrap(),
            "the key stays with the rules, not inside [llm]"
        );
        let default: FilterConfig = toml::from_str(DEFAULT_CONFIG).unwrap();
        assert_eq!(default.strictness, Strictness::Balanced);
    }

    #[test]
    fn answers_name_the_rule_they_cite() {
        assert_eq!(parse_answer("HIDE 3"), (FilterDecision::Hide, Some(3)));
        assert_eq!(parse_answer("HIDE: 12\n"), (FilterDecision::Hide, Some(12)));
        assert_eq!(
            parse_answer("hide (rule 4)"),
            (FilterDecision::Hide, Some(4))
        );
        assert_eq!(parse_answer("HIDE"), (FilterDecision::Hide, None));
        assert_eq!(parse_answer("KEEP"), (FilterDecision::Keep, None));
        assert_eq!(parse_answer("KEEP 3"), (FilterDecision::Keep, None));
    }

    #[test]
    fn a_rule_number_maps_to_its_label() {
        let rubric = Rubric::new(&cfg(vec!["war", "politics"], ""));
        let label = |answer: &str| rubric.judge(answer).reason.map(|r| r.to_string());
        assert_eq!(label("HIDE 2").as_deref(), Some("politics"));
        assert_eq!(label("HIDE 5").as_deref(), Some("engagement farming"));
        assert_eq!(label("HIDE 0"), None);
        assert_eq!(label("HIDE 8"), None);
        assert_eq!(label("HIDE"), None);
        assert_eq!(rubric.judge("HIDE 9").decision, FilterDecision::Hide);
    }

    #[tokio::test]
    async fn a_rubric_with_no_rules_keeps_everything_without_asking() {
        let mut c = cfg(vec![], "");
        c.strictness = Strictness::Relaxed;
        c.llm.host = "http://127.0.0.1:9".into();
        let judged = Classifier::new(&c).handle().classify("1", "anything").await;
        assert_eq!(judged, Some(FilterDecision::Keep.into()));
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
        assert!(handle.system_prompt_snapshot().contains("1. war"));
        assert!(!handle.system_prompt_snapshot().contains("crypto"));
        classifier.set_rubric(&cfg(vec!["war", "crypto"], "keep humor"));
        let prompt = handle.system_prompt_snapshot();
        assert!(
            prompt.contains("2. crypto") && prompt.contains("keep humor"),
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

    fn judged(decision: FilterDecision, reason: &str) -> Judgement {
        Judgement {
            decision,
            reason: Some(Arc::from(reason)),
        }
    }

    #[test]
    fn the_rule_behind_a_hide_survives_a_reopen() {
        let tmp = tempfile::NamedTempFile::new().unwrap();
        {
            let mut cache = FilterCache::open(tmp.path(), "r".into()).unwrap();
            cache.put_judgements(&[
                ("1", judged(FilterDecision::Hide, "war")),
                ("2", FilterDecision::Keep.into()),
            ]);
        }
        let cache = FilterCache::open(tmp.path(), "r".into()).unwrap();
        let hidden = cache.lookup("1").unwrap();
        assert_eq!(hidden.decision, FilterDecision::Hide);
        assert_eq!(hidden.reason.as_deref(), Some("war"));
        assert!(!hidden.overridden);
        assert_eq!(cache.lookup("2").unwrap().reason, None);
    }

    #[test]
    fn a_filter_db_from_before_reasons_gains_the_column() {
        let tmp = tempfile::NamedTempFile::new().unwrap();
        {
            let conn = Connection::open(tmp.path()).unwrap();
            conn.execute_batch(
                "CREATE TABLE verdicts (
                    tweet_id TEXT NOT NULL, rubric_hash TEXT NOT NULL,
                    verdict INTEGER NOT NULL, classified_at INTEGER NOT NULL,
                    PRIMARY KEY (tweet_id, rubric_hash));",
            )
            .unwrap();
            conn.execute(
                "INSERT INTO verdicts VALUES ('old', 'r', 1, ?1)",
                params![unix_now()],
            )
            .unwrap();
        }
        let mut cache = FilterCache::open(tmp.path(), "r".into()).unwrap();
        assert_eq!(cache.get("old"), Some(FilterDecision::Hide));
        cache.put_judgements(&[("new", judged(FilterDecision::Hide, "war"))]);
        let reopened = FilterCache::open(tmp.path(), "r".into()).unwrap();
        assert_eq!(
            reopened.lookup("new").unwrap().reason.as_deref(),
            Some("war")
        );
    }

    #[test]
    fn opening_waits_for_another_process_writing_instead_of_failing() {
        let tmp = tempfile::NamedTempFile::new().unwrap();
        let path = tmp.path().to_path_buf();
        {
            let conn = Connection::open(&path).unwrap();
            conn.execute_batch(
                "PRAGMA journal_mode = WAL;
                CREATE TABLE verdicts (
                    tweet_id TEXT NOT NULL, rubric_hash TEXT NOT NULL,
                    verdict INTEGER NOT NULL, classified_at INTEGER NOT NULL,
                    PRIMARY KEY (tweet_id, rubric_hash));",
            )
            .unwrap();
        }
        let (locked_tx, locked) = std::sync::mpsc::channel();
        let writer = {
            let path = path.clone();
            std::thread::spawn(move || {
                let conn = Connection::open(&path).unwrap();
                conn.execute_batch("BEGIN IMMEDIATE").unwrap();
                locked_tx.send(()).unwrap();
                std::thread::sleep(Duration::from_millis(300));
                conn.execute_batch("COMMIT").unwrap();
            })
        };
        locked.recv().unwrap();

        let opened = FilterCache::open(&path, "r".into());
        writer.join().unwrap();

        assert!(opened.is_ok(), "{:?}", opened.err());
    }

    #[test]
    fn the_users_own_call_outranks_the_model_and_outlives_rule_changes() {
        let tmp = tempfile::NamedTempFile::new().unwrap();
        let mut cache = FilterCache::open(tmp.path(), "a".into()).unwrap();
        cache.put_judgements(&[("1", judged(FilterDecision::Hide, "war"))]);
        cache
            .set_override(&["1"], Some(FilterDecision::Keep))
            .unwrap();
        cache
            .set_override(&["2"], Some(FilterDecision::Hide))
            .unwrap();
        let shown = cache.lookup("1").unwrap();
        assert_eq!(
            (shown.decision, shown.overridden),
            (FilterDecision::Keep, true)
        );
        assert_eq!(shown.reason, None);

        cache.rekey("b".into()).unwrap();
        assert_eq!(cache.get("1"), Some(FilterDecision::Keep));
        assert_eq!(cache.get("2"), Some(FilterDecision::Hide));

        cache.set_override(&["1"], None).unwrap();
        assert_eq!(
            cache.get("1"),
            None,
            "handed back to the model, unjudged under b"
        );
        let reopened = FilterCache::open(tmp.path(), "a".into()).unwrap();
        assert_eq!(reopened.lookup("1").unwrap().reason.as_deref(), Some("war"));
        assert!(reopened.lookup("2").unwrap().overridden);
    }

    #[test]
    fn overrides_set_by_another_process_are_picked_up() {
        let tmp = tempfile::NamedTempFile::new().unwrap();
        let mut tui = FilterCache::open(tmp.path(), "r".into()).unwrap();
        tui.put("1", FilterDecision::Hide);
        let mut server = FilterCache::open(tmp.path(), "r".into()).unwrap();
        server
            .set_override(&["1"], Some(FilterDecision::Keep))
            .unwrap();
        assert_eq!(tui.get("1"), Some(FilterDecision::Hide));
        tui.refresh_overrides();
        assert_eq!(tui.get("1"), Some(FilterDecision::Keep));
    }

    #[test]
    fn the_users_own_posts_are_always_kept_and_never_stored() {
        let tmp = tempfile::NamedTempFile::new().unwrap();
        let mut cache = FilterCache::open(tmp.path(), "r".into()).unwrap();
        cache.put("mine", FilterDecision::Hide);
        cache.exempt(["mine", "also-mine"]);
        assert_eq!(cache.get("mine"), Some(FilterDecision::Keep));
        assert_eq!(cache.get("also-mine"), Some(FilterDecision::Keep));
        assert!(!cache.contains("also-mine"));
    }

    #[test]
    fn seeding_fills_gaps_without_overwriting_or_writing() {
        let tmp = tempfile::NamedTempFile::new().unwrap();
        let mut cache = FilterCache::open(tmp.path(), "r".into()).unwrap();
        cache.put_judgements(&[("1", judged(FilterDecision::Hide, "war"))]);
        cache.seed("1", FilterDecision::Keep);
        cache.seed("2", FilterDecision::Hide);
        assert_eq!(cache.lookup("1").unwrap().reason.as_deref(), Some("war"));
        assert_eq!(cache.get("2"), Some(FilterDecision::Hide));
        let reopened = FilterCache::open(tmp.path(), "r".into()).unwrap();
        assert!(!reopened.contains("2"));
    }

    #[test]
    fn stats_count_hides_per_rule_under_the_current_rubric() {
        let tmp = tempfile::NamedTempFile::new().unwrap();
        let mut cache = FilterCache::open(tmp.path(), "old".into()).unwrap();
        cache.put_judgements(&[("0", judged(FilterDecision::Hide, "war"))]);
        cache.rekey("new".into()).unwrap();
        cache.put_judgements(&[
            ("1", judged(FilterDecision::Hide, "war")),
            ("2", judged(FilterDecision::Hide, "war")),
            ("3", judged(FilterDecision::Hide, "doom-posting")),
            ("4", FilterDecision::Hide.into()),
            ("5", FilterDecision::Keep.into()),
        ]);
        cache
            .set_override(&["6"], Some(FilterDecision::Hide))
            .unwrap();
        cache
            .set_override(&["7", "8"], Some(FilterDecision::Keep))
            .unwrap();
        let stats = cache.stats().unwrap();
        assert_eq!((stats.checked, stats.hidden), (5, 4));
        assert_eq!(
            stats.hidden_by_reason,
            vec![
                (Some("war".to_string()), 2),
                (None, 1),
                (Some("doom-posting".to_string()), 1),
            ]
        );
        assert!(stats.since.is_some());
        assert_eq!((stats.hidden_by_user, stats.shown_by_user), (1, 2));
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

    #[tokio::test]
    async fn only_ollama_models_that_list_vision_get_images() {
        assert!(!openai_cfg().sees_images().await);
        assert!(shows_vision(
            &serde_json::json!({ "capabilities": ["completion", "vision"] })
        ));
        assert!(!shows_vision(
            &serde_json::json!({ "capabilities": ["completion"] })
        ));
        assert!(shows_vision(&serde_json::json!({ "template": "…" })));
    }

    #[test]
    fn the_filter_can_run_its_own_model() {
        let mut c = cfg(vec!["war"], "");
        let shared = c.rubric_hash();
        assert_eq!(c.llm.for_filter().model, "gemma4:latest");
        c.llm.filter_model = Some("qwen3:4b-instruct".into());
        assert_eq!(c.llm.for_filter().model, "qwen3:4b-instruct");
        assert_eq!(c.llm.for_filter().filter_model, None);
        assert_ne!(
            c.rubric_hash(),
            shared,
            "the filter's model is part of the rubric"
        );
        let filtering = c.rubric_hash();
        c.llm.model = "big-model".into();
        assert_eq!(
            c.rubric_hash(),
            filtering,
            "the ask/brief model doesn't touch cached verdicts"
        );
        c.llm.filter_model = Some("  ".into());
        assert_eq!(c.llm.for_filter().model, "big-model");
        let classifier = Classifier::new(&cfg_with_filter_model());
        assert_eq!(classifier.handle().llm().model, "small");
    }

    fn cfg_with_filter_model() -> FilterConfig {
        let mut c = cfg(vec!["war"], "");
        c.llm.filter_model = Some("small".into());
        c
    }

    #[test]
    fn fallback_prefers_the_default_model() {
        let available = vec![
            "gemma4:e4b".to_string(),
            "qwen3:4b-instruct-2507-q4_K_M".to_string(),
        ];
        assert_eq!(
            pick_fallback_model(&available),
            Some("qwen3:4b-instruct-2507-q4_K_M".into())
        );
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

    /// An OpenAI-compatible model server that answers KEEP to everything
    /// after `delay`, counting the requests it gets.
    async fn counting_model(delay: Duration) -> (String, Arc<std::sync::atomic::AtomicUsize>) {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let asked = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let counter = asked.clone();
        tokio::spawn(async move {
            while let Ok((mut socket, _)) = listener.accept().await {
                let counter = counter.clone();
                tokio::spawn(async move {
                    let mut buf = vec![0u8; 64 * 1024];
                    let mut read = 0;
                    loop {
                        let n = socket.read(&mut buf[read..]).await.unwrap_or(0);
                        if n == 0 {
                            return;
                        }
                        read += n;
                        let head = String::from_utf8_lossy(&buf[..read]);
                        if let Some(end) = head.find("\r\n\r\n") {
                            let length = head
                                .lines()
                                .find_map(|l| {
                                    l.to_ascii_lowercase()
                                        .strip_prefix("content-length:")
                                        .map(|v| v.trim().parse::<usize>().unwrap_or(0))
                                })
                                .unwrap_or(0);
                            if read >= end + 4 + length {
                                break;
                            }
                        }
                    }
                    counter.fetch_add(1, Ordering::SeqCst);
                    tokio::time::sleep(delay).await;
                    let body = r#"{"choices":[{"message":{"content":"KEEP"}}]}"#;
                    let response = format!(
                        "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
                        body.len()
                    );
                    let _ = socket.write_all(response.as_bytes()).await;
                });
            }
        });
        (format!("http://{addr}"), asked)
    }

    fn handle_for(host: &str) -> ClassifierHandle {
        let mut cfg: FilterConfig = toml::from_str(FilterConfig::default_content()).unwrap();
        cfg.llm.backend = LlmBackend::OpenAi;
        cfg.llm.host = host.into();
        cfg.llm.model = "stub".into();
        Classifier::new(&cfg).handle()
    }

    #[tokio::test]
    async fn warming_up_asks_the_model_once_until_it_goes_quiet() {
        let (host, asked) = counting_model(Duration::from_millis(50)).await;
        let handle = handle_for(&host);

        let (first, second) = tokio::join!(handle.warm(), handle.warm());
        assert!(first ^ second, "two warm-ups at once ask the model once");
        assert_eq!(asked.load(Ordering::SeqCst), 1);

        assert!(
            !handle.warm().await,
            "a model that just answered isn't asked again"
        );
        assert_eq!(asked.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn a_model_that_just_judged_a_post_is_not_warmed_up() {
        let (host, asked) = counting_model(Duration::ZERO).await;
        let handle = handle_for(&host);
        assert!(handle.classify("1", "a post about bread").await.is_some());

        assert!(!handle.warm().await);
        assert_eq!(asked.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn a_failed_warm_up_lets_the_next_one_try() {
        let handle = handle_for("http://127.0.0.1:9");

        assert!(handle.warm().await);
        assert!(
            handle.warm().await,
            "a model that never answered is asked again"
        );
    }
}
