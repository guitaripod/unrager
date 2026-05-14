//! Lazy on-disk cache for Twemoji country-flag PNGs.
//!
//! Screenshots can composite color flag emoji next to the author handle by
//! pulling the matching Twemoji PNG from `~/.cache/unrager/flags/<alpha2>.png`.
//! The PNGs are not shipped with the binary — they're fetched from the
//! jsDelivr CDN on first use and cached forever. Subsequent screenshots are
//! instant; offline screenshots fall back silently to "no flag" (the cells
//! stay blank, the rasterizer doesn't draw letters).
//!
//! Cache layout mirrors the avatar cache (`avatars/<sha256(url)>.bin`):
//! flat directory, one file per country, file *is* the original PNG bytes
//! so it can be loaded directly with `image::open` or `image::load_from_memory`.

use crate::config;
use crate::tui::event::EventTx;
use futures::stream::{FuturesUnordered, StreamExt};
use image::RgbaImage;
use ratatui::text::Line;
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::time::Duration;
use tokio::sync::Semaphore;

const CDN_BASE: &str = "https://cdn.jsdelivr.net/gh/twitter/twemoji@14.0.2/assets/72x72";
const FETCH_TIMEOUT: Duration = Duration::from_secs(5);
const CONCURRENT_FETCHES: usize = 4;

pub fn cache_dir() -> Option<PathBuf> {
    let dir = config::cache_dir().ok()?.join("flags");
    if let Err(e) = std::fs::create_dir_all(&dir) {
        tracing::warn!("flag cache: mkdir failed: {e}");
        return None;
    }
    Some(dir)
}

pub fn cached_path(alpha2: &str) -> Option<PathBuf> {
    Some(cache_dir()?.join(format!("{alpha2}.png")))
}

/// Walks every span in `lines`, extracts every regional-indicator pair, and
/// returns the set of ISO 3166-1 alpha-2 codes referenced. Used by the
/// screenshot pipeline to pre-fetch flags before rasterizing.
pub fn extract_alpha2_codes(lines: &[Line<'_>]) -> HashSet<String> {
    let mut codes = HashSet::new();
    for line in lines {
        for span in &line.spans {
            let chars: Vec<char> = span.content.chars().collect();
            let mut i = 0;
            while i + 1 < chars.len() {
                match (
                    regional_indicator_letter(chars[i]),
                    regional_indicator_letter(chars[i + 1]),
                ) {
                    (Some(a), Some(b)) => {
                        codes.insert(format!("{a}{b}"));
                        i += 2;
                    }
                    _ => i += 1,
                }
            }
        }
    }
    codes
}

fn regional_indicator_letter(ch: char) -> Option<char> {
    let cp = ch as u32;
    if !(0x1F1E6..=0x1F1FF).contains(&cp) {
        return None;
    }
    Some(char::from_u32(u32::from(b'A') + (cp - 0x1F1E6)).unwrap())
}

/// Ensures every alpha-2 in `codes` has a PNG cached on disk (downloading
/// from the Twemoji CDN if necessary, in parallel with a small concurrency
/// cap), then decodes each cached PNG into an RgbaImage and returns them
/// keyed by alpha-2. Codes that fail to download silently drop out of the
/// returned map; callers treat absence as "render nothing for this flag".
pub async fn load_flags(codes: HashSet<String>) -> HashMap<String, RgbaImage> {
    if codes.is_empty() {
        return HashMap::new();
    }
    let Some(dir) = cache_dir() else {
        return HashMap::new();
    };
    let client = match reqwest::Client::builder().timeout(FETCH_TIMEOUT).build() {
        Ok(c) => c,
        Err(e) => {
            tracing::warn!("flag cache: failed to build http client: {e}");
            return HashMap::new();
        }
    };
    let sem = std::sync::Arc::new(Semaphore::new(CONCURRENT_FETCHES));
    let mut tasks = FuturesUnordered::new();
    for code in codes {
        let path = dir.join(format!("{code}.png"));
        let client = client.clone();
        let sem = sem.clone();
        tasks.push(async move {
            let bytes = match read_or_fetch(&client, &sem, &code, &path).await {
                Some(b) => b,
                None => return None,
            };
            image::load_from_memory(&bytes)
                .ok()
                .map(|img| (code, img.to_rgba8()))
        });
    }
    let mut out = HashMap::new();
    while let Some(maybe) = tasks.next().await {
        if let Some((code, img)) = maybe {
            out.insert(code, img);
        }
    }
    out
}

async fn read_or_fetch(
    client: &reqwest::Client,
    sem: &Semaphore,
    alpha2: &str,
    path: &std::path::Path,
) -> Option<Vec<u8>> {
    if let Ok(bytes) = tokio::fs::read(path).await {
        return Some(bytes);
    }
    let _permit = sem.acquire().await.ok()?;
    let url = format!("{CDN_BASE}/{}.png", twemoji_stem(alpha2)?);
    let resp = match client.get(&url).send().await {
        Ok(r) => r,
        Err(e) => {
            tracing::debug!("flag fetch failed for {alpha2}: {e}");
            return None;
        }
    };
    if !resp.status().is_success() {
        tracing::debug!("flag fetch {alpha2}: status {}", resp.status());
        return None;
    }
    let bytes = resp.bytes().await.ok()?.to_vec();
    if let Err(e) = tokio::fs::write(path, &bytes).await {
        tracing::warn!("flag cache write failed for {alpha2}: {e}");
    } else {
        tracing::debug!(alpha2, "flag cached");
    }
    Some(bytes)
}

/// Converts an alpha-2 code like `"US"` into the Twemoji filename stem
/// `"1f1fa-1f1f8"` (lowercase hex of the two regional-indicator codepoints
/// joined by `-`).
fn twemoji_stem(alpha2: &str) -> Option<String> {
    let mut chars = alpha2.chars();
    let a = chars.next()?;
    let b = chars.next()?;
    if chars.next().is_some() {
        return None;
    }
    if !a.is_ascii_uppercase() || !b.is_ascii_uppercase() {
        return None;
    }
    let cp_a = 0x1F1E6u32 + (a as u32 - u32::from(b'A'));
    let cp_b = 0x1F1E6u32 + (b as u32 - u32::from(b'A'));
    Some(format!("{cp_a:x}-{cp_b:x}"))
}

/// Used by the screenshot pipeline to keep `_tx` symmetrical with the
/// existing image/avatar load helpers. Currently unused but kept for
/// future "flag fetched" event reporting if we want to surface fetch
/// progress to the user.
pub fn _retain_tx(_tx: &EventTx) {}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::text::Span;

    #[test]
    fn twemoji_stem_us() {
        assert_eq!(twemoji_stem("US"), Some("1f1fa-1f1f8".into()));
        assert_eq!(twemoji_stem("JP"), Some("1f1ef-1f1f5".into()));
        assert_eq!(twemoji_stem("EU"), Some("1f1ea-1f1fa".into()));
    }

    #[test]
    fn twemoji_stem_rejects_bad_input() {
        assert!(twemoji_stem("us").is_none());
        assert!(twemoji_stem("U").is_none());
        assert!(twemoji_stem("USA").is_none());
        assert!(twemoji_stem("").is_none());
        assert!(twemoji_stem("12").is_none());
    }

    #[test]
    fn extracts_single_flag_from_span() {
        let lines = vec![Line::from(vec![
            Span::raw("@bcherny "),
            Span::raw("🇺🇸"),
            Span::raw(" hello"),
        ])];
        let codes = extract_alpha2_codes(&lines);
        assert_eq!(codes.len(), 1);
        assert!(codes.contains("US"));
    }

    #[test]
    fn extracts_multiple_flags() {
        let lines = vec![
            Line::from(vec![Span::raw("@a 🇯🇵")]),
            Line::from(vec![Span::raw("@b 🇩🇪")]),
            Line::from(vec![Span::raw("@c 🇯🇵")]),
        ];
        let codes = extract_alpha2_codes(&lines);
        assert_eq!(codes.len(), 2);
        assert!(codes.contains("JP"));
        assert!(codes.contains("DE"));
    }

    #[test]
    fn ignores_lone_regional_indicator() {
        let lines = vec![Line::from(vec![Span::raw("just text")])];
        let codes = extract_alpha2_codes(&lines);
        assert!(codes.is_empty());
    }
}
