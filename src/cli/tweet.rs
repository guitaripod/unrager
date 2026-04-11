use crate::api::{ApiClient, PostRequest};
use crate::error::{Error, Result};
use clap::Args as ClapArgs;

#[derive(Debug, ClapArgs)]
pub struct Args {
    #[arg(help = "Tweet body (max 280 chars for non-Premium accounts)")]
    pub text: String,

    #[arg(
        long,
        help = "Print the exact request body that would be sent, without actually posting"
    )]
    pub dry_run: bool,
}

pub async fn run(args: Args) -> Result<()> {
    if args.text.trim().is_empty() {
        return Err(Error::Config("tweet text must not be empty".into()));
    }

    let request = PostRequest {
        text: args.text,
        in_reply_to_tweet_id: None,
    };

    if args.dry_run {
        eprintln!("DRY RUN — no network writes. Would POST https://api.x.com/2/tweets with:");
        println!("{}", serde_json::to_string_pretty(&request.to_json())?);
        eprintln!();
        eprintln!("Cost if sent: $0.01 (pay-per-use).");
        eprintln!("Remove --dry-run to actually post.");
        return Ok(());
    }

    let client = ApiClient::new().await?;
    let posted = client.post(&request).await?;
    println!("posted: {}", posted.url());
    Ok(())
}
