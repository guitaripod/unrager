//! Compares the scraped live query IDs against the hardcoded fallbacks in
//! `src/gql/query_ids.rs`. Exits 0 when every operation still maps to the
//! same fallback id; exits 1 with a diff printed to stdout when any
//! operation has rotated.
//!
//! The expected table is read straight out of the library
//! (`Operation::ALL` + `QueryIdStore::with_fallbacks`), so a newly added
//! operation is watched the moment it lands — there is no second list to
//! keep in sync.
//!
//! Invoked by the `.github/workflows/query-ids-watch.yml` cron so that a
//! rotation opens a tracking issue before users start seeing failures.

use std::collections::BTreeMap;
use unrager::gql::QueryIdStore;
use unrager::gql::query_ids::Operation;
use unrager::gql::scraper;

#[tokio::main]
async fn main() {
    let http = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .expect("build http client");

    let scraped = match scraper::scrape(&http).await {
        Ok(r) => r.query_ids,
        Err(e) => {
            println!("SCRAPER_ERROR: {e}");
            println!("The main.js bundle could not be parsed. This usually means X");
            println!("moved the client shell or obfuscated the bundle format. The");
            println!("fallback IDs may still work until X rotates them. Manually");
            println!("verify by running:");
            println!();
            println!("  cargo run --release -- doctor");
            println!();
            println!("If the scraper is permanently broken, SHELL_URLS or the regexes");
            println!("in src/gql/scraper.rs need updating.");
            std::process::exit(2);
        }
    };

    let live: BTreeMap<&str, &str> = scraped
        .iter()
        .map(|q| (q.operation.as_str(), q.id.as_str()))
        .collect();

    let fallbacks = QueryIdStore::with_fallbacks();

    let mut rotated: Vec<(&str, String, &str)> = Vec::new();
    let mut missing: Vec<&str> = Vec::new();
    for op in Operation::ALL {
        let name = op.name();
        let fallback = fallbacks
            .get(*op)
            .expect("every operation has a fallback id")
            .id
            .clone();
        match live.get(name).copied() {
            Some(id) if id == fallback => {}
            Some(id) => rotated.push((name, fallback, id)),
            None => missing.push(name),
        }
    }

    if rotated.is_empty() && missing.is_empty() {
        println!(
            "OK: all {} operations match fallbacks",
            Operation::ALL.len()
        );
        return;
    }

    if !rotated.is_empty() {
        println!("ROTATED operations (fallback → live):");
        for (op, fallback, id) in &rotated {
            println!("  {op}: {fallback} → {id}");
        }
    }

    if !missing.is_empty() {
        println!();
        println!("MISSING operations (not found in scraped bundle):");
        for op in &missing {
            println!("  {op}");
        }
    }

    println!();
    println!("Paste into FALLBACK_QUERY_IDS in src/gql/query_ids.rs:");
    for op in Operation::ALL {
        let name = op.name();
        let id = live
            .get(name)
            .copied()
            .map(str::to_string)
            .unwrap_or_else(|| {
                fallbacks
                    .get(*op)
                    .expect("every operation has a fallback id")
                    .id
                    .clone()
            });
        println!("    ({name}, \"{id}\"),");
    }
    std::process::exit(1);
}
