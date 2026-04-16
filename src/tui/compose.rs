use crate::gql::client::GqlClient;
use crate::gql::endpoints;
use crate::gql::query_ids::Operation;
use crate::model::Tweet;
use crate::tui::editor::VimEditor;
use crate::tui::event::{Event, EventTx};
use std::sync::Arc;

const TWEET_CHAR_LIMIT: usize = 280;

#[derive(Debug)]
pub struct ComposeView {
    pub tweet: Tweet,
    pub editor: VimEditor,
    pub sending: bool,
    pub error: Option<String>,
}

impl ComposeView {
    pub fn new(tweet: Tweet) -> Self {
        Self {
            tweet,
            editor: VimEditor::with_limit(TWEET_CHAR_LIMIT),
            sending: false,
            error: None,
        }
    }

    pub fn tweet_id(&self) -> &str {
        &self.tweet.rest_id
    }
}

pub fn dispatch_reply(text: String, in_reply_to: String, client: Arc<GqlClient>, tx: EventTx) {
    let variables = endpoints::create_tweet_variables(&text, Some(&in_reply_to));
    let features = endpoints::create_tweet_features();

    tracing::debug!(
        %in_reply_to,
        text_len = text.len(),
        variables = %serde_json::to_string(&variables).unwrap_or_default(),
        "dispatching CreateTweet reply"
    );

    tokio::spawn(async move {
        let result = match client
            .post(Operation::CreateTweet, &variables, &features)
            .await
        {
            Ok(resp) => {
                tracing::debug!(%in_reply_to, response = %resp, "CreateTweet raw response");
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
                        tracing::warn!(%in_reply_to, response = %resp, "reply posted but could not extract id");
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
