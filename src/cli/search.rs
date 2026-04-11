use crate::cli::common;
use crate::error::{Error, Result};
use crate::gql::endpoints;
use crate::gql::query_ids::Operation;
use crate::parse::timeline;
use crate::render::pretty;
use clap::{Args as ClapArgs, ValueEnum};
use serde_json::Value;

#[derive(Debug, Clone, Copy, ValueEnum)]
pub enum Product {
    Top,
    Latest,
    People,
    Photos,
    Videos,
}

impl Product {
    fn as_api(self) -> &'static str {
        match self {
            Self::Top => "Top",
            Self::Latest => "Latest",
            Self::People => "People",
            Self::Photos => "Photos",
            Self::Videos => "Videos",
        }
    }
}

#[derive(Debug, ClapArgs)]
pub struct Args {
    #[arg(help = "Search query (same syntax as the web client: from:, since:, lang:, etc.)")]
    pub query: String,

    #[arg(short = 'n', default_value_t = 20)]
    pub count: u32,

    #[arg(long, value_enum, default_value_t = Product::Latest)]
    pub product: Product,

    #[arg(long)]
    pub json: bool,

    #[arg(long, default_value_t = 1)]
    pub max_pages: u32,
}

pub async fn run(args: Args) -> Result<()> {
    if args.query.trim().is_empty() {
        return Err(Error::Config("search query must not be empty".into()));
    }

    let client = common::build_gql_client().await?;

    let mut all = Vec::new();
    let mut cursor: Option<String> = None;
    let target = args.count as usize;

    for page_idx in 0..args.max_pages {
        let response = client
            .post(
                Operation::SearchTimeline,
                &endpoints::search_timeline_variables(
                    &args.query,
                    args.count,
                    args.product.as_api(),
                    cursor.as_deref(),
                ),
                &endpoints::search_timeline_features(),
            )
            .await?;

        let instructions = extract_search_instructions(&response)?;
        let page = timeline::walk(instructions);
        tracing::debug!(
            "page {page_idx}: {} tweets, next_cursor={:?}",
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

    if args.json {
        println!("{}", serde_json::to_string_pretty(&all)?);
    } else if all.is_empty() {
        println!("(no results)");
    } else {
        print!("{}", pretty::tweet_list(&all));
    }

    Ok(())
}

fn extract_search_instructions(response: &Value) -> Result<&[Value]> {
    response
        .pointer("/data/search_by_raw_query/search_timeline/timeline/instructions")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .ok_or_else(|| {
            Error::GraphqlShape(
                "missing data.search_by_raw_query.search_timeline.timeline.instructions".into(),
            )
        })
}
