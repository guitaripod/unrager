use crate::error::Result;
use crate::gql::endpoints;
use crate::gql::query_ids::Operation;
use crate::model::Tweet;
use crate::parse::timeline;
use unrager_model::AskPreset;

/// Posts a brief reads; [`tweets_as_brief_context`] keeps no more.
pub const BRIEF_POSTS: usize = 200;
/// Pages a brief fetches at most, one throttled X request each, all before
/// the first token.
pub const BRIEF_PAGES: u32 = 5;

/// An account's recent posts for a brief: pages of `UserTweets` until
/// [`BRIEF_POSTS`] are in hand, the timeline ends, or [`BRIEF_PAGES`] pages.
pub async fn fetch_tweets_for_brief(
    gql: &crate::gql::GqlClient,
    user_id: &str,
) -> Result<Vec<Tweet>> {
    let mut all = Vec::new();
    let mut cursor: Option<String> = None;
    for _ in 0..BRIEF_PAGES {
        let response = gql
            .get(
                Operation::UserTweets,
                &endpoints::user_tweets_variables(user_id, 40, cursor.as_deref()),
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
        if all.len() >= BRIEF_POSTS {
            break;
        }
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
    for t in tweets.iter().take(BRIEF_POSTS) {
        out.push_str("- ");
        let snippet: String = t.text.chars().take(280).collect();
        out.push_str(&snippet.replace('\n', " "));
        out.push('\n');
    }
    out
}
