//! Screenshot compose mode. Pressing `S` or `C` enters a modal picker where
//! the user chooses one of four preset themes, the "match TUI" option, or
//! tunes a custom two-color theme, then commits via save-to-disk or
//! copy-to-clipboard. The actual image render happens after commit, in a
//! tokio task, so the modal stays snappy.

use super::app::{App, DEFAULT_STATUS, InputMode};
use crate::config;
use crate::model::Tweet;
use crate::tui::event::Event;
use crate::tui::external::{self, OpenTarget};
use crate::tui::focus;
use crate::tui::screenshot::{
    self, Capture, PRESET_ARCADE, PRESET_BLUEPRINT, PRESET_CUTOUT, PRESET_GLASS, PRESET_MOSS,
    PRESET_SYNTHWAVE, RenderArgs, ShotTheme, TweetBlock,
};
use crate::tui::ui::{self, FlagStyle, RenderContext, RenderOpts};
use image::RgbaImage;
use ratatui::text::Line;
use std::path::PathBuf;

const MAX_THREAD_DEPTH: usize = 20;

/// Inputs collected per tweet on the main thread before the async compose
/// task starts: rendered lines, media-image targets to load, the avatar
/// URL to fetch, and where its bytes are cached on disk.
type ThreadBlockInputs = (
    Vec<Line<'static>>,
    Vec<OpenTarget>,
    Option<String>,
    Option<PathBuf>,
);

/// Columns the screenshot renders at. Shares the same constant the renderer
/// uses for its buffer width so `tweet_lines`'s body wrap produces lines
/// that fit exactly, not lines that get re-wrapped (and lose indent) at
/// rasterize time.
const SHOT_COLS: usize = screenshot::CONTENT_COLS as usize;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Destination {
    Disk,
    Clipboard,
}

/// One preset slot in the modal. `Match` derives from the live TUI theme,
/// `Custom` is user-supplied via tune input, the numbered slots are fixed
/// presets. Kept `Copy` so cycling/selection is frictionless.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ThemeSlot {
    Glass,
    Synthwave,
    Cutout,
    Moss,
    Blueprint,
    Arcade,
    Match,
    Custom,
}

impl ThemeSlot {
    pub fn label(self) -> &'static str {
        match self {
            Self::Glass => "glass",
            Self::Synthwave => "synthwave",
            Self::Cutout => "cutout",
            Self::Moss => "moss",
            Self::Blueprint => "blueprint",
            Self::Arcade => "arcade",
            Self::Match => "match tui",
            Self::Custom => "custom",
        }
    }

    pub fn digit(self) -> Option<char> {
        match self {
            Self::Glass => Some('1'),
            Self::Synthwave => Some('2'),
            Self::Cutout => Some('3'),
            Self::Moss => Some('4'),
            Self::Blueprint => Some('5'),
            Self::Arcade => Some('6'),
            Self::Match => Some('7'),
            Self::Custom => None,
        }
    }

    pub const ORDER: [ThemeSlot; 8] = [
        Self::Glass,
        Self::Synthwave,
        Self::Cutout,
        Self::Moss,
        Self::Blueprint,
        Self::Arcade,
        Self::Match,
        Self::Custom,
    ];
}

/// Mutable state kept while the compose modal is open. Dropped on commit or
/// cancel. Stores the cloned tweet so the underlying source list can
/// continue to scroll behind the modal without breaking the capture.
#[derive(Debug)]
pub struct ComposeState {
    pub tweet: crate::model::Tweet,
    pub destination: Destination,
    pub selected: ThemeSlot,
    pub custom: Option<ShotTheme>,
    pub tune_buffer: Option<String>,
    pub tune_error: Option<String>,
    pub last_status: Option<String>,
    /// When true and the focal tweet is itself a reply, the screenshot
    /// captures the entire ancestor chain — root tweet down to the focal —
    /// stacked vertically as one image. Toggle with `T` in the modal.
    pub include_thread: bool,
}

impl ComposeState {
    pub fn resolved_theme(&self, tui: &crate::tui::theme::Theme) -> ShotTheme {
        match self.selected {
            ThemeSlot::Glass => PRESET_GLASS,
            ThemeSlot::Synthwave => PRESET_SYNTHWAVE,
            ThemeSlot::Cutout => PRESET_CUTOUT,
            ThemeSlot::Moss => PRESET_MOSS,
            ThemeSlot::Blueprint => PRESET_BLUEPRINT,
            ThemeSlot::Arcade => PRESET_ARCADE,
            ThemeSlot::Match => ShotTheme::from_tui(tui),
            ThemeSlot::Custom => self.custom.unwrap_or_else(|| ShotTheme::from_tui(tui)),
        }
    }
}

impl App {
    pub(super) fn screenshot_save(&mut self) {
        self.open_compose(Destination::Disk);
    }

    pub(super) fn screenshot_copy(&mut self) {
        self.open_compose(Destination::Clipboard);
    }

    fn open_compose(&mut self, destination: Destination) {
        let Some(tweet) = self.selected_tweet().cloned() else {
            self.set_status("no tweet selected");
            return;
        };
        let default_slot = ThemeSlot::Match;
        self.compose = Some(ComposeState {
            tweet,
            destination,
            selected: default_slot,
            custom: None,
            tune_buffer: None,
            tune_error: None,
            last_status: None,
            include_thread: false,
        });
        self.mode = InputMode::ScreenshotCompose;
    }

    pub(super) fn compose_toggle_thread(&mut self) {
        if let Some(c) = self.compose.as_mut() {
            c.include_thread = !c.include_thread;
        }
    }

    pub(super) fn compose_toggle_display_names(&mut self) {
        self.screenshot_show_display_names = !self.screenshot_show_display_names;
        self.save_session();
    }

    pub(super) fn compose_toggle_metrics(&mut self) {
        self.screenshot_show_metrics = !self.screenshot_show_metrics;
        self.save_session();
    }

    pub(super) fn compose_select(&mut self, slot: ThemeSlot) {
        if let Some(c) = self.compose.as_mut() {
            c.selected = slot;
            c.tune_error = None;
        }
    }

    pub(super) fn compose_begin_tune(&mut self) {
        if let Some(c) = self.compose.as_mut() {
            let seed = c
                .custom
                .map(|t| {
                    format!(
                        "#{:02x}{:02x}{:02x} #{:02x}{:02x}{:02x}",
                        t.bg[0], t.bg[1], t.bg[2], t.accent[0], t.accent[1], t.accent[2]
                    )
                })
                .unwrap_or_default();
            c.tune_buffer = Some(seed);
            c.tune_error = None;
        }
    }

    pub(super) fn compose_tune_input(&mut self, edit: impl FnOnce(&mut String)) {
        if let Some(c) = self.compose.as_mut() {
            if let Some(buf) = c.tune_buffer.as_mut() {
                edit(buf);
                c.tune_error = None;
            }
        }
    }

    pub(super) fn compose_tune_submit(&mut self) {
        let Some(c) = self.compose.as_mut() else {
            return;
        };
        let Some(buf) = c.tune_buffer.take() else {
            return;
        };
        match screenshot::parse_tune(&buf) {
            Ok((bg, accent)) => {
                c.custom = Some(ShotTheme::from_colors(bg, accent));
                c.selected = ThemeSlot::Custom;
                c.tune_error = None;
            }
            Err(e) => {
                c.tune_error = Some(e);
                c.tune_buffer = Some(buf);
            }
        }
    }

    pub(super) fn compose_tune_cancel(&mut self) {
        if let Some(c) = self.compose.as_mut() {
            c.tune_buffer = None;
            c.tune_error = None;
        }
    }

    pub(super) fn compose_cancel(&mut self) {
        self.compose = None;
        self.mode = InputMode::Normal;
        self.set_status("screenshot cancelled");
    }

    pub(super) fn compose_confirm(&mut self, destination: Destination) {
        let Some(c) = self.compose.as_ref() else {
            return;
        };
        let tweet = c.tweet.clone();
        let shot = {
            let tui = crate::tui::theme::active();
            c.resolved_theme(&tui)
        };
        let include_thread = c.include_thread && tweet.in_reply_to_tweet_id.is_some();
        self.compose = None;
        self.mode = InputMode::Normal;

        if include_thread {
            self.spawn_thread_screenshot_fetch(tweet, shot, destination);
        } else {
            self.commit_single_screenshot(tweet, shot, destination);
        }
    }

    /// Fetch the focal tweet's full conversation, walk parents up to the
    /// root, and dispatch a `ScreenshotThreadResolved` event back to the
    /// main loop. The render itself happens on the main thread (under a
    /// theme swap) once the chain is in hand.
    fn spawn_thread_screenshot_fetch(
        &mut self,
        tweet: Tweet,
        shot: ShotTheme,
        destination: Destination,
    ) {
        let theme_name = shot.name;
        let label = match destination {
            Destination::Disk => format!("fetching thread for [{theme_name}] → disk…"),
            Destination::Clipboard => format!("fetching thread for [{theme_name}] → clipboard…"),
        };
        self.set_status(label);
        let client = self.client.clone();
        let tx = self.tx.clone();
        let focal_id = tweet.rest_id.clone();
        tokio::spawn(async move {
            let result = match focus::fetch_thread(&client, &focal_id).await {
                Ok(page) => {
                    let by_id: std::collections::HashMap<String, Tweet> = page
                        .tweets
                        .into_iter()
                        .map(|t| (t.rest_id.clone(), t))
                        .collect();
                    Ok(walk_ancestor_chain(&tweet, &by_id))
                }
                Err(e) => Err(e.to_string()),
            };
            let _ = tx.send(Event::ScreenshotThreadResolved {
                result,
                shot,
                destination,
            });
        });
    }

    pub(super) fn handle_screenshot_thread_resolved(
        &mut self,
        result: std::result::Result<Vec<Tweet>, String>,
        shot: ShotTheme,
        destination: Destination,
    ) {
        match result {
            Ok(chain) if !chain.is_empty() => {
                tracing::info!(
                    focal_id = %chain.last().map(|t| t.rest_id.as_str()).unwrap_or(""),
                    chain_len = chain.len(),
                    "screenshot: thread chain resolved"
                );
                self.commit_thread_screenshot(chain, shot, destination);
            }
            Ok(_) => {
                self.set_status("thread fetch returned no tweets");
            }
            Err(e) => {
                tracing::warn!("screenshot: thread fetch failed: {e}");
                self.set_status(format!("thread fetch failed: {e}"));
            }
        }
    }

    fn commit_single_screenshot(
        &mut self,
        tweet: Tweet,
        shot: ShotTheme,
        destination: Destination,
    ) {
        let theme_name = shot.name.to_string();
        let lines = self.build_focal_lines_with(&tweet, &shot);
        let Some(cache_dir) = self.resolve_cache_dir() else {
            return;
        };
        let media_dir = cache_dir.join("media").join(&tweet.rest_id);
        let screenshots_dir = cache_dir.join("screenshots");
        let targets = collect_image_targets(&tweet, &media_dir);
        let avatar_url = self
            .feed_avatars
            .then(|| tweet.author.avatar_url.clone())
            .flatten();
        let avatar_cache_path = avatar_url
            .as_deref()
            .and_then(|url| self.media.avatar_cache_path(url));

        self.set_status(status_label("capturing", &theme_name, destination));
        let tx = self.tx.clone();
        let tweet_id = tweet.rest_id.clone();

        tokio::spawn(async move {
            let images = load_image_targets(targets).await;
            let author_avatar = match avatar_url {
                Some(url) => load_avatar_image(&url, avatar_cache_path.as_deref()).await,
                None => None,
            };
            let flag_codes = crate::tui::flag_cache::extract_alpha2_codes(&lines);
            let flags = crate::tui::flag_cache::load_flags(flag_codes).await;
            let capture = screenshot::render(RenderArgs {
                tweet_id,
                blocks: vec![TweetBlock {
                    lines,
                    media_images: images,
                    author_avatar,
                    flags,
                }],
                shot_theme: &shot,
            });
            dispatch_capture(capture, screenshots_dir, destination, tx).await;
        });
    }

    fn commit_thread_screenshot(
        &mut self,
        chain: Vec<Tweet>,
        shot: ShotTheme,
        destination: Destination,
    ) {
        let theme_name = shot.name.to_string();
        let Some(cache_dir) = self.resolve_cache_dir() else {
            return;
        };
        let screenshots_dir = cache_dir.join("screenshots");

        let tweet_id = chain.last().map(|t| t.rest_id.clone()).unwrap_or_default();
        let chain_len = chain.len();

        let mut per_tweet: Vec<ThreadBlockInputs> = Vec::with_capacity(chain_len);
        let saved_theme = crate::tui::theme::active().clone();
        crate::tui::theme::set_active(shot.synthesize_tui());
        for tweet in &chain {
            let lines = self.build_lines_for(tweet, true);
            let media_dir = cache_dir.join("media").join(&tweet.rest_id);
            let targets = collect_image_targets(tweet, &media_dir);
            let avatar_url = self
                .feed_avatars
                .then(|| tweet.author.avatar_url.clone())
                .flatten();
            let avatar_cache_path = avatar_url
                .as_deref()
                .and_then(|url| self.media.avatar_cache_path(url));
            per_tweet.push((lines, targets, avatar_url, avatar_cache_path));
        }
        crate::tui::theme::set_active(saved_theme);

        self.set_status(format!(
            "{} ({} tweets)",
            status_label("capturing", &theme_name, destination),
            chain_len
        ));

        let tx = self.tx.clone();
        tokio::spawn(async move {
            let mut blocks: Vec<TweetBlock> = Vec::with_capacity(per_tweet.len());
            for (lines, targets, avatar_url, avatar_cache_path) in per_tweet {
                let images = load_image_targets(targets).await;
                let author_avatar = match avatar_url {
                    Some(url) => load_avatar_image(&url, avatar_cache_path.as_deref()).await,
                    None => None,
                };
                let flag_codes = crate::tui::flag_cache::extract_alpha2_codes(&lines);
                let flags = crate::tui::flag_cache::load_flags(flag_codes).await;
                blocks.push(TweetBlock {
                    lines,
                    media_images: images,
                    author_avatar,
                    flags,
                });
            }
            let capture = screenshot::render(RenderArgs {
                tweet_id,
                blocks,
                shot_theme: &shot,
            });
            dispatch_capture(capture, screenshots_dir, destination, tx).await;
        });
    }

    fn resolve_cache_dir(&mut self) -> Option<PathBuf> {
        match config::cache_dir() {
            Ok(p) => Some(p),
            Err(e) => {
                self.error = Some(format!("cache dir: {e}"));
                None
            }
        }
    }

    pub(super) fn handle_screenshot_saved(&mut self, result: std::result::Result<PathBuf, String>) {
        match result {
            Ok(path) => self.set_status(format!("saved: {}", path.display())),
            Err(e) => self.set_status(format!("screenshot failed: {e}")),
        }
    }

    pub(super) fn handle_screenshot_copied(&mut self, result: std::result::Result<(), String>) {
        match result {
            Ok(()) => self.set_status("screenshot copied to clipboard"),
            Err(e) => self.set_status(format!("clipboard failed: {e}")),
        }
    }

    /// Build the focal tweet's styled lines under a temporarily-swapped TUI
    /// theme synthesized from the chosen `ShotTheme`. The swap is confined
    /// to this synchronous scope: `set_active` → build lines → `set_active`
    /// back. Nothing else reads the theme during this window because event
    /// handlers run serialized.
    fn build_focal_lines_with(
        &self,
        tweet: &crate::model::Tweet,
        shot: &ShotTheme,
    ) -> Vec<Line<'static>> {
        let saved = crate::tui::theme::active().clone();
        crate::tui::theme::set_active(shot.synthesize_tui());
        let lines = self.build_focal_lines(tweet);
        crate::tui::theme::set_active(saved);
        lines
    }

    fn build_focal_lines(&self, tweet: &crate::model::Tweet) -> Vec<Line<'static>> {
        self.build_lines_for(tweet, false)
    }

    /// `in_reply_context = true` for thread-mode blocks — the visual chain
    /// already communicates the reply relationship, so leading `@parent`
    /// mentions and the `↳` reply icon become noise.
    fn build_lines_for(
        &self,
        tweet: &crate::model::Tweet,
        in_reply_context: bool,
    ) -> Vec<Line<'static>> {
        let opts = RenderOpts {
            timestamps: self.timestamps,
            metrics: if self.screenshot_show_metrics {
                crate::tui::app::MetricsStyle::Visible
            } else {
                crate::tui::app::MetricsStyle::Hidden
            },
            display_names: if self.screenshot_show_display_names {
                crate::tui::app::DisplayNameStyle::Visible
            } else {
                crate::tui::app::DisplayNameStyle::Hidden
            },
            media_enabled: false,
            media_auto_expand: false,
            media_max_rows: 0,
            feed_avatars: self.feed_avatars && tweet.author.avatar_url.is_some(),
            avatars_inline_kitty: false,
            flag_style: FlagStyle::Emoji,
            suppress_metrics_row: !self.screenshot_show_metrics,
        };
        let ctx = RenderContext {
            opts,
            raw_display_names: self.display_names,
            seen: &self.seen,
            expanded: &self.expanded_bodies,
            inline_threads: &self.inline_threads,
            media_reg: &self.media,
            youtube: &self.youtube,
            songlink_reg: &self.songlink_reg,
            translations: &self.translations,
            liked_tweet_ids: &self.liked_tweet_ids,
            about_store: &self.about,
            write_rate_limit: None,
            self_handle: None,
            cell_size_override: Some(screenshot::grid_cell_size()),
        };
        ui::tweet_lines(tweet, &ctx, false, in_reply_context, SHOT_COLS, true)
    }
}

fn image_only(targets: Vec<OpenTarget>) -> Vec<OpenTarget> {
    targets
        .into_iter()
        .filter(|t| {
            let ext = t
                .path
                .extension()
                .and_then(|e| e.to_str())
                .unwrap_or("")
                .to_ascii_lowercase();
            matches!(ext.as_str(), "jpg" | "jpeg" | "png" | "gif" | "webp")
        })
        .collect()
}

fn collect_image_targets(tweet: &Tweet, media_dir: &std::path::Path) -> Vec<OpenTarget> {
    let all = external::collect_open_targets(tweet, media_dir);
    let images = image_only(all.clone());
    tracing::info!(
        tweet_id = %tweet.rest_id,
        media_count = tweet.media.len(),
        targets_total = all.len(),
        targets_image = images.len(),
        "screenshot: collected media targets"
    );
    images
}

fn status_label(verb: &str, theme_name: &str, destination: Destination) -> String {
    match destination {
        Destination::Disk => format!("{verb} [{theme_name}] → disk…"),
        Destination::Clipboard => format!("{verb} [{theme_name}] → clipboard…"),
    }
}

async fn dispatch_capture(
    capture: Capture,
    screenshots_dir: PathBuf,
    destination: Destination,
    tx: crate::tui::event::EventTx,
) {
    match destination {
        Destination::Disk => {
            let result = tokio::task::spawn_blocking(move || capture.save(&screenshots_dir))
                .await
                .unwrap_or_else(|e| Err(format!("join: {e}")));
            let _ = tx.send(Event::ScreenshotSaved { result });
        }
        Destination::Clipboard => {
            let result = tokio::task::spawn_blocking(move || run_clipboard(&capture))
                .await
                .unwrap_or_else(|e| Err(format!("join: {e}")));
            let _ = tx.send(Event::ScreenshotCopied { result });
        }
    }
}

/// Walk `tweet.in_reply_to_tweet_id` up the chain in `by_id`, capping at
/// `MAX_THREAD_DEPTH`. Returns the chain in **root → focal** order. The
/// focal is always present even when no ancestor was resolved.
fn walk_ancestor_chain(
    focal: &Tweet,
    by_id: &std::collections::HashMap<String, Tweet>,
) -> Vec<Tweet> {
    let mut chain = vec![focal.clone()];
    let mut current = focal.in_reply_to_tweet_id.clone();
    let mut visited: std::collections::HashSet<String> =
        std::iter::once(focal.rest_id.clone()).collect();
    while let Some(id) = current {
        if !visited.insert(id.clone()) {
            break;
        }
        if chain.len() >= MAX_THREAD_DEPTH {
            break;
        }
        match by_id.get(&id) {
            Some(parent) => {
                current = parent.in_reply_to_tweet_id.clone();
                chain.push(parent.clone());
            }
            None => break,
        }
    }
    chain.reverse();
    chain
}

async fn load_image_targets(targets: Vec<OpenTarget>) -> Vec<RgbaImage> {
    if targets.is_empty() {
        let _ = DEFAULT_STATUS;
        return Vec::new();
    }
    if let Some(parent) = targets.first().and_then(|t| t.path.parent()) {
        if let Err(e) = tokio::fs::create_dir_all(parent).await {
            tracing::warn!(error = %e, "screenshot: media dir create failed");
            return Vec::new();
        }
    }
    let client = reqwest::Client::new();
    let mut out = Vec::with_capacity(targets.len());
    for t in &targets {
        let cached = tokio::fs::try_exists(&t.path).await.unwrap_or(false);
        if !cached {
            tracing::info!(url = %t.url, path = %t.path.display(), "screenshot: fetching media");
            match client.get(&t.url).send().await {
                Ok(resp) => match resp.error_for_status() {
                    Ok(resp) => match resp.bytes().await {
                        Ok(bytes) => {
                            if let Err(e) = tokio::fs::write(&t.path, &bytes).await {
                                tracing::warn!(error = %e, path = %t.path.display(), "screenshot: media write failed");
                                continue;
                            }
                        }
                        Err(e) => {
                            tracing::warn!(error = %e, url = %t.url, "screenshot: media body read failed");
                            continue;
                        }
                    },
                    Err(e) => {
                        tracing::warn!(error = %e, url = %t.url, "screenshot: media status error");
                        continue;
                    }
                },
                Err(e) => {
                    tracing::warn!(error = %e, url = %t.url, "screenshot: media fetch failed");
                    continue;
                }
            }
        } else {
            tracing::debug!(path = %t.path.display(), "screenshot: media cache hit");
        }
        let path = t.path.clone();
        let decoded = tokio::task::spawn_blocking(move || image::open(&path))
            .await
            .ok()
            .and_then(|r| r.ok())
            .map(|img| img.into_rgba8());
        match decoded {
            Some(img) => {
                tracing::info!(
                    path = %t.path.display(),
                    width = img.width(),
                    height = img.height(),
                    "screenshot: decoded media"
                );
                out.push(img);
            }
            None => {
                tracing::warn!(path = %t.path.display(), "screenshot: media decode failed");
            }
        }
    }
    tracing::info!(
        loaded = out.len(),
        requested = targets.len(),
        "screenshot: media load complete"
    );
    out
}

fn run_clipboard(capture: &Capture) -> std::result::Result<(), String> {
    capture.copy_to_clipboard()
}

/// Resolve an avatar URL to an `RgbaImage` for screenshot compositing.
/// Prefers the on-disk cache that `MediaRegistry::ensure_avatar_url`
/// populates so the live-TUI fetch is reused. Falls back to a one-shot
/// HTTP GET on miss. Returns `None` on any failure; the renderer then
/// just leaves the gutter blank.
async fn load_avatar_image(url: &str, cache_path: Option<&std::path::Path>) -> Option<RgbaImage> {
    if url.is_empty() {
        return None;
    }
    let bytes = match cache_path {
        Some(path) => match tokio::fs::read(path).await {
            Ok(b) if !b.is_empty() => b,
            _ => fetch_avatar_bytes(url, cache_path).await?,
        },
        None => fetch_avatar_bytes(url, None).await?,
    };
    let img = tokio::task::spawn_blocking(move || image::load_from_memory(&bytes))
        .await
        .ok()?
        .ok()?;
    Some(img.into_rgba8())
}

async fn fetch_avatar_bytes(url: &str, cache_path: Option<&std::path::Path>) -> Option<Vec<u8>> {
    let resp = reqwest::Client::new()
        .get(url)
        .send()
        .await
        .ok()?
        .error_for_status()
        .ok()?;
    let bytes = resp.bytes().await.ok()?.to_vec();
    if let Some(path) = cache_path {
        if let Some(parent) = path.parent() {
            let _ = tokio::fs::create_dir_all(parent).await;
        }
        let tmp = path.with_extension("bin.tmp");
        if tokio::fs::write(&tmp, &bytes).await.is_ok() {
            let _ = tokio::fs::rename(&tmp, path).await;
        }
    }
    Some(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tui::test_util::make_tweet;
    use std::collections::HashMap;

    fn with_parent(id: &str, parent: Option<&str>) -> Tweet {
        let mut t = make_tweet(id, "body");
        t.in_reply_to_tweet_id = parent.map(String::from);
        t
    }

    #[test]
    fn ancestor_chain_orders_root_to_focal() {
        let root = with_parent("a", None);
        let mid = with_parent("b", Some("a"));
        let focal = with_parent("c", Some("b"));
        let by_id: HashMap<String, Tweet> = [root.clone(), mid.clone()]
            .into_iter()
            .map(|t| (t.rest_id.clone(), t))
            .collect();
        let chain = walk_ancestor_chain(&focal, &by_id);
        assert_eq!(
            chain.iter().map(|t| t.rest_id.as_str()).collect::<Vec<_>>(),
            vec!["a", "b", "c"]
        );
    }

    #[test]
    fn ancestor_chain_returns_focal_only_when_no_ancestor() {
        let focal = with_parent("solo", None);
        let by_id: HashMap<String, Tweet> = HashMap::new();
        let chain = walk_ancestor_chain(&focal, &by_id);
        assert_eq!(chain.len(), 1);
        assert_eq!(chain[0].rest_id, "solo");
    }

    #[test]
    fn ancestor_chain_stops_at_missing_parent() {
        let focal = with_parent("c", Some("b"));
        let by_id: HashMap<String, Tweet> = HashMap::new();
        let chain = walk_ancestor_chain(&focal, &by_id);
        assert_eq!(chain.len(), 1);
        assert_eq!(chain[0].rest_id, "c");
    }

    #[test]
    fn ancestor_chain_breaks_on_cycle() {
        let a = with_parent("a", Some("b"));
        let b = with_parent("b", Some("a"));
        let by_id: HashMap<String, Tweet> = [a.clone(), b.clone()]
            .into_iter()
            .map(|t| (t.rest_id.clone(), t))
            .collect();
        let chain = walk_ancestor_chain(&a, &by_id);
        assert!(chain.len() <= 2);
        assert_eq!(chain.last().unwrap().rest_id, "a");
    }

    #[test]
    fn ancestor_chain_caps_depth() {
        let mut by_id: HashMap<String, Tweet> = HashMap::new();
        for i in 0..(MAX_THREAD_DEPTH + 5) {
            let id = format!("t{i}");
            let parent = if i == 0 {
                None
            } else {
                Some(format!("t{}", i - 1))
            };
            by_id.insert(id.clone(), with_parent(&id, parent.as_deref()));
        }
        let focal_id = format!("t{}", MAX_THREAD_DEPTH + 4);
        let focal = by_id[&focal_id].clone();
        let chain = walk_ancestor_chain(&focal, &by_id);
        assert!(chain.len() <= MAX_THREAD_DEPTH);
        assert_eq!(chain.last().unwrap().rest_id, focal_id);
    }
}
