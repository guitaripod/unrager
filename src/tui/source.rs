use crate::error::{Error, Result};
use crate::gql::GqlClient;
use crate::gql::endpoints;
use crate::gql::query_ids::Operation;
use crate::model::Tweet;
use crate::parse::timeline::{self, TimelinePage};
use serde_json::Value;

const PAGE_SIZE: u32 = 20;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SourceKind {
    Home { following: bool },
}

impl SourceKind {
    pub fn title(&self) -> String {
        match self {
            Self::Home { following: false } => "home: For You".into(),
            Self::Home { following: true } => "home: Following".into(),
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
    pub selected: usize,
    pub scroll_offset: usize,
}

impl Source {
    pub fn new(kind: SourceKind) -> Self {
        Self {
            kind: Some(kind),
            ..Self::default()
        }
    }

    pub fn title(&self) -> String {
        self.kind
            .as_ref()
            .map(SourceKind::title)
            .unwrap_or_else(|| "(empty)".to_string())
    }

    pub fn reset_with(&mut self, page: TimelinePage) {
        self.tweets = page.tweets;
        self.cursor = page.next_cursor;
        self.exhausted = self.cursor.is_none();
        self.selected = 0;
        self.scroll_offset = 0;
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
        if self.selected + 1 < self.tweets.len() {
            self.selected += 1;
        }
    }

    pub fn select_prev(&mut self) {
        if self.selected > 0 {
            self.selected -= 1;
        }
    }

    pub fn jump_top(&mut self) {
        self.selected = 0;
        self.scroll_offset = 0;
    }

    pub fn jump_bottom(&mut self) {
        if !self.tweets.is_empty() {
            self.selected = self.tweets.len() - 1;
        }
    }

    pub fn near_bottom(&self) -> bool {
        if self.tweets.is_empty() {
            return true;
        }
        self.selected + 5 >= self.tweets.len()
    }
}

pub async fn fetch_page(
    client: &GqlClient,
    kind: &SourceKind,
    cursor: Option<String>,
) -> Result<TimelinePage> {
    match kind {
        SourceKind::Home { following } => fetch_home(client, *following, cursor).await,
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
