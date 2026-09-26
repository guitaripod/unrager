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

    let exe = std::env::current_exe()?;
    update::perform_update(&version).await?;

    println!("updated to {version}.");
    refresh_setup(&exe);
    Ok(())
}

/// Hands over to the new binary so the background server restarts on it and
/// the unpacked extension is rewritten from it; this process still carries
/// the old version's files. `exe` is resolved before the swap, because
/// afterwards Linux reports this process's own image as deleted.
#[cfg(feature = "server")]
fn refresh_setup(exe: &std::path::Path) {
    match std::process::Command::new(exe)
        .args(["setup", "--refresh"])
        .status()
    {
        Ok(status) if status.success() => {}
        _ => println!(
            "run `unrager setup` to restart the background server on {}.",
            exe.display()
        ),
    }
}

#[cfg(not(feature = "server"))]
fn refresh_setup(_exe: &std::path::Path) {}
