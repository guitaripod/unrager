use crate::error::Result;
use crate::update;
use clap::Parser;

#[derive(Debug, Parser)]
pub struct Args;

pub async fn run(_args: Args) -> Result<()> {
    println!("current version: {}", update::current_version());
    println!("checking for updates...");

    let version = match update::check_latest().await? {
        Some(v) => v,
        None => {
            println!("already up to date.");
            return Ok(());
        }
    };

    println!("new version available: {version}");
    println!("downloading and verifying...");

    update::perform_update(&version).await?;

    println!("updated to {version} — restart to use the new version.");
    Ok(())
}
