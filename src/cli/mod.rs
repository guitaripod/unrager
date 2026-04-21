pub mod auth;
pub mod bookmarks;
pub mod common;
#[cfg(feature = "tui")]
pub mod demo;
#[cfg(feature = "tui")]
pub mod doctor;
pub mod home;
pub mod mentions;
#[cfg(feature = "tui")]
pub mod notifs;
pub mod read;
pub mod reply;
pub mod search;
#[cfg(feature = "server")]
pub mod serve;
pub mod thread;
pub mod tweet;
pub mod update;
#[cfg(feature = "tui")]
pub mod user;
pub mod whoami;

use clap::{Parser, Subcommand};

const LONG_ABOUT: &str = "A calm Twitter/X CLI with a local-LLM rage filter.

Run `unrager` with no arguments to launch the TUI. Subcommands perform
one-shot reads, writes, or diagnostics.

The TUI reads cookies from your logged-in Chromium-family browser and
pipes every tweet through a local Ollama classifier. The filter disables
itself silently when Ollama isn't running; `unrager doctor` explains what
is and isn't set up.

Config:
  Linux   ~/.config/unrager/{filter.toml, session.json, tokens.json}
  macOS   ~/Library/Application Support/unrager/{filter.toml, ...}";

#[derive(Debug, Parser)]
#[command(
    name = "unrager",
    about = "A calm Twitter/X CLI with a local-LLM rage filter",
    long_about = LONG_ABOUT,
    version,
    disable_help_subcommand = true
)]
pub struct Cli {
    #[command(subcommand)]
    pub command: Option<Command>,

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

    #[cfg(feature = "tui")]
    #[command(about = "A user's recent tweets")]
    User(user::Args),

    #[command(about = "Live search")]
    Search(search::Args),

    #[command(about = "Tweets that mention you")]
    Mentions(mentions::Args),

    #[cfg(feature = "tui")]
    #[command(about = "Your recent notifications")]
    Notifs(notifs::Args),

    #[command(about = "Your bookmarked tweets")]
    Bookmarks(bookmarks::Args),

    #[command(about = "Post a new tweet (official API, costs ~$0.01)")]
    Tweet(tweet::Args),

    #[command(about = "Reply to a tweet (official API, costs ~$0.01)")]
    Reply(reply::Args),

    #[command(about = "Manage OAuth 2.0 tokens for the write path")]
    Auth(auth::Args),

    #[cfg(feature = "tui")]
    #[command(
        about = "Launch the TUI against a bundled offline feed (no X cookies needed, just a terminal and optionally Ollama)"
    )]
    Demo(demo::Args),

    #[cfg(feature = "tui")]
    #[command(about = "Check cookies, Ollama, and gemma4 setup")]
    Doctor(doctor::Args),

    #[command(about = "Update unrager to the latest release")]
    Update(update::Args),

    #[cfg(feature = "server")]
    #[command(about = "Run the HTTP server exposing the web/mobile client API")]
    Serve(serve::Args),
}
