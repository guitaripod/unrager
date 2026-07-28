use crate::error::{Error, Result};
use crate::gql::client::USER_AGENT as SCRAPER_UA;
use crate::gql::query_ids::QueryId;
use crate::gql::transaction::{self, TransactionKeyMaterial};
use regex::Regex;
use reqwest::Client;
use std::sync::OnceLock;

/// Routes that may serve the classic client-web shell — the document that
/// carries both the `main.*.js` bundle url (query ids) and the
/// transaction-id key material. The bare homepage stopped referencing the
/// bundle when X moved its logged-out landing page to a different stack, so
/// the scraper walks this list and keeps the first document that actually
/// carries a bundle url instead of failing outright.
const SHELL_URLS: &[&str] = &["https://x.com/", "https://x.com/i/flow/login"];

static MAIN_JS_RE: OnceLock<Regex> = OnceLock::new();
static QUERY_ID_RE: OnceLock<Regex> = OnceLock::new();

fn main_js_re() -> &'static Regex {
    MAIN_JS_RE.get_or_init(|| {
        Regex::new(r"https://abs\.twimg\.com/responsive-web/client-web/main\.[a-z0-9]+\.js")
            .expect("main js regex")
    })
}

fn query_id_re() -> &'static Regex {
    QUERY_ID_RE.get_or_init(|| {
        Regex::new(r#"queryId:"([A-Za-z0-9_-]{16,30})",operationName:"([A-Za-z0-9_]+)""#)
            .expect("query id regex")
    })
}

pub struct ScrapeResult {
    pub query_ids: Vec<QueryId>,
    pub transaction_material: Option<TransactionKeyMaterial>,
}

pub async fn scrape(http: &Client) -> Result<ScrapeResult> {
    let (html, main_js) = fetch_shell(http).await?;

    tracing::debug!("scraping query ids from {main_js}");

    let bundle = http
        .get(&main_js)
        .header(reqwest::header::USER_AGENT, SCRAPER_UA)
        .send()
        .await?
        .error_for_status()?
        .text()
        .await?;

    let query_ids: Vec<QueryId> = query_id_re()
        .captures_iter(&bundle)
        .map(|cap| QueryId {
            id: cap[1].to_string(),
            operation: cap[2].to_string(),
        })
        .collect();

    tracing::debug!("scraped {} query ids", query_ids.len());

    if query_ids.is_empty() {
        return Err(Error::GraphqlShape(
            "main.js regex matched zero query ids; bundle format may have changed".into(),
        ));
    }

    let transaction_material = extract_transaction_material(http, &html).await;

    Ok(ScrapeResult {
        query_ids,
        transaction_material,
    })
}

/// Returns the first [`SHELL_URLS`] document that references a `main.*.js`
/// bundle, paired with that bundle url. A route that responds but carries no
/// bundle is skipped rather than fatal, so a landing-page redesign costs one
/// extra request instead of breaking query id refresh entirely.
async fn fetch_shell(http: &Client) -> Result<(String, String)> {
    let mut last_error: Option<Error> = None;

    for url in SHELL_URLS {
        let html = match http
            .get(*url)
            .header(reqwest::header::USER_AGENT, SCRAPER_UA)
            .send()
            .await
            .and_then(|res| res.error_for_status())
        {
            Ok(res) => match res.text().await {
                Ok(html) => html,
                Err(e) => {
                    tracing::debug!("{url}: body read failed: {e}");
                    last_error = Some(e.into());
                    continue;
                }
            },
            Err(e) => {
                tracing::debug!("{url}: request failed: {e}");
                last_error = Some(e.into());
                continue;
            }
        };

        match main_js_re().find(&html) {
            Some(m) => {
                let main_js = m.as_str().to_string();
                tracing::debug!("{url} carries {main_js}");
                return Ok((html, main_js));
            }
            None => {
                tracing::debug!("{url}: no main.*.js url in document ({} bytes)", html.len());
            }
        }
    }

    Err(last_error.unwrap_or_else(|| {
        Error::GraphqlShape(format!(
            "no main.*.js url found in any of {} client shell routes",
            SHELL_URLS.len()
        ))
    }))
}

async fn extract_transaction_material(http: &Client, html: &str) -> Option<TransactionKeyMaterial> {
    let extract = transaction::extract_from_homepage(html)?;

    tracing::debug!("fetching ondemand.s from {}", extract.ondemand_url);
    let js = http
        .get(&extract.ondemand_url)
        .header(reqwest::header::USER_AGENT, SCRAPER_UA)
        .send()
        .await
        .ok()?
        .text()
        .await
        .ok()?;

    let (row_index, key_indices) = transaction::extract_indices_from_js(&js)?;

    tracing::info!(
        "transaction key material ready (key_bytes={}, row_index={row_index}, indices={})",
        extract.key_bytes.len(),
        key_indices.len(),
    );

    Some(TransactionKeyMaterial {
        key_bytes: extract.key_bytes,
        svg_frames: extract.svg_frames,
        row_index,
        key_indices,
    })
}
