use clap::Parser;
use tracing_subscriber::{EnvFilter, Layer, layer::SubscriberExt, util::SubscriberInitExt};
use unrager::cli::{self, Cli, Command};
use unrager::error::Result;
use unrager::tui;

#[tokio::main]
async fn main() {
    let cli = Cli::parse();
    let tui_mode = cli.command.is_none();
    init_tracing(cli.debug, tui_mode);
    install_panic_hook();

    let result = match cli.command {
        Some(command) => dispatch(command).await,
        None => tui::run().await,
    };

    if let Err(e) = result {
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
        Command::Notifs(args) => cli::notifs::run(args).await,
        Command::Bookmarks(args) => cli::bookmarks::run(args).await,
        Command::Tweet(args) => cli::tweet::run(args).await,
        Command::Reply(args) => cli::reply::run(args).await,
        Command::Auth(args) => cli::auth::run(args).await,
        Command::Doctor(args) => cli::doctor::run(args).await,
    }
}

fn install_panic_hook() {
    let original = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        ratatui::restore();
        original(info);
    }));
}

fn init_tracing(debug: bool, tui_mode: bool) {
    let stderr_layer = if tui_mode {
        None
    } else {
        let stderr_filter = if debug {
            EnvFilter::try_new("unrager=debug,warn").unwrap()
        } else {
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("warn"))
        };
        Some(
            tracing_subscriber::fmt::layer()
                .with_writer(std::io::stderr)
                .compact()
                .with_filter(stderr_filter),
        )
    };

    let file_layer = unrager::config::cache_dir().ok().map(|cache_dir| {
        let _ = std::fs::create_dir_all(&cache_dir);
        let appender = tracing_appender::rolling::daily(&cache_dir, "unrager.log");
        let file_filter = if debug {
            EnvFilter::try_new("unrager=debug,warn").unwrap()
        } else {
            EnvFilter::try_new("unrager=info,warn").unwrap()
        };
        tracing_subscriber::fmt::layer()
            .with_writer(appender)
            .with_ansi(false)
            .with_filter(file_filter)
    });

    tracing_subscriber::registry()
        .with(stderr_layer)
        .with(file_layer)
        .init();
}
