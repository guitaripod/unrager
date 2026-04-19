use serde::{Deserialize, Serialize};

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
            Self::Mentions { target: Some(h) } => format!("mentions of @{h}"),
            Self::Bookmarks { query } => {
                if query.is_empty() {
                    "bookmarks".into()
                } else {
                    format!("bookmarks: {query}")
                }
            }
        }
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FeedMode {
    #[default]
    All,
    Originals,
}
