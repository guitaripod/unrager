use crate::gql::client::GqlClient;
use crate::gql::endpoints;
use crate::gql::query_ids::Operation;
use crate::model::Tweet;
use crate::tui::event::{Event, EventTx};
use std::sync::Arc;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EngageAction {
    Like,
}

impl EngageAction {
    pub fn apply(&self, tweet: &mut Tweet) {
        match self {
            Self::Like => {
                tweet.favorited = !tweet.favorited;
                if tweet.favorited {
                    tweet.like_count += 1;
                } else {
                    tweet.like_count = tweet.like_count.saturating_sub(1);
                }
            }
        }
    }

    pub fn is_engaged(&self, tweet: &Tweet) -> bool {
        match self {
            Self::Like => tweet.favorited,
        }
    }

    pub fn verb(&self, was_engaged: bool) -> &'static str {
        match (self, was_engaged) {
            (Self::Like, false) => "liked",
            (Self::Like, true) => "unliked",
        }
    }

    fn operation(&self, engaged: bool) -> Operation {
        match (self, engaged) {
            (Self::Like, false) => Operation::FavoriteTweet,
            (Self::Like, true) => Operation::UnfavoriteTweet,
        }
    }
}

pub fn dispatch(action: EngageAction, tweet: &Tweet, client: Arc<GqlClient>, tx: EventTx) {
    let rest_id = tweet.rest_id.clone();
    let was_engaged = action.is_engaged(tweet);
    let op = action.operation(was_engaged);
    let variables = endpoints::favorite_variables(&rest_id);
    let features = endpoints::mutation_features();

    tokio::spawn(async move {
        let error = match client.post(op, &variables, &features).await {
            Ok(_) => None,
            Err(e) => {
                tracing::warn!(%rest_id, ?action, "engage failed: {e}");
                Some(e.to_string())
            }
        };
        let _ = tx.send(Event::EngageResult {
            rest_id,
            action,
            error,
        });
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::User;
    use chrono::Utc;

    fn tweet(favorited: bool, like_count: u64) -> Tweet {
        Tweet {
            rest_id: "1".into(),
            author: User {
                rest_id: "u".into(),
                handle: "alice".into(),
                name: "Alice".into(),
                verified: false,
                followers: 0,
                following: 0,
            },
            created_at: Utc::now(),
            text: "test".into(),
            reply_count: 0,
            retweet_count: 10,
            like_count,
            quote_count: 0,
            view_count: None,
            favorited,
            retweeted: false,
            bookmarked: false,
            lang: None,
            in_reply_to_tweet_id: None,
            quoted_tweet: None,
            media: vec![],
            url: "https://x.com/alice/status/1".into(),
        }
    }

    #[test]
    fn like_toggles_favorited_and_count() {
        let mut t = tweet(false, 5);
        EngageAction::Like.apply(&mut t);
        assert!(t.favorited);
        assert_eq!(t.like_count, 6);

        EngageAction::Like.apply(&mut t);
        assert!(!t.favorited);
        assert_eq!(t.like_count, 5);
    }

    #[test]
    fn unlike_at_zero_saturates() {
        let mut t = tweet(true, 0);
        EngageAction::Like.apply(&mut t);
        assert!(!t.favorited);
        assert_eq!(t.like_count, 0);
    }

    #[test]
    fn operation_selects_correct_direction() {
        let t = tweet(false, 0);
        let t_fav = tweet(true, 5);

        assert_eq!(
            EngageAction::Like.operation(EngageAction::Like.is_engaged(&t)),
            Operation::FavoriteTweet
        );
        assert_eq!(
            EngageAction::Like.operation(EngageAction::Like.is_engaged(&t_fav)),
            Operation::UnfavoriteTweet
        );
    }

    #[test]
    fn verb_reflects_direction() {
        assert_eq!(EngageAction::Like.verb(false), "liked");
        assert_eq!(EngageAction::Like.verb(true), "unliked");
    }
}
