use crate::auth::chromium;
use crate::config;
use crate::error::{Error, Result};
use crate::gql::endpoints;
use crate::gql::query_ids::Operation;
use crate::gql::{GqlClient, QueryIdStore};
use crate::model::Tweet;
use crate::parse::timeline;
use crate::parse::viewer;
use serde_json::Value;

pub async fn build_gql_client() -> Result<GqlClient> {
    let session = chromium::load_session().await?;
    let cache_path = config::cache_dir()?.join("query-ids.json");
    let store = QueryIdStore::with_fallbacks_and_cache(&cache_path);
    GqlClient::new(session, store, cache_path)
}

pub async fn current_handle(client: &GqlClient) -> Result<String> {
    let response = client
        .get(
            Operation::Viewer,
            &endpoints::viewer_variables(),
            &endpoints::viewer_features(),
        )
        .await?;
    Ok(viewer::parse(&response)?.handle)
}

pub async fn run_search(
    client: &GqlClient,
    query: &str,
    product: &str,
    count: u32,
    max_pages: u32,
) -> Result<Vec<Tweet>> {
    let mut all = Vec::new();
    let mut cursor: Option<String> = None;
    let target = count as usize;

    for page_idx in 0..max_pages {
        let response = client
            .post(
                Operation::SearchTimeline,
                &endpoints::search_timeline_variables(query, count, product, cursor.as_deref()),
                &endpoints::search_timeline_features(),
            )
            .await?;

        let instructions = response
            .pointer("/data/search_by_raw_query/search_timeline/timeline/instructions")
            .and_then(Value::as_array)
            .map(Vec::as_slice)
            .ok_or_else(|| Error::GraphqlShape("missing search instructions".into()))?;

        let page = timeline::walk(instructions);
        tracing::debug!(
            "search page {page_idx}: {} tweets, next_cursor={:?}",
            page.tweets.len(),
            page.next_cursor.as_ref().map(|c| c.len())
        );

        let fetched = page.tweets.len();
        all.extend(page.tweets);
        if all.len() >= target {
            break;
        }
        match page.next_cursor {
            Some(next) if fetched > 0 => cursor = Some(next),
            _ => break,
        }
    }

    all.truncate(target);
    Ok(all)
}

pub fn emit_tweets(tweets: &[Tweet], json: bool, empty_note: &str) -> Result<()> {
    if json {
        println!("{}", serde_json::to_string_pretty(tweets)?);
    } else if tweets.is_empty() {
        println!("{empty_note}");
    } else {
        print!("{}", crate::render::pretty::tweet_list(tweets));
    }
    Ok(())
}
