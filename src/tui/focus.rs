use crate::error::{Error, Result};
use crate::gql::GqlClient;
use crate::gql::endpoints;
use crate::gql::query_ids::Operation;
use crate::model::Tweet;
use crate::parse::timeline::{self, TimelinePage};
use serde_json::Value;

#[derive(Debug)]
pub struct TweetDetail {
    pub tweet: Tweet,
    pub replies: Vec<Tweet>,
    pub loading: bool,
    pub error: Option<String>,
    pub selected: usize,
}

impl TweetDetail {
    pub fn new(tweet: Tweet) -> Self {
        Self {
            tweet,
            replies: Vec::new(),
            loading: true,
            error: None,
            selected: 0,
        }
    }

    pub fn apply_page(&mut self, page: TimelinePage) {
        self.loading = false;
        let focal_id = self.tweet.rest_id.clone();
        self.replies = page
            .tweets
            .into_iter()
            .filter(|t| {
                t.rest_id != focal_id && t.in_reply_to_tweet_id.as_deref() == Some(&focal_id)
            })
            .collect();
        self.selected = 0;
    }

    pub fn select_next(&mut self) {
        if !self.replies.is_empty() && self.selected + 1 < self.replies.len() {
            self.selected += 1;
        }
    }

    pub fn select_prev(&mut self) {
        if self.selected > 0 {
            self.selected -= 1;
        }
    }

    pub fn selected_reply(&self) -> Option<&Tweet> {
        self.replies.get(self.selected)
    }
}

#[derive(Debug)]
pub enum FocusEntry {
    Tweet(TweetDetail),
}

impl FocusEntry {
    pub fn focal_id(&self) -> &str {
        match self {
            Self::Tweet(d) => &d.tweet.rest_id,
        }
    }
}

pub async fn fetch_thread(client: &GqlClient, focal_tweet_id: &str) -> Result<TimelinePage> {
    let response = client
        .get(
            Operation::TweetDetail,
            &endpoints::tweet_detail_variables(focal_tweet_id, None),
            &endpoints::tweet_read_features(),
        )
        .await?;

    let instructions = response
        .pointer("/data/threaded_conversation_with_injections_v2/instructions")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .ok_or_else(|| Error::GraphqlShape("missing thread instructions".into()))?;

    Ok(timeline::walk(instructions))
}
