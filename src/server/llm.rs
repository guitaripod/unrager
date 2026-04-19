use crate::error::Result;
use crate::gql::endpoints;
use crate::gql::query_ids::Operation;
use crate::model::Tweet;
use crate::parse::timeline;
use crate::parse::tweet as parse_tweet;
use crate::tui::filter::{
    FilterConfig, FilterDecision, OllamaChatResponse, OllamaConfig, build_system_prompt,
};
use crate::tui::source;
use std::sync::Arc;
use unrager_model::AskPreset;

pub fn classify_system_prompt(cfg: &FilterConfig) -> String {
    build_system_prompt(cfg)
}

pub async fn classify_one(
    ollama: &OllamaConfig,
    system_prompt: Arc<String>,
    text: String,
) -> FilterDecision {
    use crate::tui::filter::parse_verdict;
    let http = ollama.build_client();
    let url = ollama.chat_url();
    let body = serde_json::json!({
        "model": ollama.model,
        "messages": [
            { "role": "system", "content": *system_prompt },
            { "role": "user", "content": text },
        ],
        "stream": false,
        "think": false,
        "keep_alive": ollama.keep_alive,
        "options": { "temperature": 0, "num_predict": 3 },
    });
    match http.post(&url).json(&body).send().await {
        Ok(resp) if resp.status().is_success() => match resp.json::<OllamaChatResponse>().await {
            Ok(r) => parse_verdict(&r.message.content),
            Err(_) => FilterDecision::Keep,
        },
        _ => FilterDecision::Keep,
    }
}

pub async fn fetch_tweet(gql: &crate::gql::GqlClient, tweet_id: &str) -> Result<Tweet> {
    let response = gql
        .get(
            Operation::TweetResultByRestId,
            &endpoints::tweet_by_rest_id_variables(tweet_id),
            &endpoints::tweet_read_features(),
        )
        .await?;
    parse_tweet::parse_tweet_result_by_rest_id(&response)
}

pub async fn fetch_tweets_for_brief(
    gql: &crate::gql::GqlClient,
    handle: &str,
    max_pages: u32,
) -> Result<Vec<Tweet>> {
    let user_id = source::resolve_user_id(gql, handle).await?;
    let mut all = Vec::new();
    let mut cursor: Option<String> = None;
    for _ in 0..max_pages {
        let response = gql
            .get(
                Operation::UserTweets,
                &endpoints::user_tweets_variables(&user_id, 40, cursor.as_deref()),
                &endpoints::user_tweets_features(),
            )
            .await?;
        let instructions = timeline::extract_instructions_multi(
            &response,
            &[
                "/data/user/result/timeline/timeline/instructions",
                "/data/user/result/timeline_v2/timeline/instructions",
            ],
        )?;
        let page = timeline::walk(instructions);
        if page.tweets.is_empty() {
            break;
        }
        all.extend(page.tweets);
        match page.next_cursor {
            Some(c) => cursor = Some(c),
            None => break,
        }
    }
    Ok(all)
}

pub fn ask_system_prompt(preset: AskPreset) -> &'static str {
    match preset {
        AskPreset::Explain => {
            "Explain the following tweet in plain English. Unpack references, context, and implied meaning. Be direct; no throat-clearing."
        }
        AskPreset::Summary => {
            "Summarize the following tweet in two sentences. Focus on the single clearest claim."
        }
        AskPreset::Counter => {
            "Provide a grounded counter-argument to the claim in the following tweet. State the counter directly, then give one concrete reason."
        }
        AskPreset::Eli5 => {
            "Explain the following tweet to a smart ten-year-old. Short sentences, no jargon."
        }
        AskPreset::Entities => {
            "List the people, organizations, products, and places named in the following tweet. Output a plain bullet list with one item per line."
        }
    }
}

pub fn translate_system_prompt() -> &'static str {
    "Translate the following tweet to English. Preserve meaning and tone. Output only the translation, no preamble."
}

pub fn brief_system_prompt() -> &'static str {
    "You are summarizing a Twitter account. Read the tweets below and write a 2-3 sentence third-person description of what this person tweets about. Concrete, not flattering, not editorial."
}

pub fn tweet_as_prompt_text(t: &Tweet) -> String {
    format!("@{} ({}): {}", t.author.handle, t.author.name, t.text)
}

pub fn tweets_as_brief_context(tweets: &[Tweet]) -> String {
    let mut out = String::new();
    for t in tweets.iter().take(200) {
        out.push_str("- ");
        let snippet: String = t.text.chars().take(280).collect();
        out.push_str(&snippet.replace('\n', " "));
        out.push('\n');
    }
    out
}
