use crate::auth::chromium;
use crate::config;
use crate::error::Result;
use crate::gql::endpoints;
use crate::gql::query_ids::Operation;
use crate::gql::{GqlClient, QueryIdStore};
use crate::model::Tweet;
use crate::parse::timeline::{self, TimelinePage};
use crate::parse::viewer;

pub async fn build_gql_client() -> Result<GqlClient> {
    if std::env::var_os("UNRAGER_DEMO").is_some() {
        let session = crate::auth::XSession {
            auth_token: "demo".into(),
            ct0: "demo".into(),
            twid: "demo".into(),
        };
        let cache_path = config::cache_dir()?.join("query-ids.json");
        let store = QueryIdStore::with_fallbacks_and_cache(&cache_path);
        return GqlClient::new(session, store, cache_path);
    }
    let session = chromium::load_session().await?;
    let config_dir = config::config_dir()?;
    let app_config = config::AppConfig::load(&config_dir);
    let cache_path = config::cache_dir()?.join("query-ids.json");
    let mut store = QueryIdStore::with_fallbacks_and_cache(&cache_path);
    store.apply_config_overrides(&app_config.query_ids);
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

pub async fn paginate_timeline<F>(
    max_pages: u32,
    target: usize,
    mut fetch_page: F,
) -> Result<Vec<Tweet>>
where
    F: AsyncFnMut(Option<String>) -> Result<TimelinePage>,
{
    let mut all = Vec::new();
    let mut cursor: Option<String> = None;

    for page_idx in 0..max_pages {
        let page = fetch_page(cursor.clone()).await?;
        tracing::debug!(
            "page {page_idx}: {} tweets, next_cursor_len={:?}",
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

pub async fn run_search(
    client: &GqlClient,
    query: &str,
    product: &str,
    count: u32,
    max_pages: u32,
) -> Result<Vec<Tweet>> {
    paginate_timeline(max_pages, count as usize, async |cursor| {
        let response = client
            .post(
                Operation::SearchTimeline,
                &endpoints::search_timeline_variables(query, count, product, cursor.as_deref()),
                &endpoints::search_timeline_features(),
            )
            .await?;
        let instructions = timeline::extract_instructions(
            &response,
            "/data/search_by_raw_query/search_timeline/timeline/instructions",
        )?;
        Ok(timeline::walk(instructions))
    })
    .await
}

pub fn emit_tweets(tweets: &[Tweet], json: bool, empty_note: &str) -> Result<()> {
    if json {
        println!("{}", serde_json::to_string_pretty(tweets)?);
    } else if tweets.is_empty() {
        eprintln!("{empty_note}");
    } else {
        print!("{}", crate::render::pretty::tweet_list(tweets));
    }
    Ok(())
}
