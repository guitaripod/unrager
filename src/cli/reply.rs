use crate::api::{ApiClient, PostRequest};
use crate::error::{Error, Result};
use crate::util::parse_tweet_ref;
use clap::Args as ClapArgs;

#[derive(Debug, ClapArgs)]
pub struct Args {
    #[arg(help = "Target tweet ID or URL to reply to")]
    pub target: String,

    #[arg(help = "Reply body")]
    pub text: String,

    #[arg(
        long,
        help = "Print the exact request body that would be sent, without actually posting"
    )]
    pub dry_run: bool,
}

pub async fn run(args: Args) -> Result<()> {
    if args.text.trim().is_empty() {
        return Err(Error::Config("reply text must not be empty".into()));
    }
    let target_id = parse_tweet_ref(&args.target)?;

    let request = PostRequest {
        text: args.text,
        in_reply_to_tweet_id: Some(target_id.clone()),
    };

    if args.dry_run {
        eprintln!("DRY RUN — no network writes. Would POST https://api.x.com/2/tweets with:");
        println!("{}", serde_json::to_string_pretty(&request.to_json())?);
        eprintln!();
        eprintln!("Reply target: {target_id}");
        eprintln!("Cost if sent: $0.01 (pay-per-use).");
        eprintln!("Remove --dry-run to actually post.");
        return Ok(());
    }

    let client = ApiClient::new().await?;
    let posted = client.post(&request).await?;
    println!("posted: {}", posted.url());
    Ok(())
}
