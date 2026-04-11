use crate::api::ApiClient;
use crate::cli::tweet::{emit_dry_run, resolve_media};
use crate::error::{Error, Result};
use crate::util::parse_tweet_ref;
use clap::Args as ClapArgs;
use std::path::PathBuf;

#[derive(Debug, ClapArgs)]
pub struct Args {
    #[arg(help = "Target tweet ID or URL to reply to")]
    pub target: String,

    #[arg(help = "Reply body")]
    pub text: String,

    #[arg(
        long,
        value_name = "PATH",
        help = "Attach a media file (repeat up to 4 times)"
    )]
    pub media: Vec<PathBuf>,

    #[arg(
        long,
        help = "Print the exact request body that would be sent, without actually posting"
    )]
    pub dry_run: bool,
}

pub async fn run(args: Args) -> Result<()> {
    if args.text.trim().is_empty() && args.media.is_empty() {
        return Err(Error::Config(
            "reply text must not be empty (or attach --media)".into(),
        ));
    }
    let target_id = parse_tweet_ref(&args.target)?;
    let media_files = resolve_media(&args.media)?;

    if args.dry_run {
        emit_dry_run(&args.text, Some(&target_id), &media_files)?;
        return Ok(());
    }

    let client = ApiClient::new().await?;
    let posted = client
        .post_with_media(&args.text, Some(&target_id), &media_files)
        .await?;
    println!("posted: {}", posted.url());
    Ok(())
}
