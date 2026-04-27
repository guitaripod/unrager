//! Compares the scraped live query IDs against the hardcoded fallbacks in
//! `src/gql/query_ids.rs`. Exits 0 when every known operation still maps to
//! the same fallback id; exits 1 with a diff printed to stdout when any
//! operation has rotated.
//!
//! Invoked by the `.github/workflows/query-ids-watch.yml` cron so that a
//! rotation opens a tracking issue before users start seeing failures.

use std::collections::BTreeMap;
use unrager::gql::{QueryId, scraper};

const KNOWN_OPS: &[&str] = &[
    "Viewer",
    "TweetResultByRestId",
    "TweetDetail",
    "HomeTimeline",
    "HomeLatestTimeline",
    "UserByScreenName",
    "UserTweets",
    "UserTweetsAndReplies",
    "SearchTimeline",
    "Favoriters",
    "NotificationsTimeline",
    "FavoriteTweet",
    "UnfavoriteTweet",
    "CreateTweet",
];

const FALLBACKS: &[(&str, &str)] = &[
    ("Viewer", "_8ClT24oZ8tpylf_OSuNdg"),
    ("TweetResultByRestId", "fHLDP3qFEjnTqhWBVvsREg"),
    ("TweetDetail", "QrLp7AR-eMyamw8D1N9l6A"),
    ("HomeTimeline", "3tb-_5Lf7kdCZ1cFHmsEfg"),
    ("HomeLatestTimeline", "eObmT5Nuapp04u8bYWf49Q"),
    ("UserByScreenName", "IGgvgiOx4QZndDHuD3x9TQ"),
    ("UserTweets", "naBcZ4al-iTCFBYGOAMzBQ"),
    ("UserTweetsAndReplies", "YhE6S_TtdhVxLtpokXrRaA"),
    ("SearchTimeline", "XN_HccZ9SU-miQVvwTAlFQ"),
    ("Favoriters", "E-ZTxvWWIkmOKwYdNTEefg"),
    ("NotificationsTimeline", "l6ovGrjBwVobgU4puBCycg"),
    ("FavoriteTweet", "lI07N6Otwv1PhnEgXILM7A"),
    ("UnfavoriteTweet", "ZYKSe-w7KEslx3JhSIk5LA"),
    ("CreateTweet", "c50A_puUoQGK_4SXseYz3A"),
];

#[tokio::main]
async fn main() {
    let http = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .expect("build http client");

    let scraped: Vec<QueryId> = match scraper::scrape(&http).await {
        Ok(r) => r.query_ids,
        Err(e) => {
            println!("SCRAPER_ERROR: {e}");
            println!("The main.js bundle could not be parsed. This usually means X");
            println!("obfuscated the bundle format. The fallback IDs may still work");
            println!("until X rotates them. Manually verify by running:");
            println!();
            println!("  cargo run --release -- doctor");
            println!();
            println!("If the scraper is permanently broken, the regex in");
            println!("src/gql/scraper.rs needs updating.");
            std::process::exit(2);
        }
    };

    let by_op: BTreeMap<&str, &str> = scraped
        .iter()
        .map(|q| (q.operation.as_str(), q.id.as_str()))
        .collect();

    let fallback_map: BTreeMap<&str, &str> = FALLBACKS.iter().copied().collect();

    let mut rotated: Vec<(&str, &str, &str)> = Vec::new();
    let mut missing: Vec<&str> = Vec::new();
    for op in KNOWN_OPS {
        let fallback = fallback_map
            .get(op)
            .copied()
            .expect("every KNOWN_OPS entry is mirrored in FALLBACKS");
        match by_op.get(op).copied() {
            Some(live) if live == fallback => {}
            Some(live) => rotated.push((op, fallback, live)),
            None => missing.push(op),
        }
    }

    if rotated.is_empty() && missing.is_empty() {
        println!(
            "OK: all {} known operations match fallbacks",
            KNOWN_OPS.len()
        );
        return;
    }

    if !rotated.is_empty() {
        println!("ROTATED operations (fallback → live):");
        for (op, fallback, live) in &rotated {
            println!("  {op}: {fallback} → {live}");
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
    println!("To update the fallbacks, patch FALLBACK_QUERY_IDS in src/gql/query_ids.rs");
    println!("and this example's FALLBACKS table, then ship a new release.");
    std::process::exit(1);
}
