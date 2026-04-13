use crate::error::{Error, Result};
use crate::gql::GqlClient;
use crate::gql::endpoints;
use crate::gql::query_ids::Operation;
use crate::model::Tweet;
use crate::parse::timeline::{self, TimelinePage};
use crate::tui::app::ReplySortOrder;
use ratatui::widgets::ListState;
use serde_json::Value;

#[derive(Debug)]
pub struct TweetDetail {
    pub tweet: Tweet,
    pub replies: Vec<Tweet>,
    pub loading: bool,
    pub error: Option<String>,
    pub list_state: ListState,
}

impl TweetDetail {
    pub fn new(tweet: Tweet) -> Self {
        let mut list_state = ListState::default();
        list_state.select(Some(0));
        Self {
            tweet,
            replies: Vec::new(),
            loading: true,
            error: None,
            list_state,
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
        self.list_state = ListState::default();
        self.list_state.select(Some(0));
    }

    pub fn total_items(&self) -> usize {
        1 + self.replies.len()
    }

    pub fn selected(&self) -> usize {
        self.list_state.selected().unwrap_or(0)
    }

    pub fn select_next(&mut self) {
        let total = self.total_items();
        if total == 0 {
            return;
        }
        let current = self.selected();
        if current + 1 < total {
            self.list_state.select(Some(current + 1));
        }
    }

    pub fn select_prev(&mut self) {
        let current = self.selected();
        if current > 0 {
            self.list_state.select(Some(current - 1));
        }
    }

    pub fn advance(&mut self, delta: isize) {
        let total = self.total_items() as isize;
        if total == 0 {
            return;
        }
        let current = self.selected() as isize;
        let next = (current + delta).clamp(0, total - 1) as usize;
        self.list_state.select(Some(next));
    }

    pub fn jump_top(&mut self) {
        self.list_state.select(Some(0));
        *self.list_state.offset_mut() = 0;
    }

    pub fn jump_bottom(&mut self) {
        let total = self.total_items();
        if total > 0 {
            self.list_state.select(Some(total - 1));
        }
    }

    pub fn sort_replies(&mut self, order: ReplySortOrder) {
        match order {
            ReplySortOrder::Newest => self.replies.sort_by(|a, b| b.created_at.cmp(&a.created_at)),
            ReplySortOrder::Likes => self.replies.sort_by(|a, b| b.like_count.cmp(&a.like_count)),
            ReplySortOrder::Replies => self
                .replies
                .sort_by(|a, b| b.reply_count.cmp(&a.reply_count)),
            ReplySortOrder::Retweets => self
                .replies
                .sort_by(|a, b| b.retweet_count.cmp(&a.retweet_count)),
            ReplySortOrder::Views => self
                .replies
                .sort_by(|a, b| b.view_count.unwrap_or(0).cmp(&a.view_count.unwrap_or(0))),
        }
    }

    pub fn selected_reply(&self) -> Option<&Tweet> {
        let sel = self.selected();
        if sel == 0 {
            return None;
        }
        self.replies.get(sel - 1)
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
