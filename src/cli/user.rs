use crate::cli::common;
use crate::error::{Error, Result};
use crate::gql::GqlClient;
use crate::gql::endpoints;
use crate::gql::query_ids::Operation;
use crate::parse::timeline;
use crate::render::pretty;
use clap::Args as ClapArgs;
use serde_json::Value;

#[derive(Debug, ClapArgs)]
pub struct Args {
    #[arg(help = "Screen name (with or without leading @)")]
    pub handle: String,

    #[arg(short = 'n', default_value_t = 20)]
    pub count: u32,

    #[arg(long)]
    pub json: bool,

    #[arg(long, default_value_t = 1)]
    pub max_pages: u32,
}

pub async fn run(args: Args) -> Result<()> {
    let screen_name = args.handle.trim_start_matches('@');
    if screen_name.is_empty() {
        return Err(Error::BadTweetRef(args.handle.clone()));
    }

    let client = common::build_gql_client().await?;
    let user_id = resolve_user_id(&client, screen_name).await?;
    tracing::debug!("resolved @{screen_name} to user_id {user_id}");

    let mut all = Vec::new();
    let mut cursor: Option<String> = None;
    let target = args.count as usize;

    for page_idx in 0..args.max_pages {
        let response = client
            .get(
                Operation::UserTweets,
                &endpoints::user_tweets_variables(&user_id, args.count, cursor.as_deref()),
                &endpoints::user_tweets_features(),
            )
            .await?;

        let instructions = extract_user_tweets_instructions(&response)?;
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
        println!("(no tweets)");
    } else {
        print!("{}", pretty::tweet_list(&all));
    }

    Ok(())
}

async fn resolve_user_id(client: &GqlClient, screen_name: &str) -> Result<String> {
    let response = client
        .get(
            Operation::UserByScreenName,
            &endpoints::user_by_screen_name_variables(screen_name),
            &endpoints::user_by_screen_name_features(),
        )
        .await?;

    let user = response
        .pointer("/data/user/result")
        .ok_or_else(|| Error::GraphqlShape(format!("no such user: @{screen_name}")))?;

    let typename = user.get("__typename").and_then(Value::as_str).unwrap_or("");
    if typename == "UserUnavailable" {
        return Err(Error::GraphqlShape(format!(
            "@{screen_name} is unavailable (suspended, deactivated, or protected)"
        )));
    }

    user.get("rest_id")
        .and_then(Value::as_str)
        .map(str::to_string)
        .ok_or_else(|| Error::GraphqlShape(format!("@{screen_name} has no rest_id")))
}

fn extract_user_tweets_instructions(response: &Value) -> Result<&[Value]> {
    response
        .pointer("/data/user/result/timeline/timeline/instructions")
        .or_else(|| response.pointer("/data/user/result/timeline_v2/timeline/instructions"))
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .ok_or_else(|| {
            Error::GraphqlShape(
                "missing data.user.result.timeline*.timeline.instructions".into(),
            )
        })
}
