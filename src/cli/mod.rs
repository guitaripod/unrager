pub mod bookmarks;
pub mod home;
pub mod mentions;
pub mod read;
pub mod reply;
pub mod search;
pub mod thread;
pub mod tweet;
pub mod user;
pub mod whoami;

use clap::{Parser, Subcommand};

#[derive(Debug, Parser)]
#[command(
    name = "unrager",
    about = "A calm Twitter/X CLI with a local-LLM rage filter",
    version,
    disable_help_subcommand = true
)]
pub struct Cli {
    #[command(subcommand)]
    pub command: Command,

    #[arg(long, global = true, help = "Emit verbose tracing to stderr")]
    pub debug: bool,
}

#[derive(Debug, Subcommand)]
pub enum Command {
    #[command(about = "Print the account your local browser session belongs to")]
    Whoami(whoami::Args),

    #[command(about = "Read a single tweet by ID or URL")]
    Read(read::Args),

    #[command(about = "Full conversation thread for a tweet")]
    Thread(thread::Args),

    #[command(about = "Home timeline (For You or Following)")]
    Home(home::Args),

    #[command(about = "A user's recent tweets")]
    User(user::Args),

    #[command(about = "Live search")]
    Search(search::Args),

    #[command(about = "Tweets that mention you")]
    Mentions(mentions::Args),

    #[command(about = "Your bookmarked tweets")]
    Bookmarks(bookmarks::Args),

    #[command(about = "Post a new tweet (official API, costs ~$0.01)")]
    Tweet(tweet::Args),

    #[command(about = "Reply to a tweet (official API, costs ~$0.01)")]
    Reply(reply::Args),
}
