use crate::error::Result;
use clap::Args as ClapArgs;

#[derive(Debug, ClapArgs)]
pub struct Args {
    #[arg(short = 'n', default_value_t = 20)]
    pub count: u32,

    #[arg(long)]
    pub json: bool,

    #[arg(long, default_value_t = 1)]
    pub max_pages: u32,
}

pub async fn run(_args: Args) -> Result<()> {
    todo!("`unrager mentions` is not yet implemented");
}
