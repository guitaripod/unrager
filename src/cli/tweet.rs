use crate::api::{ApiClient, MediaFile, media, validate_set};
use crate::error::{Error, Result};
use clap::Args as ClapArgs;
use std::path::PathBuf;

#[derive(Debug, ClapArgs)]
pub struct Args {
    #[arg(help = "Tweet body (max 280 chars for non-Premium accounts)")]
    pub text: String,

    #[arg(
        long,
        value_name = "PATH",
        help = "Attach a media file (repeat up to 4 times; images, gifs, and videos supported)"
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
            "tweet text must not be empty (or attach --media)".into(),
        ));
    }

    let media_files = resolve_media(&args.media)?;

    if args.dry_run {
        emit_dry_run(&args.text, None, &media_files)?;
        return Ok(());
    }

    let client = ApiClient::new().await?;
    let posted = client
        .post_with_media(&args.text, None, &media_files)
        .await?;
    println!("posted: {}", posted.url());
    Ok(())
}

pub fn resolve_media(paths: &[PathBuf]) -> Result<Vec<MediaFile>> {
    let files: Vec<MediaFile> = paths
        .iter()
        .map(MediaFile::from_path)
        .collect::<Result<_>>()?;
    validate_set(&files)?;
    Ok(files)
}

pub fn emit_dry_run(
    text: &str,
    in_reply_to_tweet_id: Option<&str>,
    media_files: &[MediaFile],
) -> Result<()> {
    eprintln!("DRY RUN — no network writes.");
    eprintln!();

    if !media_files.is_empty() {
        eprintln!(
            "Media plan ({} file{}):",
            media_files.len(),
            if media_files.len() == 1 { "" } else { "s" }
        );
        for (i, f) in media_files.iter().enumerate() {
            let strategy = match f.strategy() {
                crate::api::UploadStrategy::SingleShot => "single-shot".to_string(),
                crate::api::UploadStrategy::Chunked { segments } => {
                    format!("chunked ({segments} segments)")
                }
            };
            eprintln!(
                "  [{}] {}  {}  {}  {}  {}",
                i,
                f.path.display(),
                f.mime,
                media::format_size(f.size),
                f.category.as_api(),
                strategy
            );
        }
        eprintln!();
    }

    let placeholder_media_ids: Vec<String> = (0..media_files.len())
        .map(|i| format!("<upload-pending-{i}>"))
        .collect();
    let preview_request = crate::api::PostRequest {
        text: text.to_string(),
        in_reply_to_tweet_id: in_reply_to_tweet_id.map(str::to_string),
        media_ids: placeholder_media_ids,
    };

    eprintln!("Would POST https://api.x.com/2/tweets with:");
    println!(
        "{}",
        serde_json::to_string_pretty(&preview_request.to_json())?
    );
    eprintln!();

    if let Some(id) = in_reply_to_tweet_id {
        eprintln!("Reply target: {id}");
    }
    if media_files.is_empty() {
        eprintln!("Cost if sent: $0.01 (pay-per-use tweet creation).");
    } else {
        eprintln!(
            "Cost if sent: $0.01 for the tweet + metered media upload credits. \
             Media uploads ARE billed on pay-per-use (confirmed via HTTP 402 \
             CreditsDepleted on an empty-balance account)."
        );
    }
    eprintln!("Remove --dry-run to actually post.");
    Ok(())
}
