use crate::model::{MediaKind, Tweet};
use crate::tui::event::{Event, EventTx};
use crate::tui::filter::OllamaConfig;
use crate::tui::source::PaneState;
use base64::Engine;
use futures::TryStreamExt;
use serde_json::{Value, json};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio_util::io::StreamReader;
use tracing::{debug, info, warn};

pub const DEFAULT_PROMPT: &str = "Explain this post";

const SYSTEM_PROMPT: &str = "You help a reader understand a social media post. Be concise, direct, and factual. Keep replies short (2–4 short paragraphs). If the post is ambiguous or lacks context, say so plainly.";

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

#[derive(Debug)]
pub struct AskView {
    pub tweet: Tweet,
    pub messages: Vec<AskMessage>,
    pub input: String,
    pub streaming: bool,
    pub error: Option<String>,
    pub state: PaneState,
    pub auto_follow: bool,
}

impl AskView {
    pub fn new(tweet: Tweet) -> Self {
        Self {
            tweet,
            messages: Vec::new(),
            input: String::new(),
            streaming: false,
            error: None,
            state: PaneState::default(),
            auto_follow: true,
        }
    }

    pub fn tweet_id(&self) -> &str {
        &self.tweet.rest_id
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

pub fn send(ollama: OllamaConfig, tweet: Tweet, turns: Vec<(Role, String)>, tx: EventTx) {
    let tweet_id = tweet.rest_id.clone();
    tokio::spawn(async move {
        info!(tweet_id = %tweet_id, turns = turns.len(), "ask stream start");
        let images = fetch_images(&tweet).await;
        if !images.is_empty() {
            debug!(tweet_id = %tweet_id, count = images.len(), "ask images attached");
        }
        let messages = build_messages(&tweet, &turns, images);
        stream_ollama(&ollama, &tweet_id, messages, &tx).await;
    });
}

fn build_messages(tweet: &Tweet, turns: &[(Role, String)], images: Vec<String>) -> Vec<Value> {
    let mut out: Vec<Value> = Vec::with_capacity(turns.len() + 1);
    out.push(json!({ "role": "system", "content": SYSTEM_PROMPT }));
    let handle = &tweet.author.handle;
    let tweet_text = &tweet.text;
    let mut first_user = true;
    for (role, text) in turns {
        match role {
            Role::User => {
                let content = if first_user {
                    format!("@{handle} posted:\n{tweet_text}\n\n{text}")
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
    let http = match reqwest::Client::builder()
        .timeout(Duration::from_secs(ollama.timeout_seconds.max(180)))
        .build()
    {
        Ok(c) => c,
        Err(e) => {
            finish(tx, tweet_id, Some(format!("http client build failed: {e}")));
            return;
        }
    };
    let url = format!("{}/api/chat", ollama.host.trim_end_matches('/'));
    let body = json!({
        "model": ollama.model,
        "messages": messages,
        "stream": true,
        "think": true,
        "keep_alive": ollama.keep_alive,
        "options": { "temperature": 0.3, "num_predict": 2048 },
    });

    let response = match http.post(&url).json(&body).send().await {
        Ok(r) => r,
        Err(e) => {
            warn!(tweet_id = %tweet_id, "ask request failed: {e}");
            finish(tx, tweet_id, Some(format!("request failed: {e}")));
            return;
        }
    };

    let status = response.status();
    if !status.is_success() {
        let body_preview = response.text().await.unwrap_or_default();
        let trimmed = body_preview.chars().take(200).collect::<String>();
        warn!(
            tweet_id = %tweet_id,
            status = status.as_u16(),
            body = %trimmed,
            "ask http error"
        );
        finish(
            tx,
            tweet_id,
            Some(format!("http {}: {trimmed}", status.as_u16())),
        );
        return;
    }

    let stream = response.bytes_stream().map_err(std::io::Error::other);
    let reader = StreamReader::new(stream);
    let mut lines = BufReader::new(reader).lines();

    loop {
        match lines.next_line().await {
            Ok(Some(line)) => {
                if line.trim().is_empty() {
                    continue;
                }
                match serde_json::from_str::<Value>(&line) {
                    Ok(parsed) => {
                        if let Some(c) = parsed.pointer("/message/content").and_then(Value::as_str)
                            && !c.is_empty()
                        {
                            let _ = tx.send(Event::AskToken {
                                tweet_id: tweet_id.to_string(),
                                token: c.to_string(),
                            });
                        }
                        if parsed.get("done").and_then(Value::as_bool) == Some(true) {
                            break;
                        }
                    }
                    Err(e) => {
                        debug!(tweet_id = %tweet_id, error = %e, raw = %line, "ask json parse skip");
                    }
                }
            }
            Ok(None) => break,
            Err(e) => {
                warn!(tweet_id = %tweet_id, "ask stream read error: {e}");
                finish(tx, tweet_id, Some(format!("stream error: {e}")));
                return;
            }
        }
    }

    info!(tweet_id = %tweet_id, "ask stream complete");
    finish(tx, tweet_id, None);
}

fn finish(tx: &EventTx, tweet_id: &str, error: Option<String>) {
    let _ = tx.send(Event::AskStreamFinished {
        tweet_id: tweet_id.to_string(),
        error,
    });
}
