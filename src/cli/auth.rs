use crate::auth::oauth;
use crate::error::Result;
use clap::{Args as ClapArgs, Subcommand};

#[derive(Debug, ClapArgs)]
pub struct Args {
    #[command(subcommand)]
    pub command: Option<Command>,
}

#[derive(Debug, Subcommand)]
pub enum Command {
    #[command(about = "Run the full OAuth 2.0 PKCE flow and save the resulting token set")]
    Login,

    #[command(about = "Show the cached token state (path, scopes, expiry)")]
    Status,

    #[command(about = "Delete the cached token file")]
    Logout,
}

pub async fn run(args: Args) -> Result<()> {
    match args.command.unwrap_or(Command::Status) {
        Command::Login => {
            let tokens = oauth::load_or_authorize().await?;
            println!("authorized ✓");
            println!(
                "  scope:      {}",
                tokens.scope.unwrap_or_else(|| "(not reported)".into())
            );
            println!("  expires_at: {}", tokens.expires_at.to_rfc3339());
            println!(
                "  refresh:    {}",
                if tokens.refresh_token.is_some() {
                    "yes"
                } else {
                    "no"
                }
            );
            println!("  cached at:  {}", oauth::tokens_path()?.display());
            Ok(())
        }
        Command::Status => {
            let path = oauth::tokens_path()?;
            if !path.exists() {
                println!("no cached tokens at {}", path.display());
                println!("run `unrager auth login` to authorize");
                return Ok(());
            }
            let bytes = std::fs::read(&path)?;
            let tokens: oauth::Tokens = serde_json::from_slice(&bytes)?;
            let expired = if tokens.is_expired() {
                " (expired)"
            } else {
                ""
            };
            println!("cached at:  {}", path.display());
            println!(
                "scope:      {}",
                tokens.scope.unwrap_or_else(|| "(not reported)".into())
            );
            println!("expires_at: {}{expired}", tokens.expires_at.to_rfc3339());
            println!(
                "refresh:    {}",
                if tokens.refresh_token.is_some() {
                    "yes"
                } else {
                    "no"
                }
            );
            Ok(())
        }
        Command::Logout => {
            let path = oauth::tokens_path()?;
            match std::fs::remove_file(&path) {
                Ok(()) => println!("removed {}", path.display()),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                    println!("no cached tokens at {}", path.display())
                }
                Err(e) => return Err(e.into()),
            }
            Ok(())
        }
    }
}
