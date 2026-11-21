use crate::cli::common;
use crate::error::Result;
use crate::tui::whisper;
use clap::Args as ClapArgs;

#[derive(Debug, ClapArgs)]
pub struct Args {
    #[arg(long, help = "Emit parsed notifications as JSON (one object per line)")]
    pub json: bool,

    #[arg(long, help = "Dump the raw API response JSON")]
    pub raw: bool,

    #[arg(long, help = "Fetch the page after this cursor (with --raw)")]
    pub cursor: Option<String>,

    #[arg(
        long,
        help = "With --raw: dump the posts behind \"New post notifications\" instead"
    )]
    pub posts: bool,
}

pub async fn run(args: Args) -> Result<()> {
    let client = common::build_gql_client().await?;

    if args.raw && args.posts {
        let response = whisper::fetch_followed_posts_raw(&client).await?;
        println!("{}", serde_json::to_string_pretty(&response)?);
        return Ok(());
    }
    if args.raw {
        let response =
            whisper::fetch_notifications_raw(&client, args.cursor.as_deref(), 40).await?;
        println!("{}", serde_json::to_string_pretty(&response)?);
        return Ok(());
    }

    let page = whisper::fetch_notifications(&client, None, 40).await?;

    if args.json {
        let out: Vec<serde_json::Value> = page
            .notifications
            .iter()
            .map(|n| {
                serde_json::json!({
                    "id": n.id,
                    "type": n.notification_type,
                    "actors": n.actors.iter().map(|u| &u.handle).collect::<Vec<_>>(),
                    "people": n.people_count(),
                    "url": n.url,
                    "target_tweet_id": n.target_tweet_id,
                    "target_tweet_snippet": n.target_tweet_snippet,
                    "target_tweet_like_count": n.target_tweet_like_count,
                    "timestamp": n.timestamp.to_rfc3339(),
                })
            })
            .collect();
        println!("{}", serde_json::to_string_pretty(&out)?);
    } else if page.notifications.is_empty() {
        eprintln!("(no notifications)");
    } else {
        for n in &page.notifications {
            let actors: Vec<&str> = n.actors.iter().map(|u| u.handle.as_str()).collect();
            let actors_str = if actors.is_empty() {
                "?".to_string()
            } else {
                actors.join(", ")
            };
            let snippet = n
                .target_tweet_snippet
                .as_deref()
                .map(|s| format!(" — {s}"))
                .unwrap_or_default();
            println!(
                "[{}] @{} {}{snippet}",
                n.timestamp.format("%H:%M"),
                actors_str,
                n.notification_type.to_lowercase(),
            );
        }
    }

    Ok(())
}
