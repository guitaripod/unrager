use crate::cli::common;
use crate::error::Result;
use crate::gql::endpoints;
use crate::gql::query_ids::Operation;
use crate::parse::tweet as parse_tweet;
use crate::render::pretty;
use crate::util::parse_tweet_ref;
use clap::Args as ClapArgs;

#[derive(Debug, ClapArgs)]
pub struct Args {
    #[arg(help = "Tweet ID or URL")]
    pub target: String,

    #[arg(long, help = "Emit raw parsed JSON")]
    pub json: bool,
}

pub async fn run(args: Args) -> Result<()> {
    let tweet_id = parse_tweet_ref(&args.target)?;
    let client = common::build_gql_client().await?;

    let response = client
        .get(
            Operation::TweetResultByRestId,
            &endpoints::tweet_by_rest_id_variables(&tweet_id),
            &endpoints::tweet_read_features(),
        )
        .await?;

    let tweet = parse_tweet::parse_tweet_result_by_rest_id(&response)?;

    if args.json {
        println!("{}", serde_json::to_string_pretty(&tweet)?);
    } else {
        print!("{}", pretty::tweet(&tweet));
    }

    Ok(())
}
