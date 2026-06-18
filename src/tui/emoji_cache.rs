//! Lazy on-disk cache for color emoji PNGs (Twemoji).
//!
//! Screenshots composite color emoji — any emoji, not just country flags —
//! next to and inside the tweet body. `ab_glyph` only rasterizes monochrome
//! glyph outlines, so the bundled monospace fonts would draw color emoji as
//! tofu. Instead each emoji grapheme is mapped to its Twemoji filename stem,
//! the matching PNG is pulled from the jsDelivr CDN on first use, cached
//! forever under `~/.cache/unrager/emoji/<stem>.png`, and alpha-composited
//! over the cell(s). Subsequent screenshots are instant; offline screenshots
//! fall back silently (the rasterizer then draws the grapheme through the
//! outline font instead).
//!
//! ## Always the latest emoji
//!
//! The original `twitter/twemoji` repo is frozen at Emoji 14.0, so it 404s on
//! every emoji released since. Assets come from the maintained `jdecked/twemoji`
//! fork instead, and the version is *resolved at runtime* via jsDelivr's data
//! API (resolve-then-pin): the newest published release is looked up once per
//! process and all asset URLs are built against that immutable tag. A new
//! emoji therefore renders against the *same* binary the moment the fork ships
//! it — no rebuild. On a resolve failure (offline) the pinned
//! [`FALLBACK_TWEMOJI_VERSION`] is used so behavior stays deterministic.
//!
//! Detection ([`is_emoji_grapheme`]) is an exact lookup against the `emojis`
//! crate's Unicode table; it is the one piece that tracks Unicode at *build*
//! time, so bump the `emojis` crate alongside any expectation of brand-new
//! codepoints. Anything the table doesn't know is left to the outline font.

use crate::config;
use futures::stream::{FuturesUnordered, StreamExt};
use image::RgbaImage;
use ratatui::text::Line;
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};
use std::time::Duration;
use tokio::sync::{OnceCell, Semaphore};
use unicode_segmentation::UnicodeSegmentation;

/// Maintained Twemoji fork. The original `twitter/twemoji` is frozen at
/// Emoji 14.0; this fork tracks the latest Unicode emoji release.
const TWEMOJI_REPO: &str = "https://cdn.jsdelivr.net/gh/jdecked/twemoji";
/// Used when the runtime version resolve fails (offline / CDN unreachable).
/// Bump alongside the `emojis` crate when a newer Emoji release lands.
const FALLBACK_TWEMOJI_VERSION: &str = "17.0.3";
/// jsDelivr data API that resolves the `latest` specifier to a concrete,
/// immutable version. No GitHub-style rate limit; CORS-open; ~300s cached.
const TWEMOJI_RESOLVE_URL: &str =
    "https://data.jsdelivr.com/v1/packages/gh/jdecked/twemoji/resolved?specifier=latest";

const FETCH_TIMEOUT: Duration = Duration::from_secs(5);
const CONCURRENT_FETCHES: usize = 4;

const ZWJ: char = '\u{200D}';
const VARIATION_SELECTOR_16: char = '\u{FE0F}';

pub fn cache_dir() -> Option<PathBuf> {
    let dir = config::cache_dir().ok()?.join("emoji");
    if let Err(e) = std::fs::create_dir_all(&dir) {
        tracing::warn!("emoji cache: mkdir failed: {e}");
        return None;
    }
    Some(dir)
}

/// True when the grapheme cluster is a real emoji that should be
/// image-composited rather than outline-drawn. Exact-match lookup against the
/// `emojis` crate's Unicode table: bare ASCII digits, `#`, `*`, and
/// text-presentation symbols are not keys and return `false`, so the digit /
/// keycap and width-2 CJK false positives are sidestepped by construction.
pub fn is_emoji_grapheme(sym: &str) -> bool {
    emojis::get(sym).is_some()
}

/// Maps an emoji grapheme to its Twemoji PNG filename stem (the part before
/// `.png`), replicating Twemoji's `grabTheRightIcon` rule:
///
/// - if the sequence contains a ZWJ (U+200D), keep every codepoint;
/// - otherwise strip every variation selector U+FE0F;
/// - then lowercase-hex each remaining scalar (no zero-padding) and join
///   with `-`.
///
/// The codepoints are taken from the `emojis` crate's fully-qualified
/// canonical form when known (so an unqualified `❤` and a qualified `❤️`
/// both resolve to `2764`), falling back to the raw grapheme otherwise. A
/// flag is just the no-ZWJ, no-FE0F case (`🇺🇸` → `1f1fa-1f1f8`).
pub fn twemoji_stem(grapheme: &str) -> String {
    let canonical = emojis::get(grapheme)
        .map(|e| e.as_str())
        .unwrap_or(grapheme);
    let has_zwj = canonical.chars().any(|c| c == ZWJ);
    canonical
        .chars()
        .filter(|&c| has_zwj || c != VARIATION_SELECTOR_16)
        .map(|c| format!("{:x}", c as u32))
        .collect::<Vec<_>>()
        .join("-")
}

/// Walks every span in `lines`, segments each into grapheme clusters, and
/// returns the set of Twemoji filename stems for every emoji found. Used by
/// the screenshot pipeline to pre-fetch all emoji before rasterizing. The
/// grapheme segmenter is the same one ratatui uses for buffer cells, so the
/// stems collected here match the ones [`twemoji_stem`] derives at paint time.
pub fn extract_emoji_stems(lines: &[Line<'_>]) -> HashSet<String> {
    let mut stems = HashSet::new();
    for line in lines {
        for span in &line.spans {
            for g in span.content.graphemes(true) {
                if is_emoji_grapheme(g) {
                    stems.insert(twemoji_stem(g));
                }
            }
        }
    }
    stems
}

/// Ensures every stem in `stems` has a PNG cached on disk (downloading from
/// the Twemoji CDN if necessary, in parallel with a small concurrency cap),
/// then decodes each cached PNG into an `RgbaImage` keyed by stem. Stems that
/// fail to download silently drop out of the returned map; callers treat
/// absence as "draw this grapheme through the outline font instead".
pub async fn load_emoji(stems: HashSet<String>) -> HashMap<String, RgbaImage> {
    if stems.is_empty() {
        return HashMap::new();
    }
    let Some(dir) = cache_dir() else {
        return HashMap::new();
    };
    let client = match reqwest::Client::builder().timeout(FETCH_TIMEOUT).build() {
        Ok(c) => c,
        Err(e) => {
            tracing::warn!("emoji cache: failed to build http client: {e}");
            return HashMap::new();
        }
    };
    let base = asset_base(&client).await;
    let sem = std::sync::Arc::new(Semaphore::new(CONCURRENT_FETCHES));
    let mut tasks = FuturesUnordered::new();
    for stem in stems {
        if is_known_missing(&stem) {
            continue;
        }
        let path = dir.join(format!("{stem}.png"));
        let client = client.clone();
        let sem = sem.clone();
        let base = base.clone();
        tasks.push(async move {
            let bytes = read_or_fetch(&client, &sem, &stem, &base, &path).await?;
            image::load_from_memory(&bytes)
                .ok()
                .map(|img| (stem, img.to_rgba8()))
        });
    }
    let mut out = HashMap::new();
    while let Some(maybe) = tasks.next().await {
        if let Some((stem, img)) = maybe {
            out.insert(stem, img);
        }
    }
    out
}

/// Builds the `assets/72x72` base URL against the resolved-once Twemoji
/// version. The resolve happens at most once per process.
async fn asset_base(client: &reqwest::Client) -> String {
    static VERSION: OnceCell<String> = OnceCell::const_new();
    let version = VERSION
        .get_or_init(|| resolve_twemoji_version(client.clone()))
        .await;
    format!("{TWEMOJI_REPO}@{version}/assets/72x72")
}

/// Looks up the newest published `jdecked/twemoji` version via jsDelivr's
/// data API. Falls back to [`FALLBACK_TWEMOJI_VERSION`] on any failure.
async fn resolve_twemoji_version(client: reqwest::Client) -> String {
    match client.get(TWEMOJI_RESOLVE_URL).send().await {
        Ok(resp) => match resp.json::<serde_json::Value>().await {
            Ok(v) => {
                if let Some(ver) = v.get("version").and_then(|x| x.as_str()) {
                    tracing::info!(version = ver, "twemoji: resolved latest version");
                    return ver.to_string();
                }
                tracing::warn!("twemoji: resolve response missing version field");
            }
            Err(e) => tracing::warn!("twemoji: resolve parse failed: {e}"),
        },
        Err(e) => tracing::warn!("twemoji: resolve fetch failed: {e}"),
    }
    tracing::info!(
        version = FALLBACK_TWEMOJI_VERSION,
        "twemoji: using fallback version"
    );
    FALLBACK_TWEMOJI_VERSION.to_string()
}

async fn read_or_fetch(
    client: &reqwest::Client,
    sem: &Semaphore,
    stem: &str,
    base: &str,
    path: &std::path::Path,
) -> Option<Vec<u8>> {
    if let Ok(bytes) = tokio::fs::read(path).await {
        if !bytes.is_empty() {
            return Some(bytes);
        }
    }
    let _permit = sem.acquire().await.ok()?;
    let url = format!("{base}/{stem}.png");
    let resp = match client.get(&url).send().await {
        Ok(r) => r,
        Err(e) => {
            tracing::debug!("emoji fetch failed for {stem}: {e}");
            return None;
        }
    };
    if !resp.status().is_success() {
        tracing::debug!("emoji fetch {stem}: status {}", resp.status());
        mark_missing(stem);
        return None;
    }
    let bytes = resp.bytes().await.ok()?.to_vec();
    if let Err(e) = tokio::fs::write(path, &bytes).await {
        tracing::warn!("emoji cache write failed for {stem}: {e}");
    } else {
        tracing::debug!(stem, "emoji cached");
    }
    Some(bytes)
}

/// Stems that returned a non-200 this process. Prevents re-probing an emoji
/// the pinned Twemoji version lacks (newer than the release, or a filename
/// quirk) on every block of every screenshot in a session.
fn missing_set() -> &'static Mutex<HashSet<String>> {
    static MISSING: OnceLock<Mutex<HashSet<String>>> = OnceLock::new();
    MISSING.get_or_init(|| Mutex::new(HashSet::new()))
}

fn is_known_missing(stem: &str) -> bool {
    missing_set()
        .lock()
        .map(|s| s.contains(stem))
        .unwrap_or(false)
}

fn mark_missing(stem: &str) {
    if let Ok(mut s) = missing_set().lock() {
        s.insert(stem.to_string());
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::text::Span;

    #[test]
    fn stem_flag_us() {
        assert_eq!(twemoji_stem("🇺🇸"), "1f1fa-1f1f8");
        assert_eq!(twemoji_stem("🇯🇵"), "1f1ef-1f1f5");
    }

    #[test]
    fn stem_single_codepoint() {
        assert_eq!(twemoji_stem("🔥"), "1f525");
        assert_eq!(twemoji_stem("👍"), "1f44d");
    }

    #[test]
    fn stem_strips_fe0f_without_zwj() {
        // ❤️ = U+2764 U+FE0F, no ZWJ → FE0F dropped.
        assert_eq!(twemoji_stem("❤️"), "2764");
        // ☺️ = U+263A U+FE0F.
        assert_eq!(twemoji_stem("☺️"), "263a");
    }

    #[test]
    fn stem_keycap_strips_fe0f() {
        // 1️⃣ = U+0031 U+FE0F U+20E3, no ZWJ → FE0F dropped, keycap kept.
        assert_eq!(twemoji_stem("1️⃣"), "31-20e3");
    }

    #[test]
    fn stem_skin_tone_modifier() {
        assert_eq!(twemoji_stem("👍🏿"), "1f44d-1f3ff");
    }

    #[test]
    fn stem_zwj_sequence_keeps_all() {
        // Family is a ZWJ sequence → every codepoint (incl. joiners) kept.
        assert_eq!(twemoji_stem("👨‍👩‍👧‍👦"), "1f468-200d-1f469-200d-1f467-200d-1f466");
    }

    #[test]
    fn is_emoji_accepts_emoji_rejects_text() {
        assert!(is_emoji_grapheme("🔥"));
        assert!(is_emoji_grapheme("🇺🇸"));
        assert!(is_emoji_grapheme("❤️"));
        assert!(!is_emoji_grapheme("a"));
        assert!(!is_emoji_grapheme("1"));
        assert!(!is_emoji_grapheme("#"));
        assert!(!is_emoji_grapheme(" "));
        assert!(!is_emoji_grapheme("漢"));
    }

    #[test]
    fn extract_collects_emoji_stems_across_spans() {
        let lines = vec![
            Line::from(vec![Span::raw("@a fire 🔥 here"), Span::raw(" and 🇯🇵")]),
            Line::from(vec![Span::raw("text only, no emoji")]),
            Line::from(vec![Span::raw("dup 🔥")]),
        ];
        let stems = extract_emoji_stems(&lines);
        assert!(stems.contains("1f525"));
        assert!(stems.contains("1f1ef-1f1f5"));
        assert_eq!(stems.len(), 2);
    }

    #[test]
    fn extract_ignores_plain_text() {
        let lines = vec![Line::from(vec![Span::raw("just words and #hashtags 123")])];
        assert!(extract_emoji_stems(&lines).is_empty());
    }
}
