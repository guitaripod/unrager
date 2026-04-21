use crate::cli::common;
use crate::error::{Error, Result};
use crate::gql::endpoints;
use crate::gql::query_ids::Operation;
use crate::parse::timeline;
use crate::tui::source;
use clap::Args as ClapArgs;

#[derive(Debug, ClapArgs)]
pub struct Args {
    #[arg(help = "Screen name (with or without leading @)")]
    pub handle: String,

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
    let screen_name = args.handle.trim_start_matches('@');
    if screen_name.is_empty() {
        return Err(Error::Config("handle must not be empty".into()));
    }

    let client = common::build_gql_client().await?;
    let user_id = source::resolve_user_id(&client, screen_name).await?;
    tracing::debug!("resolved @{screen_name} to user_id {user_id}");

    let tweets = common::paginate_timeline(args.max_pages, args.count as usize, async |cursor| {
        let response = client
            .get(
                Operation::UserTweets,
                &endpoints::user_tweets_variables(&user_id, args.count, cursor.as_deref()),
                &endpoints::user_tweets_features(),
            )
            .await?;
        let instructions = timeline::extract_instructions_multi(
            &response,
            &[
                "/data/user/result/timeline/timeline/instructions",
                "/data/user/result/timeline_v2/timeline/instructions",
            ],
        )?;
        Ok(timeline::walk(instructions))
    })
    .await?;

    common::emit_tweets(&tweets, args.json, "(no tweets)")
}
