use crate::model::Tweet;
use crate::tui::event::{Event, EventTx};
use crate::tui::filter::OllamaConfig;
use crate::tui::source::PaneState;
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

    pub fn build_ollama_messages(&self) -> Vec<Value> {
        let mut out: Vec<Value> = Vec::with_capacity(self.messages.len() + 1);
        out.push(json!({ "role": "system", "content": SYSTEM_PROMPT }));
        let handle = &self.tweet.author.handle;
        let tweet_text = &self.tweet.text;
        for (i, m) in self.messages.iter().enumerate() {
            match m {
                AskMessage::User(text) => {
                    let content = if i == 0 {
                        format!("@{handle} posted:\n{tweet_text}\n\n{text}")
                    } else {
                        text.clone()
                    };
                    out.push(json!({ "role": "user", "content": content }));
                }
                AskMessage::Assistant(a) => {
                    out.push(json!({ "role": "assistant", "content": a.text }));
                }
            }
        }
        out
    }
}

pub fn send(ollama: OllamaConfig, messages: Vec<Value>, tweet_id: String, tx: EventTx) {
    tokio::spawn(async move {
        info!(tweet_id = %tweet_id, turns = messages.len(), "ask stream start");
        stream_ollama(&ollama, &tweet_id, messages, &tx).await;
    });
}

async fn stream_ollama(ollama: &OllamaConfig, tweet_id: &str, messages: Vec<Value>, tx: &EventTx) {
    let http = match reqwest::Client::builder()
        .timeout(Duration::from_secs(ollama.timeout_seconds.max(60)))
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
        "options": { "temperature": 0.3, "num_predict": 1024 },
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
                        if let Some(token) =
                            parsed.pointer("/message/content").and_then(Value::as_str)
                            && !token.is_empty()
                        {
                            let _ = tx.send(Event::AskToken {
                                tweet_id: tweet_id.to_string(),
                                token: token.to_string(),
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
