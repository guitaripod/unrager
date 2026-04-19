use crate::model::{MediaKind, Tweet};
use crate::tui::editor::VimEditor;
use crate::tui::event::{Event, EventTx};
use crate::tui::filter::OllamaConfig;
use crate::tui::source::PaneState;
use base64::Engine;
use serde_json::{Value, json};
use std::time::Duration;
use tracing::{debug, info, warn};

pub const DEFAULT_PROMPT: &str = "Explain this post";

const SYSTEM_PROMPT: &str = "You help a reader understand a social media post. Be concise, direct, and factual. Keep replies short (2–4 short paragraphs). If the post is ambiguous or lacks context, say so plainly. Prefer plain prose. Use markdown sparingly: **bold**, bulleted lists with '- ', and inline `code` are fine when they genuinely help, but avoid headings, horizontal rules, tables, and heavy formatting.";

const MAX_REPLIES_IN_CONTEXT: usize = 20;

#[derive(Debug, Clone, Copy)]
pub struct Preset {
    pub label: &'static str,
    pub prompt: &'static str,
    pub needs_replies: bool,
}

pub const PRESETS: &[Preset] = &[
    Preset {
        label: "Explain",
        prompt: "Explain this post.",
        needs_replies: false,
    },
    Preset {
        label: "Replies",
        prompt: "Summarize the key points of the replies in 3–5 bullets. Focus on dominant reactions and any notable disagreements.",
        needs_replies: true,
    },
    Preset {
        label: "Counter",
        prompt: "What are the strongest counter-arguments to this post? List 2–3, each one or two sentences.",
        needs_replies: false,
    },
    Preset {
        label: "ELI5",
        prompt: "Explain this post like I'm five.",
        needs_replies: false,
    },
    Preset {
        label: "Entities",
        prompt: "Who and what is referenced in this post? Identify people, projects, events, or topics mentioned.",
        needs_replies: false,
    },
];

#[derive(Debug)]
pub struct AskAssistantMsg {
    pub text: String,
    pub complete: bool,
}

impl AskAssistantMsg {
    fn new() -> Self {
        Self {
            text: String::new(),
            complete: false,
        }
    }
}

#[derive(Debug)]
pub enum AskMessage {
    User(String),
    Assistant(AskAssistantMsg),
}

#[derive(Debug, Clone, Default)]
pub struct ThreadContext {
    pub ancestors: Vec<Tweet>,
    pub siblings: Vec<Tweet>,
}

impl ThreadContext {
    pub fn is_empty(&self) -> bool {
        self.ancestors.is_empty() && self.siblings.is_empty()
    }
}

#[derive(Debug)]
pub struct AskView {
    pub tweet: Tweet,
    pub replies: Vec<Tweet>,
    pub replies_loading: bool,
    pub thread: Option<ThreadContext>,
    pub thread_loading: bool,
    pub messages: Vec<AskMessage>,
    pub editor: VimEditor,
    pub streaming: bool,
    pub error: Option<String>,
    pub state: PaneState,
    pub auto_follow: bool,
}

impl AskView {
    pub fn new(tweet: Tweet, replies: Vec<Tweet>, replies_loading: bool) -> Self {
        Self {
            tweet,
            replies,
            replies_loading,
            thread: None,
            thread_loading: false,
            messages: Vec::new(),
            editor: VimEditor::normal(),
            streaming: false,
            error: None,
            state: PaneState::default(),
            auto_follow: true,
        }
    }

    pub fn with_thread(mut self, thread: ThreadContext) -> Self {
        self.thread = Some(thread);
        self
    }

    pub fn with_thread_loading(mut self) -> Self {
        self.thread_loading = true;
        self
    }

    pub fn ancestor_count(&self) -> usize {
        self.thread.as_ref().map(|t| t.ancestors.len()).unwrap_or(0)
    }

    pub fn tweet_id(&self) -> &str {
        &self.tweet.rest_id
    }

    pub fn image_count(&self) -> usize {
        self.tweet
            .media
            .iter()
            .filter(|m| matches!(m.kind, MediaKind::Photo))
            .count()
            .min(4)
    }

    pub fn reply_count(&self) -> usize {
        self.replies.len()
    }

    pub fn available_presets(&self) -> Vec<(usize, &'static Preset)> {
        PRESETS
            .iter()
            .enumerate()
            .map(|(i, p)| (i + 1, p))
            .collect()
    }

    pub fn preset_enabled(&self, preset: &Preset) -> bool {
        !preset.needs_replies || !self.replies.is_empty()
    }

    pub fn push_user_message(&mut self, text: String) {
        self.messages.push(AskMessage::User(text));
        self.messages
            .push(AskMessage::Assistant(AskAssistantMsg::new()));
        self.streaming = true;
        self.error = None;
    }

    pub fn append_token(&mut self, token: &str) {
        if let Some(AskMessage::Assistant(m)) = self.messages.last_mut() {
            m.text.push_str(token);
        }
    }

    pub fn mark_done(&mut self, error: Option<String>) {
        self.streaming = false;
        if let Some(AskMessage::Assistant(m)) = self.messages.last_mut() {
            m.complete = true;
        }
        self.error = error;
    }

    pub fn turn_texts(&self) -> Vec<(Role, String)> {
        let mut out = Vec::with_capacity(self.messages.len());
        for m in &self.messages {
            match m {
                AskMessage::User(text) => out.push((Role::User, text.clone())),
                AskMessage::Assistant(a) => out.push((Role::Assistant, a.text.clone())),
            }
        }
        out
    }
}

#[derive(Debug, Clone, Copy)]
pub enum Role {
    User,
    Assistant,
}

pub fn preload(ollama: OllamaConfig) {
    tokio::spawn(async move {
        warm_model(&ollama, "10m").await;
    });
}

pub fn unload(ollama: OllamaConfig) {
    tokio::spawn(async move {
        warm_model(&ollama, "0s").await;
    });
}

pub async fn unload_blocking(ollama: &OllamaConfig) {
    warm_model(ollama, "0s").await;
}

async fn warm_model(ollama: &OllamaConfig, keep_alive: &str) {
    let Ok(http) = reqwest::Client::builder()
        .timeout(Duration::from_secs(10))
        .build()
    else {
        return;
    };
    let url = format!("{}/api/generate", ollama.host.trim_end_matches('/'));
    let body = json!({
        "model": ollama.model,
        "prompt": "",
        "keep_alive": keep_alive,
    });
    match http.post(&url).json(&body).send().await {
        Ok(resp) if resp.status().is_success() => {
            debug!(keep_alive, model = %ollama.model, "ask model warm call ok");
        }
        Ok(resp) => {
            debug!(
                keep_alive,
                status = resp.status().as_u16(),
                "ask model warm non-success"
            );
        }
        Err(e) => {
            debug!(keep_alive, "ask model warm failed: {e}");
        }
    }
}

pub fn send(
    ollama: OllamaConfig,
    tweet: Tweet,
    replies: Vec<Tweet>,
    thread: Option<ThreadContext>,
    turns: Vec<(Role, String)>,
    tx: EventTx,
) {
    let tweet_id = tweet.rest_id.clone();
    tokio::spawn(async move {
        info!(
            tweet_id = %tweet_id,
            turns = turns.len(),
            replies = replies.len(),
            thread_siblings = thread.as_ref().map(|t| t.siblings.len()).unwrap_or(0),
            has_thread = thread.is_some(),
            "ask stream start"
        );
        let images = fetch_images(&tweet).await;
        if !images.is_empty() {
            debug!(tweet_id = %tweet_id, count = images.len(), "ask images attached");
        }
        let messages = build_messages(&tweet, &replies, thread.as_ref(), &turns, images);
        stream_ollama(&ollama, &tweet_id, messages, &tx).await;
    });
}

fn build_messages(
    tweet: &Tweet,
    replies: &[Tweet],
    thread: Option<&ThreadContext>,
    turns: &[(Role, String)],
    images: Vec<String>,
) -> Vec<Value> {
    let mut out: Vec<Value> = Vec::with_capacity(turns.len() + 1);
    out.push(json!({ "role": "system", "content": SYSTEM_PROMPT }));
    let handle = &tweet.author.handle;
    let tweet_text = &tweet.text;
    let mut first_user = true;
    for (role, text) in turns {
        match role {
            Role::User => {
                let content = if first_user {
                    let mut buf = String::new();
                    let ctx_with_ancestors = thread.filter(|ctx| !ctx.ancestors.is_empty());
                    if let Some(ctx) = ctx_with_ancestors {
                        buf.push_str("Full thread (root first, indented by depth):\n");
                        for (i, anc) in ctx.ancestors.iter().enumerate() {
                            let indent = "  ".repeat(i);
                            let snippet: String = anc.text.chars().take(600).collect();
                            let snippet = snippet.replace('\n', " ");
                            let label = if i == 0 { "root" } else { "reply" };
                            buf.push_str(&format!(
                                "{indent}[{label}] @{}: {snippet}\n",
                                anc.author.handle
                            ));
                        }
                        let indent = "  ".repeat(ctx.ancestors.len());
                        buf.push_str(&format!("{indent}[reply] @{handle}: {tweet_text}\n"));
                        if !ctx.siblings.is_empty() {
                            buf.push_str(
                                "\nOther replies at the same level as the asked reply (context):\n",
                            );
                            for s in ctx.siblings.iter().take(MAX_REPLIES_IN_CONTEXT) {
                                let snippet: String = s.text.chars().take(400).collect();
                                let snippet = snippet.replace('\n', " ");
                                buf.push_str(&format!("- @{}: {}\n", s.author.handle, snippet));
                            }
                        }
                        buf.push_str(&format!(
                            "\nThe user is asking specifically about the last reply (@{handle}).\n"
                        ));
                    } else {
                        buf.push_str(&format!("@{handle} posted:\n{tweet_text}\n"));
                    }
                    if !replies.is_empty() {
                        buf.push_str("\nReplies to the asked post:\n");
                        for reply in replies.iter().take(MAX_REPLIES_IN_CONTEXT) {
                            let snippet: String = reply.text.chars().take(400).collect();
                            let snippet = snippet.replace('\n', " ");
                            buf.push_str(&format!("- @{}: {}\n", reply.author.handle, snippet));
                        }
                    }
                    buf.push_str(&format!("\n{text}"));
                    buf
                } else {
                    text.clone()
                };
                let mut msg = json!({ "role": "user", "content": content });
                if first_user && !images.is_empty() {
                    msg["images"] = json!(images);
                }
                out.push(msg);
                first_user = false;
            }
            Role::Assistant => {
                out.push(json!({ "role": "assistant", "content": text }));
            }
        }
    }
    out
}

async fn fetch_images(tweet: &Tweet) -> Vec<String> {
    let photo_urls: Vec<String> = tweet
        .media
        .iter()
        .filter(|m| matches!(m.kind, MediaKind::Photo))
        .map(|m| m.url.clone())
        .take(4)
        .collect();
    if photo_urls.is_empty() {
        return Vec::new();
    }
    let Ok(http) = reqwest::Client::builder()
        .timeout(Duration::from_secs(10))
        .build()
    else {
        return Vec::new();
    };
    let mut out: Vec<String> = Vec::with_capacity(photo_urls.len());
    for url in photo_urls {
        match http.get(&url).send().await {
            Ok(resp) if resp.status().is_success() => match resp.bytes().await {
                Ok(bytes) => {
                    let encoded = base64::engine::general_purpose::STANDARD.encode(&bytes);
                    out.push(encoded);
                }
                Err(e) => warn!(url = %url, "ask image body read failed: {e}"),
            },
            Ok(resp) => warn!(url = %url, status = resp.status().as_u16(), "ask image http error"),
            Err(e) => warn!(url = %url, "ask image fetch failed: {e}"),
        }
    }
    out
}

async fn stream_ollama(ollama: &OllamaConfig, tweet_id: &str, messages: Vec<Value>, tx: &EventTx) {
    let body = json!({
        "model": ollama.model,
        "messages": messages,
        "stream": true,
        "think": true,
        "keep_alive": ollama.keep_alive,
        "options": { "temperature": 0.3, "num_predict": 2048 },
    });

    let tid = tweet_id.to_string();
    let tx2 = tx.clone();
    let result = ollama
        .stream_chat(
            body,
            "ask",
            |token| {
                let _ = tx2.send(Event::AskToken {
                    tweet_id: tid.clone(),
                    token: token.to_string(),
                });
            },
            |_| {},
        )
        .await;

    match result {
        Ok(_) => {
            info!(tweet_id = %tweet_id, "ask stream complete");
            finish(tx, tweet_id, None);
        }
        Err(e) => {
            warn!(tweet_id = %tweet_id, "ask stream failed: {e}");
            finish(tx, tweet_id, Some(e));
        }
    }
}

fn finish(tx: &EventTx, tweet_id: &str, error: Option<String>) {
    let _ = tx.send(Event::AskStreamFinished {
        tweet_id: tweet_id.to_string(),
        error,
    });
}
