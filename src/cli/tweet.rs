use crate::error::Result;
use clap::Args as ClapArgs;

#[derive(Debug, ClapArgs)]
pub struct Args {
    pub text: String,
}

pub async fn run(_args: Args) -> Result<()> {
    todo!("`unrager tweet` is not yet implemented (official API write path)");
}
