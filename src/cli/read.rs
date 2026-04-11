use crate::error::Result;
use clap::Args as ClapArgs;

#[derive(Debug, ClapArgs)]
pub struct Args {
    #[arg(help = "Tweet ID or URL")]
    pub target: String,

    #[arg(long, help = "Emit raw parsed JSON")]
    pub json: bool,
}

pub async fn run(_args: Args) -> Result<()> {
    todo!("`unrager read` is not yet implemented");
}
