use crate::cli::common;
use crate::error::{Error, Result};
use crate::gql::endpoints;
use crate::gql::query_ids::Operation;
use crate::parse::timeline;
use crate::render::pretty;
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

    let mut all = Vec::new();
    let mut cursor: Option<String> = None;

    for page_idx in 0..args.max_pages {
        let response = client
            .get(
                Operation::TweetDetail,
                &endpoints::tweet_detail_variables(&focal, cursor.as_deref()),
                &endpoints::tweet_read_features(),
            )
            .await?;

        let instructions = extract_instructions(&response)?;
        let page = timeline::walk(instructions);
        tracing::debug!(
            "page {page_idx}: {} tweets, next_cursor={:?}",
            page.tweets.len(),
            page.next_cursor.as_ref().map(|c| c.len())
        );

        let fetched = page.tweets.len();
        all.extend(page.tweets);

        match page.next_cursor {
            Some(next) if fetched > 0 => cursor = Some(next),
            _ => break,
        }
    }

    if all.is_empty() {
        return Err(Error::GraphqlShape(
            "thread returned no tweets: focal tweet may be inaccessible".into(),
        ));
    }

    if args.json {
        println!("{}", serde_json::to_string_pretty(&all)?);
    } else {
        print!("{}", pretty::tweet_list(&all));
    }

    Ok(())
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
