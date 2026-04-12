use crate::error::{Error, Result};
use crate::gql::GqlClient;
use crate::gql::endpoints;
use crate::gql::query_ids::Operation;
use crate::model::Tweet;
use crate::parse::timeline::{self, TimelinePage};
use ratatui::widgets::ListState;
use serde::{Deserialize, Serialize};
use serde_json::Value;

const PAGE_SIZE: u32 = 20;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum SourceKind {
    Home {
        following: bool,
    },
    User {
        handle: String,
    },
    Search {
        query: String,
        product: SearchProduct,
    },
    Mentions {
        target: Option<String>,
    },
    Bookmarks {
        query: String,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SearchProduct {
    Top,
    Latest,
    People,
    Photos,
    Videos,
}

impl SearchProduct {
    pub const fn as_api(self) -> &'static str {
        match self {
            Self::Top => "Top",
            Self::Latest => "Latest",
            Self::People => "People",
            Self::Photos => "Photos",
            Self::Videos => "Videos",
        }
    }
}

impl SourceKind {
    pub fn title(&self) -> String {
        match self {
            Self::Home { following: false } => "home: For You".into(),
            Self::Home { following: true } => "home: Following".into(),
            Self::User { handle } => format!("user: @{handle}"),
            Self::Search { query, product } => {
                format!("search: {query}  [{}]", product.as_api())
            }
            Self::Mentions { target: None } => "mentions".into(),
            Self::Mentions { target: Some(h) } => format!("mentions: @{h}"),
            Self::Bookmarks { query } => format!("bookmarks: {query}"),
        }
    }
}

#[derive(Debug, Default)]
pub struct Source {
    pub kind: Option<SourceKind>,
    pub tweets: Vec<Tweet>,
    pub cursor: Option<String>,
    pub loading: bool,
    pub exhausted: bool,
    pub list_state: ListState,
}

impl Source {
    pub fn new(kind: SourceKind) -> Self {
        let mut list_state = ListState::default();
        list_state.select(Some(0));
        Self {
            kind: Some(kind),
            list_state,
            ..Self::default()
        }
    }

    pub fn title(&self) -> String {
        self.kind
            .as_ref()
            .map(SourceKind::title)
            .unwrap_or_else(|| "(empty)".to_string())
    }

    pub fn selected(&self) -> usize {
        self.list_state.selected().unwrap_or(0)
    }

    pub fn set_selected(&mut self, index: usize) {
        self.list_state.select(Some(index));
    }

    pub fn reset_with(&mut self, page: TimelinePage) {
        self.tweets = page.tweets;
        self.cursor = page.next_cursor;
        self.exhausted = self.cursor.is_none();
        let last = self.tweets.len().saturating_sub(1);
        let current = self.list_state.selected().unwrap_or(0).min(last);
        self.list_state = ListState::default();
        self.list_state.select(Some(current));
        if !self.tweets.is_empty() {
            *self.list_state.offset_mut() = 0;
        }
    }

    pub fn append(&mut self, page: TimelinePage) {
        let incoming = page.tweets.len();
        self.tweets.extend(page.tweets);
        self.cursor = page.next_cursor;
        if self.cursor.is_none() || incoming == 0 {
            self.exhausted = true;
        }
    }

    pub fn select_next(&mut self) {
        if self.tweets.is_empty() {
            return;
        }
        let current = self.selected();
        if current + 1 < self.tweets.len() {
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
        if self.tweets.is_empty() {
            return;
        }
        let current = self.selected() as isize;
        let next = (current + delta).clamp(0, self.tweets.len() as isize - 1) as usize;
        self.set_selected(next);
    }

    pub fn jump_top(&mut self) {
        self.set_selected(0);
        *self.list_state.offset_mut() = 0;
    }

    pub fn jump_bottom(&mut self) {
        if !self.tweets.is_empty() {
            self.set_selected(self.tweets.len() - 1);
        }
    }

    pub fn near_bottom(&self) -> bool {
        if self.tweets.is_empty() {
            return true;
        }
        self.selected() + 5 >= self.tweets.len()
    }
}

pub async fn fetch_page(
    client: &GqlClient,
    kind: &SourceKind,
    cursor: Option<String>,
) -> Result<TimelinePage> {
    match kind {
        SourceKind::Home { following } => fetch_home(client, *following, cursor).await,
        SourceKind::User { handle } => fetch_user(client, handle, cursor).await,
        SourceKind::Search { query, product } => {
            fetch_search(client, query, product.as_api(), cursor).await
        }
        SourceKind::Mentions { target } => {
            let handle = match target {
                Some(h) => h.clone(),
                None => fetch_self_handle(client).await?,
            };
            let query = format!("@{handle} -from:{handle}");
            fetch_search(client, &query, "Latest", cursor).await
        }
        SourceKind::Bookmarks { query } => fetch_bookmarks(client, query, cursor).await,
    }
}

async fn fetch_home(
    client: &GqlClient,
    following: bool,
    cursor: Option<String>,
) -> Result<TimelinePage> {
    let op = if following {
        Operation::HomeLatestTimeline
    } else {
        Operation::HomeTimeline
    };
    let response = client
        .post(
            op,
            &endpoints::home_timeline_variables(PAGE_SIZE, cursor.as_deref()),
            &endpoints::home_timeline_features(),
        )
        .await?;

    let instructions = response
        .pointer("/data/home/home_timeline_urt/instructions")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .ok_or_else(|| Error::GraphqlShape("missing home timeline instructions".into()))?;

    Ok(timeline::walk(instructions))
}

async fn fetch_user(
    client: &GqlClient,
    handle: &str,
    cursor: Option<String>,
) -> Result<TimelinePage> {
    let user_id = resolve_user_id(client, handle).await?;
    let response = client
        .get(
            Operation::UserTweets,
            &endpoints::user_tweets_variables(&user_id, PAGE_SIZE, cursor.as_deref()),
            &endpoints::user_tweets_features(),
        )
        .await?;

    let instructions = response
        .pointer("/data/user/result/timeline/timeline/instructions")
        .or_else(|| response.pointer("/data/user/result/timeline_v2/timeline/instructions"))
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .ok_or_else(|| Error::GraphqlShape("missing user tweets instructions".into()))?;

    Ok(timeline::walk(instructions))
}

async fn resolve_user_id(client: &GqlClient, handle: &str) -> Result<String> {
    let response = client
        .get(
            Operation::UserByScreenName,
            &endpoints::user_by_screen_name_variables(handle),
            &endpoints::user_by_screen_name_features(),
        )
        .await?;
    let user = response
        .pointer("/data/user/result")
        .ok_or_else(|| Error::GraphqlShape(format!("no such user: @{handle}")))?;
    let typename = user.get("__typename").and_then(Value::as_str).unwrap_or("");
    if typename == "UserUnavailable" {
        return Err(Error::GraphqlShape(format!(
            "@{handle} is unavailable (suspended, deactivated, or protected)"
        )));
    }
    user.get("rest_id")
        .and_then(Value::as_str)
        .map(str::to_string)
        .ok_or_else(|| Error::GraphqlShape(format!("@{handle} has no rest_id")))
}

async fn fetch_search(
    client: &GqlClient,
    query: &str,
    product: &str,
    cursor: Option<String>,
) -> Result<TimelinePage> {
    let response = client
        .post(
            Operation::SearchTimeline,
            &endpoints::search_timeline_variables(query, PAGE_SIZE, product, cursor.as_deref()),
            &endpoints::search_timeline_features(),
        )
        .await?;
    let instructions = response
        .pointer("/data/search_by_raw_query/search_timeline/timeline/instructions")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .ok_or_else(|| Error::GraphqlShape("missing search instructions".into()))?;
    Ok(timeline::walk(instructions))
}

async fn fetch_bookmarks(
    client: &GqlClient,
    query: &str,
    cursor: Option<String>,
) -> Result<TimelinePage> {
    let response = client
        .get(
            Operation::BookmarkSearchTimeline,
            &endpoints::bookmark_search_variables(query, PAGE_SIZE, cursor.as_deref()),
            &endpoints::bookmark_search_features(),
        )
        .await?;
    let instructions = response
        .pointer("/data/search_by_raw_query/bookmarks_search_timeline/timeline/instructions")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .ok_or_else(|| Error::GraphqlShape("missing bookmark timeline instructions".into()))?;
    Ok(timeline::walk(instructions))
}

pub async fn fetch_self_handle(client: &GqlClient) -> Result<String> {
    let response = client
        .get(
            Operation::Viewer,
            &endpoints::viewer_variables(),
            &endpoints::viewer_features(),
        )
        .await?;
    Ok(crate::parse::viewer::parse(&response)?.handle)
}

pub async fn fetch_single_tweet(client: &GqlClient, id: &str) -> Result<Tweet> {
    let response = client
        .get(
            Operation::TweetResultByRestId,
            &endpoints::tweet_by_rest_id_variables(id),
            &endpoints::tweet_read_features(),
        )
        .await?;
    crate::parse::tweet::parse_tweet_result_by_rest_id(&response)
}
