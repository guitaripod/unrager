use crate::cli::common;
use crate::error::{Error, Result};
use crate::gql::endpoints;
use crate::gql::query_ids::Operation;
use crate::parse::timeline;
use crate::util::parse_tweet_ref;
use clap::Args as ClapArgs;
use serde_json::Value;

#[derive(Debug, ClapArgs)]
pub struct Args {
    #[arg(help = "Tweet ID or URL")]
    pub target: String,

    #[arg(long)]
    pub json: bool,

    #[arg(long, default_value_t = 1, help = "How many pages of replies to fetch")]
    pub max_pages: u32,
}

pub async fn run(args: Args) -> Result<()> {
    let focal = parse_tweet_ref(&args.target)?;
    let client = common::build_gql_client().await?;

    let tweets = common::paginate_timeline(args.max_pages, usize::MAX, async |cursor| {
        let response = client
            .get(
                Operation::TweetDetail,
                &endpoints::tweet_detail_variables(&focal, cursor.as_deref()),
                &endpoints::tweet_read_features(),
            )
            .await?;
        let instructions = extract_instructions(&response)?;
        Ok(timeline::walk(instructions))
    })
    .await?;

    if tweets.is_empty() {
        return Err(Error::GraphqlShape(
            "thread returned no tweets: focal tweet may be inaccessible".into(),
        ));
    }

    common::emit_tweets(&tweets, args.json, "(empty)")
}

fn extract_instructions(response: &Value) -> Result<&[Value]> {
    response
        .pointer("/data/threaded_conversation_with_injections_v2/instructions")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .ok_or_else(|| {
            Error::GraphqlShape(
                "missing data.threaded_conversation_with_injections_v2.instructions".into(),
            )
        })
}
