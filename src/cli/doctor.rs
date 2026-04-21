use crate::auth::chromium;
use crate::config;
use crate::error::Result;
use crate::tui::filter::FilterConfig;
use clap::Parser;
use serde::Deserialize;

#[derive(Debug, Parser)]
pub struct Args {
    #[arg(long, help = "Emit verbose tracing to stderr")]
    pub debug: bool,
}

pub async fn run(_args: Args) -> Result<()> {
    let mut report = Report::default();

    print_cookies(&mut report);
    print_query_ids(&mut report).await;
    print_ollama_and_gemma4(&mut report).await;

    println!();
    if report.errors > 0 {
        println!("some checks failed — follow the → hints above.");
        std::process::exit(1);
    }
    if report.warnings > 0 {
        println!("working, but with warnings — follow the → hints above to clean up.");
    } else {
        println!("all good — unrager is fully set up.");
    }
    Ok(())
}

#[derive(Default)]
struct Report {
    errors: usize,
    warnings: usize,
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

    if !with_session.is_empty() {
        println!(
            "✓ cookies     x.com session found in {} browser profile(s)",
            with_session.len()
        );
        for r in &with_session {
            println!("              - {} ({})", r.browser, r.path.display());
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
        report.errors += 1;
    }
}

#[derive(Deserialize)]
struct TagsResponse {
    #[serde(default)]
    models: Vec<TagsModel>,
}

#[derive(Deserialize)]
struct TagsModel {
    name: String,
}

async fn print_ollama_and_gemma4(report: &mut Report) {
    let filter_cfg = match load_filter_cfg() {
        Ok(c) => c,
        Err(e) => {
            println!("✗ filter      filter.toml unreadable: {e}");
            report.errors += 1;
            return;
        }
    };
    let host = filter_cfg.ollama.host.trim_end_matches('/');
    let configured = &filter_cfg.ollama.model;

    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(3))
        .build()
        .unwrap_or_default();

    let resp = client.get(format!("{host}/api/tags")).send().await;
    let models = match resp {
        Ok(r) if r.status().is_success() => match r.json::<TagsResponse>().await {
            Ok(t) => t.models.into_iter().map(|m| m.name).collect::<Vec<_>>(),
            Err(e) => {
                println!("✗ ollama      reachable at {host} but response malformed: {e}");
                report.errors += 1;
                return;
            }
        },
        Ok(r) => {
            println!(
                "✗ ollama      reachable at {host} but returned {}",
                r.status()
            );
            report.errors += 1;
            return;
        }
        Err(_) => {
            println!("✗ ollama      not reachable at {host}");
            println!("              → install: curl -fsSL https://ollama.com/install.sh | sh");
            println!("              → start:   ollama serve");
            report.errors += 1;
            return;
        }
    };

    println!(
        "✓ ollama      reachable at {host} ({} model(s))",
        models.len()
    );

    let gemma4: Vec<&String> = models.iter().filter(|n| n.starts_with("gemma4")).collect();
    if gemma4.is_empty() {
        println!("✗ gemma4      no gemma4 model installed");
        println!("              → ollama pull gemma4");
        report.errors += 1;
        return;
    }

    if models.iter().any(|n| n == configured) {
        println!("✓ gemma4      configured model {configured} is installed");
    } else {
        let fallback = gemma4[0];
        println!(
            "! gemma4      configured model {configured} not installed; filter will fall back to {fallback}"
        );
        println!("              → fix: ollama pull gemma4");
        report.warnings += 1;
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

fn load_filter_cfg() -> Result<FilterConfig> {
    let cfg_dir = config::config_dir()?;
    FilterConfig::load_or_init(&cfg_dir.join("filter.toml"))
}
