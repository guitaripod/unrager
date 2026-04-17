use crate::error::{Error, Result};
use crate::gql::GqlClient;
use crate::gql::endpoints;
use crate::gql::query_ids::Operation;
use crate::model::{Tweet, User};
use crate::parse::notification::{NotificationPage, RawNotification};
use crate::parse::timeline::{self, TimelinePage};
use crate::tui::app::ReplySortOrder;
use crate::tui::ask::AskView;
use crate::tui::brief::BriefView;
use crate::tui::compose::ReplyBar;
use crate::tui::source::PaneState;
use serde_json::Value;
use std::collections::{HashMap, HashSet};

#[derive(Debug)]
pub struct TweetDetail {
    pub tweet: Tweet,
    pub replies: Vec<Tweet>,
    pub loading: bool,
    pub error: Option<String>,
    pub state: PaneState,
    pub reply_bar: Option<ReplyBar>,
    pub new_reply_ids: HashSet<String>,
}

impl TweetDetail {
    pub fn new(tweet: Tweet) -> Self {
        Self {
            tweet,
            replies: Vec::new(),
            loading: true,
            error: None,
            state: PaneState::default(),
            reply_bar: None,
            new_reply_ids: HashSet::new(),
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
        self.state = PaneState::default();
    }

    pub fn merge_refreshed_replies(&mut self, page: TimelinePage) {
        let focal_id = &self.tweet.rest_id;
        let existing: HashSet<String> = self.replies.iter().map(|t| t.rest_id.clone()).collect();
        let new_replies: Vec<Tweet> = page
            .tweets
            .into_iter()
            .filter(|t| {
                t.rest_id != *focal_id
                    && t.in_reply_to_tweet_id.as_deref() == Some(focal_id.as_str())
                    && !existing.contains(&t.rest_id)
            })
            .collect();
        if !new_replies.is_empty() {
            tracing::info!(
                focal_id,
                count = new_replies.len(),
                "new replies merged from refresh"
            );
        }
        for t in &new_replies {
            self.new_reply_ids.insert(t.rest_id.clone());
        }
        self.replies.extend(new_replies);
    }

    pub fn total_items(&self) -> usize {
        1 + self.replies.len()
    }

    pub fn selected(&self) -> usize {
        self.state.selected
    }

    pub fn select_next(&mut self) {
        let total = self.total_items();
        if total == 0 {
            return;
        }
        let current = self.selected();
        if current + 1 < total {
            self.state.selected = current + 1;
        }
    }

    pub fn select_prev(&mut self) {
        let current = self.selected();
        if current > 0 {
            self.state.selected = current - 1;
        }
    }

    pub fn advance(&mut self, delta: isize) {
        let total = self.total_items() as isize;
        if total == 0 {
            return;
        }
        let current = self.selected() as isize;
        let next = (current + delta).clamp(0, total - 1) as usize;
        self.state.selected = next;
    }

    pub fn jump_top(&mut self) {
        self.state = PaneState::default();
    }

    pub fn jump_bottom(&mut self) {
        let total = self.total_items();
        if total > 0 {
            self.state.selected = total - 1;
        }
    }

    pub fn sort_replies(&mut self, order: ReplySortOrder) {
        match order {
            ReplySortOrder::Newest => self
                .replies
                .sort_by_key(|t| std::cmp::Reverse(t.created_at)),
            ReplySortOrder::Likes => self
                .replies
                .sort_by_key(|t| std::cmp::Reverse(t.like_count)),
            ReplySortOrder::Replies => self
                .replies
                .sort_by_key(|t| std::cmp::Reverse(t.reply_count)),
            ReplySortOrder::Retweets => self
                .replies
                .sort_by_key(|t| std::cmp::Reverse(t.retweet_count)),
            ReplySortOrder::Views => self
                .replies
                .sort_by_key(|t| std::cmp::Reverse(t.view_count.unwrap_or(0))),
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
pub struct LikersView {
    pub tweet_id: String,
    pub title: String,
    pub users: Vec<User>,
    pub cursor: Option<String>,
    pub loading: bool,
    pub exhausted: bool,
    pub error: Option<String>,
    pub state: PaneState,
}

impl LikersView {
    pub fn new(tweet_id: String, title: String) -> Self {
        Self {
            tweet_id,
            title,
            users: Vec::new(),
            cursor: None,
            loading: true,
            exhausted: false,
            error: None,
            state: PaneState::default(),
        }
    }

    pub fn selected(&self) -> usize {
        self.state.selected
    }

    pub fn select_next(&mut self) {
        if self.users.is_empty() {
            return;
        }
        let current = self.selected();
        if current + 1 < self.users.len() {
            self.state.selected = current + 1;
        }
    }

    pub fn select_prev(&mut self) {
        let current = self.selected();
        if current > 0 {
            self.state.selected = current - 1;
        }
    }

    pub fn advance(&mut self, delta: isize) {
        if self.users.is_empty() {
            return;
        }
        let current = self.selected() as isize;
        let next = (current + delta).clamp(0, self.users.len() as isize - 1) as usize;
        self.state.selected = next;
    }

    pub fn jump_top(&mut self) {
        self.state = PaneState::default();
    }

    pub fn jump_bottom(&mut self) {
        if !self.users.is_empty() {
            self.state.selected = self.users.len() - 1;
        }
    }

    pub fn near_bottom(&self) -> bool {
        if self.users.is_empty() {
            return true;
        }
        self.selected() + 5 >= self.users.len()
    }

    pub fn selected_user(&self) -> Option<&User> {
        self.users.get(self.selected())
    }
}

#[derive(Debug, Default)]
pub struct NotificationsView {
    pub notifications: Vec<RawNotification>,
    pub cursor: Option<String>,
    pub loading: bool,
    pub silent_refreshing: bool,
    pub exhausted: bool,
    pub error: Option<String>,
    pub state: PaneState,
    pub actor_cursor: Option<usize>,
}

impl NotificationsView {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn selected(&self) -> usize {
        self.state.selected
    }

    pub fn set_selected(&mut self, idx: usize) {
        self.state.selected = idx;
    }

    pub fn len(&self) -> usize {
        self.notifications.len()
    }

    pub fn is_empty(&self) -> bool {
        self.notifications.is_empty()
    }

    pub fn select_next(&mut self) {
        if self.is_empty() {
            return;
        }
        let current = self.selected();
        if current + 1 < self.len() {
            self.set_selected(current + 1);
        }
    }

    pub fn select_prev(&mut self) {
        let current = self.selected();
        if current > 0 {
            self.set_selected(current - 1);
        }
    }

    pub fn advance(&mut self, delta: isize) {
        if self.is_empty() {
            return;
        }
        let current = self.selected() as isize;
        let next = (current + delta).clamp(0, self.len() as isize - 1) as usize;
        self.set_selected(next);
    }

    pub fn jump_top(&mut self) {
        self.state = PaneState::default();
    }

    pub fn jump_bottom(&mut self) {
        if !self.is_empty() {
            self.set_selected(self.len() - 1);
        }
    }

    pub fn near_bottom(&self) -> bool {
        if self.is_empty() {
            return true;
        }
        self.selected() + 5 >= self.len()
    }

    pub fn reset_with(&mut self, page: NotificationPage) {
        self.notifications = page
            .notifications
            .into_iter()
            .filter(is_actionable_notification)
            .collect();
        self.cursor = page.next_cursor;
        self.exhausted = self.cursor.is_none();
        let last = self.notifications.len().saturating_sub(1);
        let current = self.state.selected.min(last);
        self.state = PaneState::with_selected(current);
        self.actor_cursor = None;
    }

    pub fn append(&mut self, page: NotificationPage) {
        let existing: HashSet<&str> = self.notifications.iter().map(|n| n.id.as_str()).collect();
        let deduped: Vec<RawNotification> = page
            .notifications
            .into_iter()
            .filter(is_actionable_notification)
            .filter(|n| !existing.contains(n.id.as_str()))
            .collect();
        let incoming = deduped.len();
        self.notifications.extend(deduped);
        self.cursor = page.next_cursor;
        if self.cursor.is_none() || incoming == 0 {
            self.exhausted = true;
        }
    }
}

fn is_actionable_notification(n: &RawNotification) -> bool {
    !matches!(
        n.notification_type.as_str(),
        "Recommendation" | "System" | "Trending" | "Topic" | "Spaces" | "Community" | "List"
    )
}

#[derive(Debug)]
#[allow(clippy::large_enum_variant)]
pub enum FocusEntry {
    Tweet(TweetDetail),
    Likers(LikersView),
    Notifications(NotificationsView),
    Ask(AskView),
    Brief(BriefView),
}

impl FocusEntry {
    pub fn focal_id(&self) -> &str {
        match self {
            Self::Tweet(d) => &d.tweet.rest_id,
            Self::Likers(l) => &l.tweet_id,
            Self::Notifications(_) => "notifications",
            Self::Ask(a) => a.tweet_id(),
            Self::Brief(b) => &b.handle,
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

    let instructions = timeline::extract_instructions(
        &response,
        "/data/threaded_conversation_with_injections_v2/instructions",
    )?;
    Ok(timeline::walk(instructions))
}

const MAX_RECURSIVE_FETCHES: usize = 20;

pub async fn fetch_thread_recursive(
    client: &GqlClient,
    focal_tweet_id: &str,
) -> Result<TimelinePage> {
    let mut all_tweets: HashMap<String, Tweet> = HashMap::new();
    let mut fetched: HashSet<String> = HashSet::new();
    let mut queue: Vec<String> = vec![focal_tweet_id.to_string()];

    while let Some(tweet_id) = queue.pop() {
        if !fetched.insert(tweet_id.clone()) {
            continue;
        }
        if fetched.len() > MAX_RECURSIVE_FETCHES {
            break;
        }
        let page = match fetch_thread(client, &tweet_id).await {
            Ok(p) => p,
            Err(e) => {
                if fetched.len() == 1 {
                    return Err(e);
                }
                continue;
            }
        };
        for tweet in page.tweets {
            all_tweets.entry(tweet.rest_id.clone()).or_insert(tweet);
        }

        let has_child: HashSet<&str> = all_tweets
            .values()
            .filter_map(|t| t.in_reply_to_tweet_id.as_deref())
            .collect();
        for tweet in all_tweets.values() {
            if tweet.reply_count > 0
                && !has_child.contains(tweet.rest_id.as_str())
                && !fetched.contains(&tweet.rest_id)
            {
                queue.push(tweet.rest_id.clone());
            }
        }
    }

    Ok(TimelinePage {
        tweets: all_tweets.into_values().collect(),
        next_cursor: None,
        top_cursor: None,
    })
}

#[derive(Debug, Default)]
pub struct LikersPage {
    pub users: Vec<User>,
    pub next_cursor: Option<String>,
}

pub async fn fetch_likers(
    client: &GqlClient,
    tweet_id: &str,
    cursor: Option<&str>,
) -> Result<LikersPage> {
    let response = client
        .get(
            Operation::Favoriters,
            &endpoints::favoriters_variables(tweet_id, 50, cursor),
            &endpoints::favoriters_features(),
        )
        .await?;

    let instructions = response
        .pointer("/data/favoriters_timeline/timeline/instructions")
        .and_then(Value::as_array)
        .ok_or_else(|| Error::GraphqlShape("missing favoriters instructions".into()))?;

    let mut page = LikersPage::default();
    for instr in instructions {
        let instr_type = instr.get("type").and_then(Value::as_str).unwrap_or("");
        match instr_type {
            "TimelineAddEntries" | "TimelineReplaceEntry" => {
                let entries = instr.get("entries").and_then(Value::as_array);
                let Some(entries) = entries else { continue };
                for entry in entries {
                    let entry_id = entry.get("entryId").and_then(Value::as_str).unwrap_or("");
                    if entry_id.starts_with("cursor-bottom-") {
                        if let Some(v) = entry.pointer("/content/value").and_then(Value::as_str) {
                            page.next_cursor = Some(v.to_string());
                        }
                        continue;
                    }
                    if entry_id.starts_with("cursor-top-") {
                        continue;
                    }
                    let user_result = entry
                        .pointer("/content/itemContent/user_results/result")
                        .or_else(|| entry.pointer("/content/item/itemContent/user_results/result"));
                    let Some(user_result) = user_result else {
                        continue;
                    };
                    if let Some(u) = crate::parse::user::parse_user_result(user_result) {
                        page.users.push(u);
                    }
                }
            }
            _ => {}
        }
    }

    Ok(page)
}
