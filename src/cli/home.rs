use crate::cli::common;
use crate::error::Result;
use crate::gql::endpoints;
use crate::gql::query_ids::Operation;
use crate::parse::timeline;
use clap::Args as ClapArgs;

#[derive(Debug, ClapArgs)]
pub struct Args {
    #[arg(long, help = "Fetch the Following feed instead of For You")]
    pub following: bool,

    #[arg(
        short = 'n',
        default_value_t = 20,
        help = "Target tweet count after filtering"
    )]
    pub count: u32,

    #[arg(long, help = "Emit parsed tweets as JSON (one object per line)")]
    pub json: bool,

    #[arg(
        long,
        default_value_t = 1,
        help = "Maximum pages to fetch (~20 tweets each)"
    )]
    pub max_pages: u32,
}

pub async fn run(args: Args) -> Result<()> {
    let client = common::build_gql_client().await?;
    let op = if args.following {
        Operation::HomeLatestTimeline
    } else {
        Operation::HomeTimeline
    };

    let tweets = common::paginate_timeline(args.max_pages, args.count as usize, async |cursor| {
        let response = client
            .post(
                op,
                &endpoints::home_timeline_variables(args.count, cursor.as_deref()),
                &endpoints::home_timeline_features(),
            )
            .await?;
        let instructions =
            timeline::extract_instructions(&response, "/data/home/home_timeline_urt/instructions")?;
        Ok(timeline::walk(instructions))
    })
    .await?;

    common::emit_tweets(&tweets, args.json, "(home timeline returned no tweets)")
}
