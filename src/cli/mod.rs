pub mod auth;
pub mod bookmarks;
#[cfg(feature = "tui")]
pub mod checks;
pub mod common;
#[cfg(feature = "tui")]
pub mod demo;
#[cfg(feature = "tui")]
pub mod doctor;
#[cfg(feature = "tui")]
pub mod eval;
pub mod home;
pub mod mentions;
#[cfg(feature = "tui")]
pub mod notifs;
pub mod read;
pub mod reply;
pub mod search;
#[cfg(feature = "server")]
pub mod serve;
#[cfg(feature = "server")]
pub mod setup;
pub mod thread;
pub mod tweet;
pub mod update;
#[cfg(feature = "tui")]
pub mod user;
pub mod whoami;

use clap::{Parser, Subcommand};

const LONG_ABOUT: &str =
    "Takes the rage out of your x.com timeline with a model on your own computer.

Get started:
  unrager setup     checks your model, runs unrager in the background and
                    unpacks the browser extension; then follow what it prints
  unrager doctor    shows what is and isn't working

The browser extension works in Chrome, Brave, Edge, Vivaldi and Arc. Run
`unrager` with no arguments for the terminal client, which filters the same
way; the other subcommands read and post from the command line.

The model runs on Ollama by default (`ollama pull hf.co/guitaripod/unrager-4b:Q4_K_M`). Any server that
speaks the OpenAI chat API works too (LM Studio, vLLM, llama.cpp, SGLang):
set [llm] in filter.toml.

Config:
  Linux   ~/.config/unrager/{filter.toml, config.toml, tokens.json}
  macOS   ~/Library/Application Support/unrager/{filter.toml, ...}";

#[derive(Debug, Parser)]
#[command(
    name = "unrager",
    about = "Takes the rage out of your x.com timeline with a model on your own computer",
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
        about = "Launch the TUI against a bundled offline feed (no X cookies needed, just a terminal and optionally a local LLM)"
    )]
    Demo(demo::Args),

    #[cfg(feature = "tui")]
    #[command(about = "Check the model, background server, extension and X login")]
    Doctor(doctor::Args),

    #[cfg(feature = "tui")]
    #[command(
        about = "Measure how well your model filters: it judges a set of made-up posts labelled against the default rules"
    )]
    Eval(eval::Args),

    #[command(about = "Update unrager to the latest release")]
    Update(update::Args),

    #[cfg(feature = "server")]
    #[command(
        about = "Check your model, run unrager in the background and unpack the browser extension"
    )]
    Setup(setup::Args),

    #[cfg(feature = "server")]
    #[command(about = "Run the server the browser extension and the iPhone app talk to")]
    Serve(serve::Args),
}
