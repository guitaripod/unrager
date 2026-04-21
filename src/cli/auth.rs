use crate::auth::oauth;
use crate::error::Result;
use clap::{Args as ClapArgs, Subcommand};
use std::io::Write;

#[derive(Debug, ClapArgs)]
pub struct Args {
    #[command(subcommand)]
    pub command: Option<Command>,
}

#[derive(Debug, Subcommand)]
pub enum Command {
    #[command(
        about = "Interactive setup wizard: walks through registering an X app, writes the client id to config.toml, then runs `auth login`"
    )]
    Setup,

    #[command(about = "Run the full OAuth 2.0 PKCE flow and save the resulting token set")]
    Login,

    #[command(about = "Show the cached token state (path, scopes, expiry)")]
    Status,

    #[command(about = "Delete the cached token file")]
    Logout,
}

pub async fn run(args: Args) -> Result<()> {
    match args.command.unwrap_or(Command::Status) {
        Command::Setup => run_setup().await,
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

async fn run_setup() -> Result<()> {
    println!("── unrager write-path setup ────────────────────");
    println!();
    println!("The write path (tweet, reply) uses the official X API v2");
    println!("via OAuth 2.0 PKCE. You need your own registered X");
    println!("developer app — the binary does not embed a default.");
    println!();
    println!("Steps:");
    println!("  1. Open https://developer.x.com and sign in");
    println!("  2. Create a project, then a native app");
    println!("     (\"Type of app\" = Native, no client secret)");
    println!("  3. Set the callback URL to:");
    println!("       http://127.0.0.1:8765/callback");
    println!("  4. Set user-auth scopes: tweet.read, tweet.write,");
    println!("     users.read, media.write, offline.access");
    println!("  5. Copy the Client ID from the app's Keys and tokens tab");
    println!("  6. Load pay-per-use credits at https://console.x.com");
    println!("     (required to post; reading from the TUI does not");
    println!("      need this)");
    println!();
    print!("Paste your Client ID (or press Enter to abort): ");
    std::io::stdout().flush().ok();

    let mut buf = String::new();
    std::io::stdin().read_line(&mut buf)?;
    let client_id = buf.trim().to_string();
    if client_id.is_empty() {
        println!("aborted — no client id provided");
        return Ok(());
    }

    let cfg_dir = crate::config::config_dir()?;
    let cfg_path = cfg_dir.join("config.toml");
    let existing = std::fs::read_to_string(&cfg_path).unwrap_or_default();
    let updated = set_oauth_client_id_in_config(&existing, &client_id);
    std::fs::write(&cfg_path, updated)?;
    println!();
    println!("✓ wrote client_id to {}", cfg_path.display());
    println!();

    print!("Run `auth login` now? [Y/n] ");
    std::io::stdout().flush().ok();
    let mut answer = String::new();
    std::io::stdin().read_line(&mut answer)?;
    let answer = answer.trim();
    if answer.is_empty() || answer.eq_ignore_ascii_case("y") || answer.eq_ignore_ascii_case("yes") {
        let tokens = oauth::load_or_authorize().await?;
        println!();
        println!("✓ authorized");
        println!("  expires_at: {}", tokens.expires_at.to_rfc3339());
        println!("  cached at:  {}", oauth::tokens_path()?.display());
        println!();
        println!("try it: unrager tweet \"hello from unrager\"");
    } else {
        println!("ok — run `unrager auth login` when ready");
    }
    Ok(())
}

/// Write (or replace) `client_id` under the `[oauth]` section of a
/// config.toml body, creating the section if absent. Preserves all other
/// content verbatim.
fn set_oauth_client_id_in_config(existing: &str, client_id: &str) -> String {
    let escaped = client_id.replace('\\', "\\\\").replace('"', "\\\"");
    let new_line = format!(r#"client_id = "{escaped}""#);

    let lines: Vec<&str> = existing.split_inclusive('\n').collect();
    let section_start = lines.iter().position(|l| l.trim() == "[oauth]");

    let Some(section_start) = section_start else {
        let sep = match () {
            _ if existing.is_empty() => "",
            _ if existing.ends_with("\n\n") => "",
            _ if existing.ends_with('\n') => "\n",
            _ => "\n\n",
        };
        return format!("{existing}{sep}[oauth]\n{new_line}\n");
    };

    let section_end = lines[section_start + 1..]
        .iter()
        .position(|l| l.trim_start().starts_with('['))
        .map(|p| section_start + 1 + p)
        .unwrap_or(lines.len());

    let client_id_idx = lines[section_start + 1..section_end]
        .iter()
        .position(|l| l.trim_start().starts_with("client_id"))
        .map(|p| section_start + 1 + p);

    let mut out = String::new();
    for (i, line) in lines.iter().enumerate() {
        match (client_id_idx, i) {
            (Some(ci), j) if j == ci => {
                out.push_str(&new_line);
                out.push('\n');
            }
            (None, j) if j == section_start => {
                out.push_str(line);
                out.push_str(&new_line);
                out.push('\n');
            }
            _ => out.push_str(line),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn creates_section_in_empty_config() {
        let got = set_oauth_client_id_in_config("", "abc");
        assert_eq!(got, "[oauth]\nclient_id = \"abc\"\n");
    }

    #[test]
    fn appends_section_to_existing_config() {
        let got = set_oauth_client_id_in_config("[browser]\nname = \"firefox\"\n", "abc");
        assert_eq!(
            got,
            "[browser]\nname = \"firefox\"\n\n[oauth]\nclient_id = \"abc\"\n"
        );
    }

    #[test]
    fn replaces_existing_client_id() {
        let got = set_oauth_client_id_in_config("[oauth]\nclient_id = \"OLD\"\n", "NEW");
        assert_eq!(got, "[oauth]\nclient_id = \"NEW\"\n");
    }

    #[test]
    fn inserts_client_id_into_existing_empty_section() {
        let got = set_oauth_client_id_in_config("[oauth]\nother = 1\n", "NEW");
        assert_eq!(got, "[oauth]\nclient_id = \"NEW\"\nother = 1\n");
    }

    #[test]
    fn preserves_unrelated_sections() {
        let input = "[a]\nx = 1\n\n[oauth]\nclient_id = \"OLD\"\n\n[b]\ny = 2\n";
        let got = set_oauth_client_id_in_config(input, "NEW");
        assert_eq!(
            got,
            "[a]\nx = 1\n\n[oauth]\nclient_id = \"NEW\"\n\n[b]\ny = 2\n"
        );
    }

    #[test]
    fn escapes_embedded_quotes_and_backslashes() {
        let got = set_oauth_client_id_in_config("", r#"a"b\c"#);
        assert_eq!(got, "[oauth]\nclient_id = \"a\\\"b\\\\c\"\n");
    }

    #[test]
    fn does_not_touch_client_id_in_unrelated_section() {
        let input = "[other]\nclient_id = \"leave_me_alone\"\n";
        let got = set_oauth_client_id_in_config(input, "NEW");
        assert_eq!(
            got,
            "[other]\nclient_id = \"leave_me_alone\"\n\n[oauth]\nclient_id = \"NEW\"\n"
        );
    }
}
