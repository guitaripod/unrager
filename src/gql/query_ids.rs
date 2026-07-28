use crate::error::Result;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::Path;

/// Single source of truth for every GraphQL operation. One list generates the
/// `Operation` enum, its wire `name()` (the variant identifier itself),
/// `Operation::ALL`, and the hardcoded `FALLBACK_QUERY_IDS` table — so a new
/// operation cannot be added without extending all of them at once, and the
/// old failure mode (a variant silently missing from the hand-maintained
/// `ALL`/fallback lists) is a compile error instead of a runtime
/// "missing query id".
macro_rules! operations {
    ($(($variant:ident, $fallback_id:literal)),* $(,)?) => {
        #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
        #[serde(rename_all = "PascalCase")]
        pub enum Operation {
            $($variant,)*
        }

        impl Operation {
            pub const ALL: &'static [Self] = &[$(Self::$variant,)*];

            pub const fn name(self) -> &'static str {
                match self {
                    $(Self::$variant => stringify!($variant),)*
                }
            }
        }

        const FALLBACK_QUERY_IDS: &[(&str, &str)] = &[
            $((stringify!($variant), $fallback_id),)*
        ];
    };
}

operations! {
    (Viewer, "5XShkXk2oO2J7SYmTu6pvw"),
    (TweetResultByRestId, "LkId5Akr61BS6BmOIcffRg"),
    (TweetDetail, "559hs_YZNV4IgA3Z6zIIuw"),
    (HomeTimeline, "3tb-_5Lf7kdCZ1cFHmsEfg"),
    (HomeLatestTimeline, "eObmT5Nuapp04u8bYWf49Q"),
    (UserByScreenName, "Gb-d6r0vxPOADdG62OEBpQ"),
    (UserTweets, "eoJ5zbv51Z_KVl81v9PmLQ"),
    (UserTweetsAndReplies, "wc5DRl4VaW5lSqJ8YbftZQ"),
    (SearchTimeline, "BGd0T_j7oVwlW5U79tO_0A"),
    (BookmarkSearchTimeline, "dzUkTX927TOSBQ3Jin7QqQ"),
    (Bookmarks, "tUVliYsHyxrQIT4HXUWNdA"),
    (Favoriters, "E-ZTxvWWIkmOKwYdNTEefg"),
    (Followers, "vJijlO_CM7dyGFNjDd7iqQ"),
    (BlueVerifiedFollowers, "cg6WLW39UujWMeX77xBnOA"),
    (Following, "b8XpwALENnJdFSHchkK6rw"),
    (NotificationsTimeline, "l6ovGrjBwVobgU4puBCycg"),
    (FavoriteTweet, "lI07N6Otwv1PhnEgXILM7A"),
    (UnfavoriteTweet, "ZYKSe-w7KEslx3JhSIk5LA"),
    (CreateRetweet, "mbRO74GrOvSfRcJnlMapnQ"),
    (DeleteRetweet, "ZyZigVsNiFO6v1dEks1eWg"),
    (DeleteTweet, "nxpZCY2K-I6QoFHAHeojFQ"),
    (CreateBookmark, "aoDbu3RHznuiSkQ9aNM67Q"),
    (DeleteBookmark, "Wlmlj2-xzyS1GN3a6cj-mQ"),
    (AboutAccountQuery, "XRqGa7EeokUU5kppkh13EA"),
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

    pub fn apply_config_overrides(
        &mut self,
        overrides: &std::collections::HashMap<String, String>,
    ) {
        for (operation, id) in overrides {
            tracing::info!(operation, id, "query id override from config");
            self.entries.insert(
                operation.clone(),
                QueryId {
                    id: id.clone(),
                    operation: operation.clone(),
                },
            );
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fallback_table_covers_every_operation() {
        let store = QueryIdStore::with_fallbacks();
        for op in Operation::ALL {
            assert!(
                store.get(*op).is_some(),
                "no fallback query id for {}",
                op.name()
            );
        }
    }

    #[test]
    fn all_lists_every_variant_exactly_once() {
        let mut names: Vec<_> = Operation::ALL.iter().map(|op| op.name()).collect();
        names.sort_unstable();
        names.dedup();
        assert_eq!(names.len(), Operation::ALL.len());
        assert_eq!(names.len(), FALLBACK_QUERY_IDS.len());
    }

    #[test]
    fn wire_name_matches_serde_serialization() {
        for op in Operation::ALL {
            let serialized = serde_json::to_value(op).unwrap();
            assert_eq!(serialized, serde_json::Value::String(op.name().to_string()));
        }
    }
}
