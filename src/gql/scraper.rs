use crate::auth::XSession;
use crate::error::{Error, Result};
use crate::gql::client::USER_AGENT as SCRAPER_UA;
use crate::gql::query_ids::QueryId;
use crate::gql::transaction::{self, TransactionKeyMaterial};
use futures::StreamExt;
use regex::Regex;
use reqwest::Client;
use std::collections::HashMap;
use std::sync::OnceLock;

/// The page a signed-in browser opens, which is what unrager's requests
/// imitate: as long as X serves the classic client-web app to anyone, it
/// serves it here, with the `main.*.js` bundle url (query ids) and the
/// transaction-id key material.
const SESSION_SHELL_URL: &str = "https://x.com/home";

/// Routes that still serve the classic client-web shell to a logged-out
/// visitor. X moved its logged-out landing page, profiles and login flow to a
/// separate app (`x-web`) whose documents reference no `main.*.js`; these
/// pages kept the old shell, so a scrape without a session (the CI query-id
/// watcher, a filter-only server) walks them and keeps the first document
/// that actually carries a bundle url.
const ANONYMOUS_SHELL_URLS: &[&str] = &[
    "https://x.com/intent/post",
    "https://x.com/i/display",
    "https://x.com/i/tweetdeck",
    "https://x.com/",
];

/// Fragments of the names of the lazily loaded chunks that define the
/// operations `main.js` doesn't: the Home timelines, bookmarks,
/// notifications, likers, the post-analytics query and the about-account
/// lookup. The shell's chunk map
/// names every chunk, so these are matched against it instead of hardcoding
/// hashed file names that change on every deploy.
const LAZY_CHUNK_HINTS: &[&str] = &[
    "HomeTimeline",
    "Bookmarks",
    "bundle.Notifications",
    "TweetActivity",
    "ConversationWithRelay",
    "AboutAccount",
];
const CHUNK_BASE: &str = "https://abs.twimg.com/responsive-web/client-web/";
const CHUNK_FETCH_CONCURRENCY: usize = 6;

static MAIN_JS_RE: OnceLock<Regex> = OnceLock::new();
static QUERY_ID_RE: OnceLock<Regex> = OnceLock::new();
static RELAY_ID_RE: OnceLock<Regex> = OnceLock::new();
static CHUNK_ENTRY_RE: OnceLock<Regex> = OnceLock::new();
static CHUNK_HASH_RE: OnceLock<Regex> = OnceLock::new();

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

/// Operations compiled Relay-style (`params:{id:"…",metadata:{},name:"…",
/// operationKind:"query"}`) rather than as `{queryId,operationName}` objects;
/// `AboutAccountQuery` is one.
fn relay_id_re() -> &'static Regex {
    RELAY_ID_RE.get_or_init(|| {
        Regex::new(r#"id:"([A-Za-z0-9_-]{16,30})",metadata:\{[^}]*\},name:"([A-Za-z0-9_]+)",operationKind:"(?:query|mutation|subscription)""#)
            .expect("relay id regex")
    })
}

fn chunk_entry_re() -> &'static Regex {
    CHUNK_ENTRY_RE.get_or_init(|| {
        Regex::new(r#"[^0-9A-Za-z_$](\d+):"([A-Za-z0-9_.~-]+)""#).expect("chunk entry regex")
    })
}

fn chunk_hash_re() -> &'static Regex {
    CHUNK_HASH_RE.get_or_init(|| Regex::new(r"^[0-9a-f]{5,16}$").expect("chunk hash regex"))
}

/// Every operation id `js` defines, in either compiled form.
fn query_ids_in(js: &str) -> impl Iterator<Item = QueryId> + '_ {
    query_id_re()
        .captures_iter(js)
        .chain(relay_id_re().captures_iter(js))
        .map(|cap| QueryId {
            id: cap[1].to_string(),
            operation: cap[2].to_string(),
        })
}

/// The urls of the lazily loaded chunks worth reading for query ids. The
/// shell's webpack runtime maps each chunk id to a name (`12:"bundle.Home"`)
/// and, separately, to a content hash (`12:"a1b2c3d4"`); a chunk's file is
/// `<name>.<hash>a.js`.
fn lazy_chunk_urls(html: &str) -> Vec<String> {
    let mut names: HashMap<&str, &str> = HashMap::new();
    let mut hashes: HashMap<&str, &str> = HashMap::new();
    for cap in chunk_entry_re().captures_iter(html) {
        let (id, value) = (cap.get(1).unwrap().as_str(), cap.get(2).unwrap().as_str());
        if chunk_hash_re().is_match(value) {
            hashes.entry(id).or_insert(value);
        } else if value.contains('.') {
            names.entry(id).or_insert(value);
        }
    }
    let mut urls: Vec<String> = names
        .iter()
        .filter(|(_, name)| LAZY_CHUNK_HINTS.iter().any(|hint| name.contains(hint)))
        .filter_map(|(id, name)| Some(format!("{CHUNK_BASE}{name}.{}a.js", hashes.get(id)?)))
        .collect();
    urls.sort();
    urls
}

/// Query ids from the hinted lazy chunks. A chunk that fails to load is
/// skipped: whatever it would have added stays at its cached or built-in id.
async fn lazy_query_ids(http: &Client, html: &str) -> Vec<QueryId> {
    let urls = lazy_chunk_urls(html);
    tracing::debug!("reading {} lazy chunks for query ids", urls.len());
    futures::stream::iter(urls)
        .map(|url| async move {
            let js = http
                .get(&url)
                .header(reqwest::header::USER_AGENT, SCRAPER_UA)
                .send()
                .await
                .and_then(|res| res.error_for_status());
            match js {
                Ok(res) => res.text().await.unwrap_or_default(),
                Err(e) => {
                    tracing::debug!("{url}: {e}");
                    String::new()
                }
            }
        })
        .buffer_unordered(CHUNK_FETCH_CONCURRENCY)
        .flat_map(|js| futures::stream::iter(query_ids_in(&js).collect::<Vec<_>>()))
        .collect()
        .await
}

pub struct ScrapeResult {
    pub query_ids: Vec<QueryId>,
    pub transaction_material: Option<TransactionKeyMaterial>,
}

/// Scrapes query ids and transaction key material, from the signed-in shell
/// when `session` holds one and from the anonymous routes otherwise (or when
/// that fails).
pub async fn scrape(http: &Client, session: Option<&XSession>) -> Result<ScrapeResult> {
    let (html, main_js) = fetch_shell(http, session).await?;

    tracing::debug!("scraping query ids from {main_js}");

    let bundle = http
        .get(&main_js)
        .header(reqwest::header::USER_AGENT, SCRAPER_UA)
        .send()
        .await?
        .error_for_status()?
        .text()
        .await?;

    let mut by_operation: HashMap<String, QueryId> = HashMap::new();
    for qid in lazy_query_ids(http, &html)
        .await
        .into_iter()
        .chain(query_ids_in(&bundle))
    {
        by_operation.insert(qid.operation.clone(), qid);
    }
    let query_ids: Vec<QueryId> = by_operation.into_values().collect();

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

/// The shell routes to try, in order, each with the cookie header to send.
fn shell_candidates(session: Option<&XSession>) -> Vec<(&'static str, Option<String>)> {
    let signed_in = session.filter(|s| !s.auth_token.is_empty()).map(|s| {
        (
            SESSION_SHELL_URL,
            Some(format!(
                "auth_token={}; ct0={}; twid={}",
                s.auth_token, s.ct0, s.twid
            )),
        )
    });
    signed_in
        .into_iter()
        .chain(ANONYMOUS_SHELL_URLS.iter().map(|url| (*url, None)))
        .collect()
}

/// Returns the first candidate document that references a `main.*.js`
/// bundle, paired with that bundle url. A route that responds but carries no
/// bundle is skipped rather than fatal, so a redesign of one page costs one
/// extra request instead of breaking query id refresh entirely.
async fn fetch_shell(http: &Client, session: Option<&XSession>) -> Result<(String, String)> {
    let mut last_error: Option<Error> = None;
    let candidates = shell_candidates(session);

    for (url, cookie) in &candidates {
        let mut request = http
            .get(*url)
            .header(reqwest::header::USER_AGENT, SCRAPER_UA);
        if let Some(cookie) = cookie {
            request = request.header(reqwest::header::COOKIE, cookie);
        }
        let html = match request.send().await.and_then(|res| res.error_for_status()) {
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
            candidates.len()
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_session_is_tried_first_then_the_anonymous_routes() {
        let session = XSession {
            auth_token: "a".into(),
            ct0: "c".into(),
            twid: "t".into(),
        };
        let candidates = shell_candidates(Some(&session));
        assert_eq!(candidates[0].0, SESSION_SHELL_URL);
        assert_eq!(
            candidates[0].1.as_deref(),
            Some("auth_token=a; ct0=c; twid=t")
        );
        assert_eq!(candidates.len(), 1 + ANONYMOUS_SHELL_URLS.len());
        assert!(candidates[1..].iter().all(|(_, cookie)| cookie.is_none()));
    }

    #[test]
    fn both_compiled_forms_yield_query_ids() {
        let js = r#"e.exports={queryId:"aoDbu3RHznuiSkQ9aNM67Q",operationName:"CreateBookmark",operationType:"mutation"}; params:{id:"TzOG2twZEfhr9KmClvVVqA",metadata:{},name:"AboutAccountQuery",operationKind:"query",text:null}"#;
        let found: Vec<(String, String)> = query_ids_in(js).map(|q| (q.operation, q.id)).collect();
        assert_eq!(
            found,
            [
                (
                    "CreateBookmark".to_string(),
                    "aoDbu3RHznuiSkQ9aNM67Q".to_string()
                ),
                (
                    "AboutAccountQuery".to_string(),
                    "TzOG2twZEfhr9KmClvVVqA".to_string()
                ),
            ]
        );
    }

    #[test]
    fn lazy_chunks_are_found_through_the_webpack_maps() {
        let html = r#"e+({53852:"shared~bundle.Compose~bundle.HomeTimeline~bundle.LoggedInMain",99969:"bundle.Notifications",12:"bundle.Explore",62408:"loader.AboutAccount"}[e]||e)+"."+{53852:"5222375b6bad6760",99969:"0a5c147c6eeb0298",12:"deadbeef",62408:"5b67f6e0ad2cb32c"}[e]+"a.js""#;
        assert_eq!(
            lazy_chunk_urls(html),
            [
                "https://abs.twimg.com/responsive-web/client-web/bundle.Notifications.0a5c147c6eeb0298a.js",
                "https://abs.twimg.com/responsive-web/client-web/loader.AboutAccount.5b67f6e0ad2cb32ca.js",
                "https://abs.twimg.com/responsive-web/client-web/shared~bundle.Compose~bundle.HomeTimeline~bundle.LoggedInMain.5222375b6bad6760a.js",
            ]
        );
    }

    #[test]
    fn an_empty_session_scrapes_anonymously() {
        let candidates = shell_candidates(Some(&XSession::default()));
        assert_eq!(candidates.len(), ANONYMOUS_SHELL_URLS.len());
        assert!(
            shell_candidates(None)
                .iter()
                .all(|(_, cookie)| cookie.is_none())
        );
    }
}
