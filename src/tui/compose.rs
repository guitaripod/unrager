use crate::gql::client::GqlClient;
use crate::gql::endpoints;
use crate::gql::query_ids::Operation;
use crate::tui::editor::VimEditor;
use crate::tui::event::{Event, EventTx};
use std::sync::Arc;

const TWEET_CHAR_LIMIT: usize = 280;

#[derive(Debug)]
pub struct ReplyBar {
    pub editor: VimEditor,
    pub sending: bool,
    pub error: Option<String>,
}

impl Default for ReplyBar {
    fn default() -> Self {
        Self::new()
    }
}

impl ReplyBar {
    pub fn new() -> Self {
        Self {
            editor: VimEditor::with_limit(TWEET_CHAR_LIMIT),
            sending: false,
            error: None,
        }
    }
}

pub fn friendly_error(raw: &str) -> String {
    if raw.contains("\"code\":226") || raw.contains("code=226") {
        return "X flagged this as automated activity · wait a few minutes and try again".into();
    }
    if raw.contains("\"code\":139") {
        return "already replied to this tweet".into();
    }
    if raw.contains("rate-limited") || raw.contains("rate limit") || raw.contains("429") {
        return "X cooldown in effect · wait before sending again".into();
    }
    if raw.contains("Authorization") && raw.contains("Permissions") {
        return "X rejected this request (permissions) · account may be flagged".into();
    }
    if raw.contains("\"code\":88") {
        return "X cooldown in effect · wait before sending again".into();
    }
    if raw.contains("graphql errors:") {
        let start = raw.find("graphql errors:").unwrap() + "graphql errors:".len();
        return format!(
            "X error:{}",
            &raw[start..].chars().take(80).collect::<String>()
        );
    }
    raw.chars().take(120).collect()
}

pub fn dispatch_reply(text: String, in_reply_to: String, client: Arc<GqlClient>, tx: EventTx) {
    let variables = endpoints::create_tweet_variables(&text, Some(&in_reply_to));
    let features = endpoints::create_tweet_features();

    tracing::debug!(
        %in_reply_to,
        text_len = text.len(),
        "dispatching CreateTweet reply"
    );

    tokio::spawn(async move {
        let result = match client
            .post(Operation::CreateTweet, &variables, &features)
            .await
        {
            Ok(resp) => {
                let new_id = resp
                    .pointer("/data/create_tweet/tweet_results/result/rest_id")
                    .and_then(|v| v.as_str())
                    .map(String::from);
                match new_id {
                    Some(id) => {
                        tracing::info!(%in_reply_to, %id, "reply posted");
                        Ok(id)
                    }
                    None => {
                        tracing::warn!(%in_reply_to, "reply posted but could not extract id");
                        Ok("unknown".to_string())
                    }
                }
            }
            Err(e) => {
                tracing::warn!(%in_reply_to, error = %e, "CreateTweet failed");
                Err(e.to_string())
            }
        };
        let _ = tx.send(Event::ReplyResult {
            in_reply_to,
            result,
        });
    });
}
