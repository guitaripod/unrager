//! The shared materialized-feed store (`feed.db`) and its background ingest
//! worker. A single process holds the writer lock and keeps a small capped
//! buffer of pre-classified Home tweets fresh; every client reads pages from it
//! so opening the app is instant instead of waiting on a live X fetch + Ollama.

pub mod about;
pub mod feed;
pub mod ingest;

pub use about::{AboutFetcher, AboutStore, FetchOutcome};
pub use feed::{FeedMeta, FeedPage, FeedStore, FeedVariant, StoredTweet};
