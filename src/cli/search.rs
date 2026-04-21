use crate::cli::common;
use crate::error::{Error, Result};
use clap::{Args as ClapArgs, ValueEnum};

#[derive(Debug, Clone, Copy, ValueEnum)]
pub enum Product {
    Top,
    Latest,
    People,
    Photos,
    Videos,
}

impl Product {
    fn as_api(self) -> &'static str {
        match self {
            Self::Top => "Top",
            Self::Latest => "Latest",
            Self::People => "People",
            Self::Photos => "Photos",
            Self::Videos => "Videos",
        }
    }
}

#[derive(Debug, ClapArgs)]
pub struct Args {
    #[arg(help = "Search query (same syntax as the web client: from:, since:, lang:, etc.)")]
    pub query: String,

    #[arg(short = 'n', default_value_t = 20, help = "Target result count")]
    pub count: u32,

    #[arg(long, value_enum, default_value_t = Product::Latest, help = "Which search tab to query")]
    pub product: Product,

    #[arg(long, help = "Emit parsed tweets as JSON (one object per line)")]
    pub json: bool,

    #[arg(long, default_value_t = 1, help = "Maximum pages to fetch")]
    pub max_pages: u32,
}

pub async fn run(args: Args) -> Result<()> {
    if args.query.trim().is_empty() {
        return Err(Error::Config("search query must not be empty".into()));
    }

    let client = common::build_gql_client().await?;
    let tweets = common::run_search(
        &client,
        &args.query,
        args.product.as_api(),
        args.count,
        args.max_pages,
    )
    .await?;

    common::emit_tweets(&tweets, args.json, "(no results)")
}
