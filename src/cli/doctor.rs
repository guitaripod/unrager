use crate::auth::chromium;
use crate::cli::checks::{self, Report};
use crate::config;
use crate::error::Result;
use clap::Parser;

#[derive(Debug, Parser)]
pub struct Args {
    #[arg(long, help = "Emit verbose tracing to stderr")]
    pub debug: bool,
}

/// What the first group of checks covers: everything the browser extension
/// needs, or just the model in a build without the server.
#[cfg(feature = "server")]
const FILTER_GROUP: &str = "Browser extension";
#[cfg(not(feature = "server"))]
const FILTER_GROUP: &str = "Rage filter";

pub async fn run(_args: Args) -> Result<()> {
    let mut filter = Report::default();
    println!("{FILTER_GROUP}");
    checks::llm(&mut filter).await;
    #[cfg(feature = "server")]
    {
        checks::server(&mut filter).await;
        checks::extension(&mut filter);
    }

    let mut client = Report::default();
    println!();
    println!("Terminal client and iPhone app");
    print_cookies(&mut client);
    print_query_ids(&mut client).await;

    println!();
    if filter.errors > 0 {
        println!("{FILTER_GROUP}: not working yet. Follow the → hints under it.");
        std::process::exit(1);
    }
    if client.errors > 0 {
        println!(
            "{FILTER_GROUP}: all set. The terminal client and iPhone app need the → fixes under them."
        );
        std::process::exit(1);
    }
    if filter.warnings + client.warnings > 0 {
        println!("Working, with warnings: the → hints above clean them up.");
    } else {
        println!("All good: unrager is fully set up.");
    }
    Ok(())
}

fn print_cookies(report: &mut Report) {
    let results = match chromium::probe() {
        Ok(r) => r,
        Err(e) => {
            println!("✗ cookies     probe failed: {e}");
            report.errors += 1;
            return;
        }
    };

    let with_session: Vec<_> = results.iter().filter(|r| r.has_x_session).collect();
    let pin = chromium::pinned_browser();

    if !with_session.is_empty() {
        println!(
            "✓ cookies     x.com session found in {} browser profile(s)",
            with_session.len()
        );
        for r in &with_session {
            let pinned = pin
                .as_deref()
                .is_some_and(|p| r.browser.eq_ignore_ascii_case(p));
            let tag = if pinned { "  ← pinned source" } else { "" };
            println!("              - {} ({}){tag}", r.browser, r.path.display());
        }
        if let Some(pin) = &pin {
            if !with_session
                .iter()
                .any(|r| r.browser.eq_ignore_ascii_case(pin))
            {
                println!(
                    "              ! pinned to \"{pin}\" but it has no x.com session — unrager will fail to authenticate"
                );
                report.errors += 1;
            }
        }
    } else if !results.is_empty() {
        println!(
            "✗ cookies     {} cookie store(s) found, but none are logged into x.com",
            results.len()
        );
        println!("              → log into x.com in any of these browsers:");
        for r in &results {
            println!("                {} ({})", r.browser, r.path.display());
        }
        report.errors += 1;
    } else if let Some(override_path) = std::env::var_os("UNRAGER_COOKIES_PATH") {
        let p = std::path::PathBuf::from(override_path);
        println!(
            "✗ cookies     UNRAGER_COOKIES_PATH={} does not exist",
            p.display()
        );
        println!(
            "              → unset the env var to auto-detect, or point it at a real Cookies file"
        );
        report.errors += 1;
    } else {
        println!("✗ cookies     no Chromium-family browser cookie store found");
        println!("              → install Vivaldi / Chrome / Brave / Edge, then log into x.com");
        println!(
            "              → or, if your browser is installed at a non-standard path (Flatpak, Snap, sandbox),"
        );
        println!("                point UNRAGER_COOKIES_PATH at the Cookies file directly, e.g.:");
        println!(
            "                export UNRAGER_COOKIES_PATH=\"$HOME/.config/BraveSoftware/Brave-Browser/Default/Cookies\""
        );
        report.errors += 1;
    }
}

async fn print_query_ids(report: &mut Report) {
    let cache_path = match config::cache_dir() {
        Ok(d) => d.join("query-ids.json"),
        Err(_) => {
            println!("✗ query ids   cache dir unavailable");
            report.errors += 1;
            return;
        }
    };

    let config_dir = config::config_dir().ok();
    let overrides = config_dir
        .map(|d| config::AppConfig::load(&d).query_ids)
        .unwrap_or_default();
    if !overrides.is_empty() {
        println!(
            "✓ query ids   {} manual override(s) in config.toml",
            overrides.len()
        );
        for (op, id) in &overrides {
            println!("              - {op} = {id}");
        }
    }

    let store = crate::gql::QueryIdStore::with_fallbacks_and_cache(&cache_path);
    let cached_age = std::fs::metadata(&cache_path)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| t.elapsed().ok());

    match cached_age {
        Some(age) if age.as_secs() < 86400 => {
            let hours = age.as_secs() / 3600;
            println!("✓ query ids   cache is {hours}h old (fresh)");
        }
        Some(age) => {
            let days = age.as_secs() / 86400;
            println!(
                "! query ids   cache is {days}d old — may be stale; will refresh on next API call"
            );
            report.warnings += 1;
        }
        None => {
            println!("! query ids   no cache file — using hardcoded fallbacks");
            report.warnings += 1;
        }
    }

    let http = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(10))
        .build()
        .unwrap_or_default();
    match crate::gql::scraper::scrape(&http).await {
        Ok(result) => {
            let known_ops: Vec<&str> = [
                "HomeTimeline",
                "HomeLatestTimeline",
                "UserTweets",
                "SearchTimeline",
                "TweetDetail",
            ]
            .into_iter()
            .collect();
            let matched = result
                .query_ids
                .iter()
                .filter(|q| known_ops.contains(&q.operation.as_str()))
                .count();
            println!(
                "✓ query ids   scraper found {} ids ({matched} known operations)",
                result.query_ids.len()
            );
            if result.transaction_material.is_some() {
                println!("✓ transaction key material extracted");
            } else {
                println!("! transaction key material not available (header will be omitted)");
            }
            let _ = store;
        }
        Err(e) => {
            println!("! query ids   scraper failed: {e}");
            println!("              → cached/fallback ids will be used; may go stale");
            println!(
                "              → manual override: add [query_ids] section to config.toml with OperationName = \"queryId\""
            );
            report.warnings += 1;
        }
    }
}
