use crate::error::Result;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::Path;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "PascalCase")]
pub enum Operation {
    Viewer,
    TweetResultByRestId,
    TweetDetail,
    HomeTimeline,
    HomeLatestTimeline,
    UserByScreenName,
    UserTweets,
    SearchTimeline,
    Bookmarks,
    BookmarkSearchTimeline,
    Favoriters,
}

impl Operation {
    pub const fn name(self) -> &'static str {
        match self {
            Self::Viewer => "Viewer",
            Self::TweetResultByRestId => "TweetResultByRestId",
            Self::TweetDetail => "TweetDetail",
            Self::HomeTimeline => "HomeTimeline",
            Self::HomeLatestTimeline => "HomeLatestTimeline",
            Self::UserByScreenName => "UserByScreenName",
            Self::UserTweets => "UserTweets",
            Self::SearchTimeline => "SearchTimeline",
            Self::Bookmarks => "Bookmarks",
            Self::BookmarkSearchTimeline => "BookmarkSearchTimeline",
            Self::Favoriters => "Favoriters",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QueryId {
    pub id: String,
    pub operation: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct QueryIdStore {
    entries: HashMap<String, QueryId>,
}

impl QueryIdStore {
    pub fn with_fallbacks() -> Self {
        let mut entries = HashMap::new();
        for (op, id) in FALLBACK_QUERY_IDS {
            entries.insert(
                (*op).to_string(),
                QueryId {
                    id: (*id).to_string(),
                    operation: (*op).to_string(),
                },
            );
        }
        Self { entries }
    }

    pub fn with_fallbacks_and_cache(cache_path: &Path) -> Self {
        let mut store = Self::with_fallbacks();
        match Self::load_cached(cache_path) {
            Ok(Some(cached)) => {
                tracing::debug!(
                    "loaded {} query ids from cache at {}",
                    cached.entries.len(),
                    cache_path.display()
                );
                store.merge_iter(cached.entries.into_values());
            }
            Ok(None) => {
                tracing::debug!("no query id cache yet; using fallback table");
            }
            Err(e) => {
                tracing::warn!("failed to load query id cache, using fallback only: {e}");
            }
        }
        store
    }

    pub fn get(&self, op: Operation) -> Option<&QueryId> {
        self.entries.get(op.name())
    }

    pub fn merge_iter(&mut self, fresh: impl IntoIterator<Item = QueryId>) {
        for qid in fresh {
            self.entries.insert(qid.operation.clone(), qid);
        }
    }

    pub fn load_cached(path: &Path) -> Result<Option<Self>> {
        match std::fs::read(path) {
            Ok(bytes) => Ok(Some(serde_json::from_slice(&bytes)?)),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(e.into()),
        }
    }

    pub fn save_cached(&self, path: &Path) -> Result<()> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let json = serde_json::to_vec_pretty(self)?;
        std::fs::write(path, json)?;
        tracing::debug!(
            "wrote {} query ids to cache at {}",
            self.entries.len(),
            path.display()
        );
        Ok(())
    }
}

const FALLBACK_QUERY_IDS: &[(&str, &str)] = &[
    ("Viewer", "_8ClT24oZ8tpylf_OSuNdg"),
    ("TweetResultByRestId", "tmhPpO5sDermwYmq3h034A"),
    ("TweetDetail", "rU08O-YiXdr0IZfE7qaUMg"),
    ("HomeTimeline", "Fb7fyZ9MMCzvf_bNtwNdXA"),
    ("HomeLatestTimeline", "2ee46L1AFXmnTa0EvUog-Q"),
    ("UserByScreenName", "IGgvgiOx4QZndDHuD3x9TQ"),
    ("UserTweets", "x3B_xLqC0yZawOB7WQhaVQ"),
    ("SearchTimeline", "pCd62NDD9dlCDgEGgEVHMg"),
    ("Favoriters", "E-ZTxvWWIkmOKwYdNTEefg"),
];
