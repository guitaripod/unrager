//! Fills in the posts a quote of a quote leaves out. X sends a quote's post
//! whole, but the post inside that one only as a reference (see
//! `Tweet::quoted_tweet_id`), so the server fetches those and clients get a
//! tree of up to [`MAX_QUOTE_LAYERS`] quotes under the post they opened.

use crate::error::Error;
use crate::gql::GqlClient;
use crate::server::state::fetch_tweet;
use futures::future::BoxFuture;
use futures::stream::{FuturesUnordered, StreamExt};
use lru::LruCache;
use std::num::NonZeroUsize;
use std::sync::{Mutex, PoisonError};
use std::time::{Duration, Instant};
use unrager_model::Tweet;

/// How many quotes deep a post's tree goes: the post it quotes, the post that
/// one quotes, and the post that one quotes.
pub const MAX_QUOTE_LAYERS: usize = 3;

const REMEMBERED: NonZeroUsize = NonZeroUsize::new(512).unwrap();
const REMEMBERED_FOR: Duration = Duration::from_secs(15 * 60);
const FETCH_TIMEOUT: Duration = Duration::from_secs(3);
const FETCH_CONCURRENCY: usize = 4;

/// Asks for one quoted post by id.
pub type FetchQuoted<'f> = &'f (dyn Fn(String) -> BoxFuture<'static, Fetched> + Sync);

/// What asking X for one quoted post came to.
pub enum Fetched {
    Post(Box<Tweet>),
    /// Deleted, protected or otherwise withheld: not worth asking again soon.
    Gone,
    /// The request failed or timed out; a later one may work.
    Failed,
}

/// The quoted posts fetched so far, kept for [`REMEMBERED_FOR`] so a feed
/// scrolled back through (or one post quoted by many) costs one request.
pub struct QuoteHydrator {
    fetched: Mutex<LruCache<String, (Instant, Option<Tweet>)>>,
}

impl QuoteHydrator {
    pub fn new() -> Self {
        Self {
            fetched: Mutex::new(LruCache::new(REMEMBERED)),
        }
    }

    /// Gives every post in `tweets` its quote tree, fetching what X left out
    /// through `fetch` (four at a time). A post whose quote can't be fetched
    /// keeps the layers it has.
    pub async fn hydrate(&self, tweets: &mut [Tweet], fetch: FetchQuoted<'_>) {
        let mut waiting = tweets.iter_mut();
        let mut running = FuturesUnordered::new();
        loop {
            while running.len() < FETCH_CONCURRENCY {
                let Some(tweet) = waiting.next() else { break };
                running.push(self.fill(tweet, fetch));
            }
            if running.next().await.is_none() {
                break;
            }
        }
    }

    /// Walks down `root`'s chain of quotes, attaching each missing post, until
    /// [`MAX_QUOTE_LAYERS`] layers hang under it or the chain ends.
    async fn fill(&self, root: &mut Tweet, fetch: FetchQuoted<'_>) {
        let mut node = root;
        for _ in 0..MAX_QUOTE_LAYERS {
            if node.quoted_tweet.is_none() {
                let Some(id) = node.quoted_tweet_id.take() else {
                    return;
                };
                match self.lookup(&id, fetch).await {
                    Some(quoted) => node.quoted_tweet = Some(Box::new(quoted)),
                    None => {
                        node.quoted_tweet_id = Some(id);
                        return;
                    }
                }
            }
            let Some(next) = node.quoted_tweet.as_deref_mut() else {
                return;
            };
            node = next;
        }
    }

    /// A quoted post from the memory or from `fetch`, remembering what X
    /// answered for good (a post, or that it is gone) but not a failure.
    async fn lookup(&self, id: &str, fetch: FetchQuoted<'_>) -> Option<Tweet> {
        if let Some(known) = self.recall(id) {
            return known;
        }
        let answer = match fetch(id.to_string()).await {
            Fetched::Post(post) => Some(*post),
            Fetched::Gone => None,
            Fetched::Failed => return None,
        };
        self.fetched
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .put(id.to_string(), (Instant::now(), answer.clone()));
        answer
    }

    fn recall(&self, id: &str) -> Option<Option<Tweet>> {
        let mut fetched = self.fetched.lock().unwrap_or_else(PoisonError::into_inner);
        match fetched.get(id) {
            Some((at, answer)) if at.elapsed() < REMEMBERED_FOR => Some(answer.clone()),
            _ => None,
        }
    }
}

impl Default for QuoteHydrator {
    fn default() -> Self {
        Self::new()
    }
}

/// One quoted post from X, giving up after [`FETCH_TIMEOUT`] so a slow answer
/// never holds a whole timeline page back.
pub async fn fetch_quoted(gql: &GqlClient, id: String) -> Fetched {
    match tokio::time::timeout(FETCH_TIMEOUT, fetch_tweet(gql, &id)).await {
        Ok(Ok(post)) => Fetched::Post(Box::new(post)),
        Ok(Err(Error::NotFound(_) | Error::Unavailable { .. })) => Fetched::Gone,
        Ok(Err(e)) => {
            tracing::debug!(quoted = %id, "quoted post fetch failed: {e}");
            Fetched::Failed
        }
        Err(_) => {
            tracing::debug!(quoted = %id, "quoted post fetch timed out");
            Fetched::Failed
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tui::test_util::make_tweet;
    use std::collections::HashMap;
    use std::sync::atomic::{AtomicUsize, Ordering};

    fn post(id: &str, quotes: Option<&str>, quotes_whole: Option<Tweet>) -> Tweet {
        let mut tweet = make_tweet(id, "text");
        tweet.quoted_tweet_id = quotes.map(str::to_string);
        tweet.quoted_tweet = quotes_whole.map(Box::new);
        tweet
    }

    fn depth(tweet: &Tweet) -> usize {
        tweet.quoted_tweet.as_deref().map_or(0, |q| 1 + depth(q))
    }

    /// A fetcher over `posts` that counts its calls.
    fn fetcher(
        posts: Vec<Tweet>,
        calls: &AtomicUsize,
    ) -> Box<dyn Fn(String) -> BoxFuture<'static, Fetched> + Sync + '_> {
        let by_id: HashMap<String, Tweet> =
            posts.into_iter().map(|t| (t.rest_id.clone(), t)).collect();
        Box::new(move |id| {
            calls.fetch_add(1, Ordering::SeqCst);
            let answer = match by_id.get(&id) {
                Some(t) => Fetched::Post(Box::new(t.clone())),
                None => Fetched::Gone,
            };
            Box::pin(std::future::ready(answer))
        })
    }

    #[tokio::test]
    async fn a_quote_of_a_quote_gets_the_posts_below_it() {
        let q3 = post("q3", Some("q4"), None);
        let q2 = post("q2", Some("q3"), Some(q3));
        let q1 = post("q1", Some("q2"), None);
        let mut top = post("top", None, Some(q1));
        let calls = AtomicUsize::new(0);
        QuoteHydrator::new()
            .hydrate(std::slice::from_mut(&mut top), &fetcher(vec![q2], &calls))
            .await;
        assert_eq!(depth(&top), MAX_QUOTE_LAYERS);
        assert_eq!(calls.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn the_tree_stops_at_three_layers() {
        let posts: Vec<Tweet> = (2..10)
            .map(|n| post(&format!("q{n}"), Some(&format!("q{}", n + 1)), None))
            .collect();
        let q1 = post("q1", Some("q2"), None);
        let mut top = post("top", None, Some(q1));
        let calls = AtomicUsize::new(0);
        QuoteHydrator::new()
            .hydrate(std::slice::from_mut(&mut top), &fetcher(posts, &calls))
            .await;
        assert_eq!(depth(&top), MAX_QUOTE_LAYERS);
        assert_eq!(calls.load(Ordering::SeqCst), 2);
    }

    #[tokio::test]
    async fn a_post_that_quotes_nothing_is_left_alone() {
        let mut plain = post("plain", None, None);
        let calls = AtomicUsize::new(0);
        QuoteHydrator::new()
            .hydrate(std::slice::from_mut(&mut plain), &fetcher(vec![], &calls))
            .await;
        assert_eq!(depth(&plain), 0);
        assert_eq!(calls.load(Ordering::SeqCst), 0);
    }

    #[tokio::test]
    async fn a_gone_post_keeps_its_reference_and_is_asked_for_once() {
        let hydrator = QuoteHydrator::new();
        let calls = AtomicUsize::new(0);
        let fetch = fetcher(vec![], &calls);
        let mut a = post("a", Some("deleted"), None);
        let mut b = post("b", Some("deleted"), None);
        hydrator.hydrate(std::slice::from_mut(&mut a), &fetch).await;
        hydrator.hydrate(std::slice::from_mut(&mut b), &fetch).await;
        assert_eq!(depth(&a), 0);
        assert_eq!(a.quoted_tweet_id.as_deref(), Some("deleted"));
        assert_eq!(calls.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn a_failed_fetch_is_tried_again_next_time() {
        let hydrator = QuoteHydrator::new();
        let calls = AtomicUsize::new(0);
        let failing = |_: String| -> BoxFuture<'static, Fetched> {
            calls.fetch_add(1, Ordering::SeqCst);
            Box::pin(std::future::ready(Fetched::Failed))
        };
        let mut a = post("a", Some("q"), None);
        hydrator
            .hydrate(std::slice::from_mut(&mut a), &failing)
            .await;
        hydrator
            .hydrate(std::slice::from_mut(&mut a), &failing)
            .await;
        assert_eq!(calls.load(Ordering::SeqCst), 2);
        assert_eq!(a.quoted_tweet_id.as_deref(), Some("q"));
    }

    #[tokio::test]
    async fn posts_quoting_the_same_post_share_what_was_fetched() {
        let hydrator = QuoteHydrator::new();
        let calls = AtomicUsize::new(0);
        let target = post("shared", None, None);
        let mut posts: Vec<Tweet> = (0..5)
            .map(|n| post(&format!("p{n}"), Some("shared"), None))
            .collect();
        hydrator
            .hydrate(&mut posts, &fetcher(vec![target], &calls))
            .await;
        assert!(posts.iter().all(|p| depth(p) == 1));
        assert!(calls.load(Ordering::SeqCst) <= FETCH_CONCURRENCY);
        let again = AtomicUsize::new(0);
        let mut more = post("p9", Some("shared"), None);
        hydrator
            .hydrate(std::slice::from_mut(&mut more), &fetcher(vec![], &again))
            .await;
        assert_eq!(depth(&more), 1);
        assert_eq!(again.load(Ordering::SeqCst), 0);
    }
}
