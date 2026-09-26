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

    let session = chromium::load_session().await.ok();
    let http = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(10))
        .build()
        .unwrap_or_default();
    match crate::gql::scraper::scrape(&http, session.as_ref()).await {
        Ok(result) => {
            let core = [
                "HomeTimeline",
                "HomeLatestTimeline",
                "UserTweets",
                "SearchTimeline",
                "TweetDetail",
            ];
            let found = result.query_ids.len();
            let core_found = result
                .query_ids
                .iter()
                .filter(|q| core.contains(&q.operation.as_str()))
                .count();
            let mut store = crate::gql::QueryIdStore::with_fallbacks_and_cache(&cache_path);
            store.merge_iter(result.query_ids);
            let refreshed = if store.save_cached(&cache_path).is_ok() {
                ", cache refreshed"
            } else {
                ""
            };
            println!(
                "✓ query ids   {found} fetched from x.com ({core_found}/{} core operations){refreshed}",
                core.len()
            );
            if result.transaction_material.is_some() {
                println!("✓ transaction key material extracted");
            } else {
                println!("! transaction key material not available (header will be omitted)");
                report.warnings += 1;
            }
        }
        Err(e) => {
            println!("! query ids   couldn't fetch fresh ones from x.com: {e}");
            match std::fs::metadata(&cache_path)
                .and_then(|m| m.modified())
                .ok()
                .and_then(|t| t.elapsed().ok())
            {
                Some(age) => println!(
                    "              → using ids cached {} ago; they keep working until X rotates them",
                    rough_age(age)
                ),
                None => println!("              → using the ids built into this version"),
            }
            println!(
                "              → if requests start failing, add a [query_ids] section to config.toml with OperationName = \"queryId\""
            );
            report.warnings += 1;
        }
    }
}

/// "40m", "5h", "3d": how stale a cache is, at the precision anyone needs.
fn rough_age(age: std::time::Duration) -> String {
    let secs = age.as_secs();
    match secs {
        s if s < 3600 => format!("{}m", s / 60),
        s if s < 86400 => format!("{}h", s / 3600),
        s => format!("{}d", s / 86400),
    }
}
