use crate::cli::common;
use crate::error::{Error, Result};
use crate::gql::endpoints;
use crate::gql::query_ids::Operation;
use crate::parse::timeline;
use crate::render::pretty;
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

    let mut all = Vec::new();
    let mut cursor: Option<String> = None;
    let target = args.count as usize;

    for page_idx in 0..args.max_pages {
        let response = client
            .post(
                op,
                &endpoints::home_timeline_variables(args.count, cursor.as_deref()),
                &endpoints::home_timeline_features(),
            )
            .await?;

        let instructions = extract_home_instructions(&response)?;
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
        println!("(home timeline returned no tweets)");
    } else {
        print!("{}", pretty::tweet_list(&all));
    }

    Ok(())
}

fn extract_home_instructions(response: &Value) -> Result<&[Value]> {
    response
        .pointer("/data/home/home_timeline_urt/instructions")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .ok_or_else(|| Error::GraphqlShape("missing data.home.home_timeline_urt.instructions".into()))
}
