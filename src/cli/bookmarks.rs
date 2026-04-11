use crate::cli::common;
use crate::error::{Error, Result};
use crate::gql::GqlClient;
use crate::gql::endpoints;
use crate::gql::query_ids::Operation;
use crate::parse::timeline;
use clap::Args as ClapArgs;
use serde_json::Value;

#[derive(Debug, ClapArgs)]
pub struct Args {
    #[arg(
        help = "Search query within your bookmarks (required: full-list bookmark operation \
                lives in a lazy-loaded chunk unreachable without a headless browser)"
    )]
    pub query: String,

    #[arg(short = 'n', default_value_t = 20)]
    pub count: u32,

    #[arg(long)]
    pub json: bool,

    #[arg(long, default_value_t = 1)]
    pub max_pages: u32,
}

pub async fn run(args: Args) -> Result<()> {
    if args.query.trim().is_empty() {
        return Err(Error::Config(
            "bookmarks requires a non-empty search query".into(),
        ));
    }

    let client = common::build_gql_client().await?;

    let mut all = Vec::new();
    let mut cursor: Option<String> = None;
    let target = args.count as usize;

    for page_idx in 0..args.max_pages {
        let response = call(&client, &args.query, args.count, cursor.as_deref()).await?;
        let instructions = extract_instructions(&response)?;
        let page = timeline::walk(instructions);
        tracing::debug!(
            "bookmarks page {page_idx}: {} tweets, next_cursor={:?}",
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
    common::emit_tweets(&all, args.json, "(no matching bookmarks)")
}

async fn call(
    client: &GqlClient,
    query: &str,
    count: u32,
    cursor: Option<&str>,
) -> Result<Value> {
    client
        .get(
            Operation::BookmarkSearchTimeline,
            &endpoints::bookmark_search_variables(query, count, cursor),
            &endpoints::bookmark_search_features(),
        )
        .await
}

fn extract_instructions(response: &Value) -> Result<&[Value]> {
    response
        .pointer("/data/search_by_raw_query/bookmarks_search_timeline/timeline/instructions")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .ok_or_else(|| {
            Error::GraphqlShape(
                "missing data.search_by_raw_query.bookmarks_search_timeline.timeline.instructions"
                    .into(),
            )
        })
}
