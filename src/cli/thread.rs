use crate::error::Result;
use clap::Args as ClapArgs;

#[derive(Debug, ClapArgs)]
pub struct Args {
    pub target: String,

    #[arg(long)]
    pub json: bool,

    #[arg(long, default_value_t = 1)]
    pub max_pages: u32,
}

pub async fn run(_args: Args) -> Result<()> {
    todo!("`unrager thread` is not yet implemented");
}
