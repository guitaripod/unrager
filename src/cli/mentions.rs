use crate::cli::common;
use crate::error::Result;
use clap::Args as ClapArgs;

#[derive(Debug, ClapArgs)]
pub struct Args {
    #[arg(short = 'n', default_value_t = 20)]
    pub count: u32,

    #[arg(
        long,
        help = "Search mentions for another @handle instead of the authenticated user"
    )]
    pub user: Option<String>,

    #[arg(long)]
    pub json: bool,

    #[arg(long, default_value_t = 1)]
    pub max_pages: u32,
}

pub async fn run(args: Args) -> Result<()> {
    let client = common::build_gql_client().await?;

    let handle = match args.user.as_ref() {
        Some(h) => h.trim_start_matches('@').to_string(),
        None => common::current_handle(&client).await?,
    };

    let query = format!("@{handle} -from:{handle}");
    let tweets = common::run_search(&client, &query, "Latest", args.count, args.max_pages).await?;

    common::emit_tweets(&tweets, args.json, "(no mentions)")
}
