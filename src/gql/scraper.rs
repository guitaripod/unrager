use crate::error::{Error, Result};
use crate::gql::query_ids::QueryId;
use regex::Regex;
use reqwest::Client;
use std::sync::OnceLock;

const HOMEPAGE: &str = "https://x.com/";
const SCRAPER_UA: &str =
    "Mozilla/5.0 (X11; Linux x86_64; rv:133.0) Gecko/20100101 Firefox/133.0";

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

pub async fn scrape(http: &Client) -> Result<Vec<QueryId>> {
    let html = http
        .get(HOMEPAGE)
        .header(reqwest::header::USER_AGENT, SCRAPER_UA)
        .send()
        .await?
        .error_for_status()?
        .text()
        .await?;

    let main_js = main_js_re()
        .find(&html)
        .map(|m| m.as_str().to_string())
        .ok_or_else(|| {
            Error::GraphqlShape("could not locate main.*.js url in x.com homepage".into())
        })?;

    tracing::debug!("scraping query ids from {main_js}");

    let bundle = http
        .get(&main_js)
        .header(reqwest::header::USER_AGENT, SCRAPER_UA)
        .send()
        .await?
        .error_for_status()?
        .text()
        .await?;

    let found: Vec<QueryId> = query_id_re()
        .captures_iter(&bundle)
        .map(|cap| QueryId {
            id: cap[1].to_string(),
            operation: cap[2].to_string(),
        })
        .collect();

    tracing::debug!("scraped {} query ids", found.len());

    if found.is_empty() {
        return Err(Error::GraphqlShape(
            "main.js regex matched zero query ids; bundle format may have changed".into(),
        ));
    }

    Ok(found)
}
