use crate::cli::common;
use crate::error::{Error, Result};
use crate::gql::endpoints;
use crate::gql::query_ids::Operation;
use crate::parse::timeline;
use clap::Args as ClapArgs;
use serde_json::Value;

#[derive(Debug, ClapArgs)]
pub struct Args {
    #[arg(long, help = "Fetch the Following feed instead of For You")]
    pub following: bool,

    #[arg(short = 'n', default_value_t = 20)]
    pub count: u32,

    #[arg(long)]
    pub json: bool,

    #[arg(long, default_value_t = 1)]
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
        let instructions = extract_instructions(&response)?;
        Ok(timeline::walk(instructions))
    })
    .await?;

    common::emit_tweets(&tweets, args.json, "(home timeline returned no tweets)")
}

fn extract_instructions(response: &Value) -> Result<&[Value]> {
    response
        .pointer("/data/home/home_timeline_urt/instructions")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .ok_or_else(|| {
            Error::GraphqlShape("missing data.home.home_timeline_urt.instructions".into())
        })
}
