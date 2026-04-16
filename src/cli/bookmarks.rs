use crate::cli::common;
use crate::error::{Error, Result};
use crate::gql::endpoints;
use crate::gql::query_ids::Operation;
use crate::parse::timeline;
use clap::Args as ClapArgs;

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

    let tweets = common::paginate_timeline(args.max_pages, args.count as usize, async |cursor| {
        let response = client
            .get(
                Operation::BookmarkSearchTimeline,
                &endpoints::bookmark_search_variables(&args.query, args.count, cursor.as_deref()),
                &endpoints::bookmark_search_features(),
            )
            .await?;
        let instructions = timeline::extract_instructions(
            &response,
            "/data/search_by_raw_query/bookmarks_search_timeline/timeline/instructions",
        )?;
        Ok(timeline::walk(instructions))
    })
    .await?;

    common::emit_tweets(&tweets, args.json, "(no matching bookmarks)")
}
