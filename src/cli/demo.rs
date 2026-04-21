use crate::error::Result;
use clap::Parser;

#[derive(Debug, Parser)]
pub struct Args {
    #[arg(long, help = "Emit verbose tracing to stderr")]
    pub debug: bool,
}

pub async fn run(_args: Args) -> Result<()> {
    // SAFETY: set once, before the TUI spawns any background work that might
    // read the env var concurrently.
    unsafe { std::env::set_var("UNRAGER_DEMO", "1") };
    crate::tui::run().await
}
