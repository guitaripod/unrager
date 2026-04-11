use serde::{Deserialize, Serialize};
use std::collections::HashMap;

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
    Notifications,
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
            Self::Notifications => "Notifications",
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

    pub fn get(&self, op: Operation) -> Option<&QueryId> {
        self.entries.get(op.name())
    }

    pub fn insert(&mut self, qid: QueryId) {
        self.entries.insert(qid.operation.clone(), qid);
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
];
