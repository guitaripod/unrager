use clap::Parser;
use tracing_subscriber::{EnvFilter, fmt};
use unrager::cli::{self, Cli, Command};
use unrager::error::Result;

#[tokio::main]
async fn main() {
    let cli = Cli::parse();
    init_tracing(cli.debug);

    if let Err(e) = dispatch(cli.command).await {
        eprintln!("error: {e}");
        let mut source = std::error::Error::source(&e);
        while let Some(s) = source {
            eprintln!("  caused by: {s}");
            source = s.source();
        }
        std::process::exit(1);
    }
}

async fn dispatch(command: Command) -> Result<()> {
    match command {
        Command::Whoami(args) => cli::whoami::run(args).await,
        Command::Read(args) => cli::read::run(args).await,
        Command::Thread(args) => cli::thread::run(args).await,
        Command::Home(args) => cli::home::run(args).await,
        Command::User(args) => cli::user::run(args).await,
        Command::Search(args) => cli::search::run(args).await,
        Command::Mentions(args) => cli::mentions::run(args).await,
        Command::Bookmarks(args) => cli::bookmarks::run(args).await,
        Command::Tweet(args) => cli::tweet::run(args).await,
        Command::Reply(args) => cli::reply::run(args).await,
        Command::Auth(args) => cli::auth::run(args).await,
    }
}

fn init_tracing(debug: bool) {
    let filter = if debug {
        EnvFilter::try_new("unrager=debug,warn").unwrap()
    } else {
        EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("warn"))
    };
    fmt()
        .with_env_filter(filter)
        .with_writer(std::io::stderr)
        .compact()
        .init();
}
