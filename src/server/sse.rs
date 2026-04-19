use crate::server::error::ApiError;
use crate::server::llm;
use crate::server::state::AppState;
use crate::tui::filter::FilterDecision;
use async_stream::stream;
use axum::extract::{Query, State};
use axum::response::Sse;
use axum::response::sse::{Event, KeepAlive};
use futures::Stream;
use serde::Deserialize;
use std::convert::Infallible;
use std::sync::Arc;
use tokio::sync::mpsc;
use unrager_model::{AskPreset, FilterVerdictEvent, TokenEvent, Verdict};

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
                cache.put(&id, decision);
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
    let (tx, mut rx) = mpsc::channel::<String>(128);
    let done_tx = tx.clone();

    tokio::spawn(async move {
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
        let inner_tx = tx.clone();
        let _ = ollama
            .stream_chat(
                body,
                label,
                move |token| {
                    let _ = inner_tx.try_send(token.to_string());
                },
                |_| {},
            )
            .await;
        drop(done_tx);
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

fn decision_to_verdict(d: FilterDecision) -> Verdict {
    match d {
        FilterDecision::Hide => Verdict::Hide,
        FilterDecision::Keep => Verdict::Keep,
    }
}
