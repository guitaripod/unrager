use crate::server::error::ApiError;
use crate::server::llm;
use crate::server::state::AppState;
use crate::tui::ask;
use crate::tui::filter::{FilterCache, FilterDecision};
use async_stream::stream;
use axum::extract::{Query, State};
use axum::response::Sse;
use axum::response::sse::{Event, KeepAlive};
use futures::Stream;
use serde::Deserialize;
use std::convert::Infallible;
use std::sync::Arc;
use tokio::sync::mpsc;
use unrager_model::{
    AskPreset, AskRequest, AskRole, AskTurn, FilterVerdictEvent, TokenEvent, Verdict,
};

#[derive(Debug, Deserialize)]
pub struct FilterQuery {
    pub ids: String,
}

pub async fn filter_stream(
    State(state): State<Arc<AppState>>,
    Query(q): Query<FilterQuery>,
) -> Sse<impl Stream<Item = std::result::Result<Event, Infallible>>> {
    let ids: Vec<String> = q
        .ids
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();

    let (tx, mut rx) = mpsc::channel::<FilterVerdictEvent>(64);
    let state_clone = state.clone();

    tokio::spawn(async move {
        let cfg = state_clone.filter_config.lock().await.clone();
        let ollama = cfg.ollama.clone();
        let system = Arc::new(llm::classify_system_prompt(&cfg));
        let rubric_snapshot = cfg.rubric_hash();
        for id in ids {
            // cache hit?
            {
                let cache = state_clone.filter_cache.lock().await;
                if let Some(d) = cache.get(&id) {
                    let _ = tx
                        .send(FilterVerdictEvent {
                            id: id.clone(),
                            verdict: decision_to_verdict(d),
                        })
                        .await;
                    continue;
                }
            }
            let tweet = match llm::fetch_tweet(&state_clone.gql, &id).await {
                Ok(t) => t,
                Err(_) => continue,
            };
            let text = llm::tweet_as_prompt_text(&tweet);
            let decision = llm::classify_one(&ollama, system.clone(), text).await;
            {
                let mut cache = state_clone.filter_cache.lock().await;
                persist_verdict(&mut cache, &rubric_snapshot, &id, decision);
            }
            let _ = tx
                .send(FilterVerdictEvent {
                    id,
                    verdict: decision_to_verdict(decision),
                })
                .await;
        }
    });

    let s = stream! {
        while let Some(v) = rx.recv().await {
            let data = serde_json::to_string(&v).unwrap_or_else(|_| "{}".into());
            yield Ok(Event::default().data(data));
        }
        yield Ok(Event::default().data("[DONE]"));
    };
    Sse::new(s).keep_alive(KeepAlive::new())
}

#[derive(Debug, Deserialize)]
pub struct AskQuery {
    pub tweet_id: String,
    pub preset: String,
}

pub async fn ask_stream(
    State(state): State<Arc<AppState>>,
    Query(q): Query<AskQuery>,
) -> std::result::Result<Sse<impl Stream<Item = std::result::Result<Event, Infallible>>>, ApiError>
{
    let preset = parse_preset(&q.preset)
        .ok_or_else(|| ApiError::bad_request(format!("unknown preset: {}", q.preset)))?;
    let tweet = llm::fetch_tweet(&state.gql, &q.tweet_id).await?;
    let cfg = state.filter_config.lock().await.clone();

    Ok(stream_tokens(
        cfg.ollama.clone(),
        llm::ask_system_prompt(preset).to_string(),
        llm::tweet_as_prompt_text(&tweet),
        "ask",
    ))
}

/// `POST /api/sse/ask` — the conversational ask stream. Mirrors the TUI's ask
/// view: the focal tweet (fetched fresh, photos attached for multimodal
/// models) plus client-supplied thread context and the full turn history are
/// folded into the same prompt the TUI builds, and tokens stream back as the
/// usual `TokenEvent` SSE.
pub async fn ask_context_stream(
    State(state): State<Arc<AppState>>,
    axum::Json(req): axum::Json<AskRequest>,
) -> std::result::Result<Sse<impl Stream<Item = std::result::Result<Event, Infallible>>>, ApiError>
{
    if req.turns.is_empty() {
        return Err(ApiError::bad_request("turns must not be empty"));
    }
    let last_is_user = matches!(
        req.turns.last(),
        Some(AskTurn {
            role: AskRole::User,
            ..
        })
    );
    if !last_is_user {
        return Err(ApiError::bad_request("turns must end with a user turn"));
    }
    let tweet = llm::fetch_tweet(&state.gql, &req.tweet_id).await?;
    let cfg = state.filter_config.lock().await.clone();

    let images = ask::fetch_images(&tweet).await;
    let ctx = ask::PromptContext {
        ancestors: req.ancestors.into_iter().map(prompt_entry).collect(),
        siblings: req.siblings.into_iter().map(prompt_entry).collect(),
        replies: req.replies.into_iter().map(prompt_entry).collect(),
    };
    let turns: Vec<(ask::Role, String)> = req
        .turns
        .into_iter()
        .map(|t| {
            let role = match t.role {
                AskRole::User => ask::Role::User,
                AskRole::Assistant => ask::Role::Assistant,
            };
            (role, t.text)
        })
        .collect();
    let messages = ask::build_messages(&tweet.author.handle, &tweet.text, &ctx, &turns, images);
    tracing::info!(
        tweet_id = %tweet.rest_id,
        turns = turns.len(),
        ancestors = ctx.ancestors.len(),
        siblings = ctx.siblings.len(),
        replies = ctx.replies.len(),
        "ask context stream start"
    );

    let ollama = cfg.ollama.clone();
    let body = serde_json::json!({
        "model": ollama.model,
        "messages": messages,
        "stream": true,
        "think": true,
        "keep_alive": ollama.keep_alive,
        "options": { "temperature": 0.3, "num_predict": 2048 },
    });
    Ok(stream_body(ollama, body, "ask"))
}

fn prompt_entry(e: unrager_model::AskContextEntry) -> ask::PromptEntry {
    ask::PromptEntry {
        handle: e.handle,
        text: e.text,
    }
}

fn parse_preset(s: &str) -> Option<AskPreset> {
    match s.to_ascii_lowercase().as_str() {
        "explain" => Some(AskPreset::Explain),
        "summary" => Some(AskPreset::Summary),
        "counter" => Some(AskPreset::Counter),
        "eli5" => Some(AskPreset::Eli5),
        "entities" => Some(AskPreset::Entities),
        _ => None,
    }
}

#[derive(Debug, Deserialize)]
pub struct BriefQuery {
    pub handle: String,
}

pub async fn brief_stream(
    State(state): State<Arc<AppState>>,
    Query(q): Query<BriefQuery>,
) -> std::result::Result<Sse<impl Stream<Item = std::result::Result<Event, Infallible>>>, ApiError>
{
    let handle = q.handle.trim_start_matches('@').to_string();
    let tweets = llm::fetch_tweets_for_brief(&state.gql, &handle, 8).await?;
    let cfg = state.filter_config.lock().await.clone();
    let user = format!(
        "Handle: @{handle}\n\nTweets:\n{}",
        llm::tweets_as_brief_context(&tweets)
    );

    Ok(stream_tokens(
        cfg.ollama.clone(),
        llm::brief_system_prompt().to_string(),
        user,
        "brief",
    ))
}

#[derive(Debug, Deserialize)]
pub struct TranslateQuery {
    pub tweet_id: String,
}

pub async fn translate_stream(
    State(state): State<Arc<AppState>>,
    Query(q): Query<TranslateQuery>,
) -> std::result::Result<Sse<impl Stream<Item = std::result::Result<Event, Infallible>>>, ApiError>
{
    let tweet = llm::fetch_tweet(&state.gql, &q.tweet_id).await?;
    let cfg = state.filter_config.lock().await.clone();

    Ok(stream_tokens(
        cfg.ollama.clone(),
        llm::translate_system_prompt().to_string(),
        tweet.text.clone(),
        "translate",
    ))
}

fn stream_tokens(
    ollama: crate::tui::filter::OllamaConfig,
    system: String,
    user: String,
    label: &'static str,
) -> Sse<impl Stream<Item = std::result::Result<Event, Infallible>>> {
    let body = serde_json::json!({
        "model": ollama.model,
        "messages": [
            { "role": "system", "content": system },
            { "role": "user", "content": user },
        ],
        "stream": true,
        "think": false,
        "keep_alive": ollama.keep_alive,
        "options": { "temperature": 0, "num_predict": 1024 },
    });
    stream_body(ollama, body, label)
}

/// Streams a fully-built Ollama chat body as a `TokenEvent` SSE response —
/// the shared core of the single-shot streams and the conversational ask.
fn stream_body(
    ollama: crate::tui::filter::OllamaConfig,
    body: serde_json::Value,
    label: &'static str,
) -> Sse<impl Stream<Item = std::result::Result<Event, Infallible>>> {
    let (tx, mut rx) = token_channel();

    tokio::spawn(async move {
        let _ = ollama
            .stream_chat(
                body,
                label,
                move |token| {
                    let _ = tx.send(token.to_string());
                },
                |_| {},
            )
            .await;
    });

    let s = stream! {
        while let Some(token) = rx.recv().await {
            let ev = TokenEvent { token, done: false };
            let data = serde_json::to_string(&ev).unwrap_or_else(|_| "{}".into());
            yield Ok(Event::default().data(data));
        }
        let ev = TokenEvent { token: String::new(), done: true };
        yield Ok(Event::default().data(serde_json::to_string(&ev).unwrap_or_default()));
        yield Ok(Event::default().data("[DONE]"));
    };
    Sse::new(s).keep_alive(KeepAlive::new())
}

/// Lossless channel between the sync `stream_chat` token callback and the SSE
/// body. It must be unbounded: the callback can't await, a bounded `try_send`
/// silently drops tokens whenever a slow client stalls the SSE stream, and the
/// backlog is inherently small (`num_predict: 1024` short strings), so every
/// token is buffered until the client catches up instead of being discarded
/// mid-output.
fn token_channel() -> (
    mpsc::UnboundedSender<String>,
    mpsc::UnboundedReceiver<String>,
) {
    mpsc::unbounded_channel()
}

/// Persist a stream-computed verdict only while the live cache still speaks
/// the rubric this stream snapshotted at start. A `PATCH /api/config/filter`
/// arriving mid-stream re-keys the shared cache to the new rubric hash, and
/// storing an old-prompt verdict under it would poison the new rubric's cache
/// for the whole retention window. The SSE event is emitted either way — the
/// client asked under the old rubric and still gets its answer.
fn persist_verdict(cache: &mut FilterCache, rubric_snapshot: &str, id: &str, d: FilterDecision) {
    if cache.rubric_hash() == rubric_snapshot {
        cache.put(id, d);
    } else {
        tracing::debug!(
            id,
            snapshot = rubric_snapshot,
            live = cache.rubric_hash(),
            "rubric changed mid-stream; verdict not cached"
        );
    }
}

fn decision_to_verdict(d: FilterDecision) -> Verdict {
    match d {
        FilterDecision::Hide => Verdict::Hide,
        FilterDecision::Keep => Verdict::Keep,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn token_channel_is_lossless_when_the_consumer_stalls() {
        let (tx, mut rx) = token_channel();
        let total = 4096usize;
        for i in 0..total {
            assert!(tx.send(format!("t{i}")).is_ok());
        }
        drop(tx);
        let mut received = Vec::with_capacity(total);
        while let Some(t) = rx.recv().await {
            received.push(t);
        }
        assert_eq!(received.len(), total);
        assert_eq!(received.first().map(String::as_str), Some("t0"));
        assert_eq!(received.last().map(String::as_str), Some("t4095"));
    }

    #[test]
    fn verdict_persists_only_under_the_snapshotted_rubric() {
        let tmp = tempfile::NamedTempFile::new().unwrap();
        let mut cache = FilterCache::open(tmp.path(), "old-rubric".into()).unwrap();
        persist_verdict(&mut cache, "old-rubric", "t1", FilterDecision::Hide);
        assert_eq!(
            cache.get("t1"),
            Some(FilterDecision::Hide),
            "matching rubric persists normally"
        );
        cache.rekey("new-rubric".into()).unwrap();
        persist_verdict(&mut cache, "old-rubric", "t2", FilterDecision::Hide);
        assert_eq!(
            cache.get("t2"),
            None,
            "an old-prompt verdict must not launder into the new rubric's cache"
        );
        let reopened = FilterCache::open(tmp.path(), "new-rubric".into()).unwrap();
        assert!(!reopened.contains("t2"));
    }
}
