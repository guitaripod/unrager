//! Screenshot compose mode. Pressing `S` or `C` enters a modal picker where
//! the user chooses one of four preset themes, the "match TUI" option, or
//! tunes a custom two-color theme, then commits via save-to-disk or
//! copy-to-clipboard. The actual image render happens after commit, in a
//! tokio task, so the modal stays snappy.

use super::app::{App, DEFAULT_STATUS, InputMode};
use crate::config;
use crate::tui::event::Event;
use crate::tui::external::{self, OpenTarget};
use crate::tui::screenshot::{
    self, Capture, PRESET_ARCADE, PRESET_BLUEPRINT, PRESET_CUTOUT, PRESET_GLASS, PRESET_MOSS,
    PRESET_SYNTHWAVE, RenderArgs, ShotTheme,
};
use crate::tui::ui::{self, RenderContext, RenderOpts};
use image::RgbaImage;
use ratatui::text::Line;
use std::path::PathBuf;

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
        });
        self.mode = InputMode::ScreenshotCompose;
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
        let theme_name = shot.name.to_string();
        self.compose = None;
        self.mode = InputMode::Normal;

        let lines = self.build_focal_lines_with(&tweet, &shot);
        let cache_dir = match config::cache_dir() {
            Ok(p) => p,
            Err(e) => {
                self.error = Some(format!("cache dir: {e}"));
                return;
            }
        };
        let media_dir = cache_dir.join("media").join(&tweet.rest_id);
        let screenshots_dir = cache_dir.join("screenshots");
        let targets = image_only(external::collect_open_targets(&tweet, &media_dir));
        let tx = self.tx.clone();
        let tweet_id = tweet.rest_id.clone();

        let label = match destination {
            Destination::Disk => format!("capturing [{theme_name}] → disk…"),
            Destination::Clipboard => format!("capturing [{theme_name}] → clipboard…"),
        };
        self.set_status(label);

        tokio::spawn(async move {
            let images = load_image_targets(targets).await;
            let capture = screenshot::render(RenderArgs {
                tweet_id,
                lines,
                media_images: images,
                shot_theme: &shot,
            });
            match destination {
                Destination::Disk => {
                    let result =
                        tokio::task::spawn_blocking(move || capture.save(&screenshots_dir))
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
        });
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
        let opts = RenderOpts {
            timestamps: self.timestamps,
            metrics: crate::tui::app::MetricsStyle::Visible,
            display_names: crate::tui::app::DisplayNameStyle::Visible,
            media_enabled: false,
            media_auto_expand: false,
            media_max_rows: 0,
        };
        let ctx = RenderContext {
            opts,
            raw_display_names: self.display_names,
            seen: &self.seen,
            expanded: &self.expanded_bodies,
            inline_threads: &self.inline_threads,
            media_reg: &self.media,
            youtube: &self.youtube,
            translations: &self.translations,
            liked_tweet_ids: &self.liked_tweet_ids,
            write_rate_limit: None,
        };
        ui::tweet_lines(tweet, &ctx, false, false, SHOT_COLS, true)
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
        if !tokio::fs::try_exists(&t.path).await.unwrap_or(false) {
            match client.get(&t.url).send().await {
                Ok(resp) => match resp.error_for_status() {
                    Ok(resp) => match resp.bytes().await {
                        Ok(bytes) => {
                            if let Err(e) = tokio::fs::write(&t.path, &bytes).await {
                                tracing::warn!(error = %e, "screenshot: media write failed");
                                continue;
                            }
                        }
                        Err(e) => {
                            tracing::warn!(error = %e, "screenshot: media body read failed");
                            continue;
                        }
                    },
                    Err(e) => {
                        tracing::warn!(error = %e, "screenshot: media status error");
                        continue;
                    }
                },
                Err(e) => {
                    tracing::warn!(error = %e, "screenshot: media fetch failed");
                    continue;
                }
            }
        }
        let path = t.path.clone();
        let decoded = tokio::task::spawn_blocking(move || image::open(&path))
            .await
            .ok()
            .and_then(|r| r.ok())
            .map(|img| img.into_rgba8());
        if let Some(img) = decoded {
            out.push(img);
        }
    }
    out
}

fn run_clipboard(capture: &Capture) -> std::result::Result<(), String> {
    capture.copy_to_clipboard()
}
