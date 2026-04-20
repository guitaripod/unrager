//! Tweet-card screenshots. Renders the focal tweet (status row, body, accent
//! bar, composited media) onto an `RgbaImage` using a bundled monospace font,
//! then exposes the result as PNG bytes plus two independent outputs: a
//! file on disk and a clipboard yank. The render path has a single
//! responsibility (pixels); the output path (save vs clipboard) is the
//! caller's choice so future outputs can be added without touching rendering.
//!
//! The screenshot's visual look is controlled by a [`ShotTheme`] — a minimal
//! palette (bg, text, muted, accent) decoupled from the TUI's full `Theme`.
//! Four presets plus a custom "two-color" builder let users restyle the
//! screenshot without touching their live TUI theme.

use ab_glyph::{Font, FontRef, Glyph, PxScale, ScaleFont, point};
use image::{Rgba, RgbaImage, imageops};
use ratatui::buffer::Buffer;
use ratatui::layout::Rect;
use ratatui::style::Style;
use ratatui::style::{Color, Modifier};
use ratatui::text::Line;
use ratatui::text::Span;
use ratatui::widgets::{Paragraph, Widget};
use std::path::{Path, PathBuf};
use std::sync::LazyLock;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::tui::theme::Theme;

const FONT_REG_DATA: &[u8] = include_bytes!("../../assets/NotoSansMono-Regular.ttf");
const FONT_BOLD_DATA: &[u8] = include_bytes!("../../assets/NotoSansMono-Bold.ttf");

static FONT_REG: LazyLock<FontRef<'static>> =
    LazyLock::new(|| FontRef::try_from_slice(FONT_REG_DATA).expect("noto sans mono regular"));
static FONT_BOLD: LazyLock<FontRef<'static>> =
    LazyLock::new(|| FontRef::try_from_slice(FONT_BOLD_DATA).expect("noto sans mono bold"));

/// Linear scale multiplier applied to every pixel dimension (font, padding,
/// cell width, media width cap). Bumping this produces a natively-higher-
/// resolution PNG — sharper than upscaling after the fact because glyph
/// rasterization happens at the target density. 2 gives ~1400px-wide
/// output — retina-sharp and share-ready without being absurd.
const SCALE_I: u32 = 2;
const SCALE_F: f32 = 2.0;

/// Base font size in CSS-like "pt" units (before SCALE). 22pt is deliberate
/// editorial-feel body size — prominent and readable as a standalone image,
/// not tiny-terminal-text squeezed into a PNG.
const FONT_PX: f32 = 22.0 * SCALE_F;
/// Slightly smaller watermark so the "unrager" signature stays lowkey
/// relative to the tweet body.
const WATERMARK_PX: f32 = 15.0 * SCALE_F;
/// Extra pixels of leading added on top of the font's natural line height —
/// small amount of air between body lines for magazine-y rhythm.
const LINE_LEADING: u32 = 4 * SCALE_I;

const PADDING_X: u32 = 32 * SCALE_I;
const PAD_TOP: u32 = 24 * SCALE_I;
const PAD_BOTTOM: u32 = 22 * SCALE_I;
const WATERMARK_GAP: u32 = 12 * SCALE_I;
const ACCENT_BAR_W: u32 = 5 * SCALE_I;
const ACCENT_BAR_GAP: u32 = 18 * SCALE_I;
const MEDIA_GAP_ABOVE: u32 = 14 * SCALE_I;
const MEDIA_GAP_BELOW: u32 = 8 * SCALE_I;
const MEDIA_MAX_W_PX: u32 = 900 * SCALE_I;

/// Columns of text per line. Shorter lines feel editorial; a tweet body
/// at this width is closer to newspaper-column readability than
/// terminal-width sprawl. Shared with the compose glue so the wrap width
/// fed to `tweet_lines` stays in sync with the rasterization grid —
/// otherwise a pre-wrapped body line wider than the grid gets re-wrapped
/// by ratatui's `Paragraph` and loses its leading indent on continuation.
pub const CONTENT_COLS: u16 = 56;

pub struct Capture {
    pub image: RgbaImage,
    pub tweet_id: String,
}

pub struct RenderArgs<'a> {
    pub tweet_id: String,
    pub lines: Vec<Line<'static>>,
    pub media_images: Vec<RgbaImage>,
    pub shot_theme: &'a ShotTheme,
}

/// Minimal palette for rendering a screenshot. Decoupled from the TUI's full
/// `Theme` so screenshot look can be switched without touching the live
/// terminal palette. Six distinctive presets (each a real aesthetic, not a
/// color shuffle) + a "match the TUI" converter + a `from_colors(bg, accent)`
/// custom builder.
///
/// `bg_end` is an optional second background color; when `Some`, the canvas
/// paints a vertical linear gradient from `bg` (top) to `bg_end` (bottom).
/// Unlocks the synthwave / liquid-glass / sunset looks that a solid fill
/// can't reach.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ShotTheme {
    pub name: &'static str,
    pub bg: [u8; 3],
    pub bg_end: Option<[u8; 3]>,
    pub text: [u8; 3],
    pub text_muted: [u8; 3],
    pub accent: [u8; 3],
    pub is_dark: bool,
}

/// Frosted ice-blue glass — deeper vertical gradient for real
/// glassmorphism depth, cool palette, sky accent.
pub const PRESET_GLASS: ShotTheme = ShotTheme {
    name: "glass",
    bg: [0xeb, 0xf3, 0xfa],
    bg_end: Some([0xb8, 0xce, 0xe8]),
    text: [0x14, 0x22, 0x36],
    text_muted: [0x5c, 0x72, 0x8a],
    accent: [0x2e, 0x8b, 0xff],
    is_dark: false,
};

/// 80s neo-synthwave — near-black night top fading into magenta-horizon
/// bottom, hot pink body, electric cyan accent. VHS / arcade cabinet.
pub const PRESET_SYNTHWAVE: ShotTheme = ShotTheme {
    name: "synthwave",
    bg: [0x0a, 0x04, 0x1c],
    bg_end: Some([0x5a, 0x1a, 0x66]),
    text: [0xff, 0x84, 0xd6],
    text_muted: [0xa0, 0x7a, 0xc8],
    accent: [0x05, 0xd9, 0xe8],
    is_dark: true,
};

/// Hand-cut kraft paper — warm tan gradient, chocolate text, collage-red
/// accent. Zine / scrapbook feel.
pub const PRESET_CUTOUT: ShotTheme = ShotTheme {
    name: "cutout",
    bg: [0xf3, 0xe4, 0xca],
    bg_end: Some([0xe6, 0xd0, 0xaa]),
    text: [0x2b, 0x1d, 0x11],
    text_muted: [0x8c, 0x6a, 0x3f],
    accent: [0xd8, 0x41, 0x4d],
    is_dark: false,
};

/// Forest-floor moss — deep greens with bone text and sage accent.
/// Botanical / field-guide feel.
pub const PRESET_MOSS: ShotTheme = ShotTheme {
    name: "moss",
    bg: [0x1e, 0x2a, 0x20],
    bg_end: Some([0x2c, 0x3a, 0x2e]),
    text: [0xe8, 0xea, 0xe0],
    text_muted: [0x8b, 0xa0, 0x8e],
    accent: [0xa3, 0xc2, 0x93],
    is_dark: true,
};

/// Engineering blueprint — saturated cobalt flat fill, chalk-white
/// drafting text, electric cyan rule-marking accent. Drawing-table feel
/// without the noisy gradient that weakens the technical vibe.
pub const PRESET_BLUEPRINT: ShotTheme = ShotTheme {
    name: "blueprint",
    bg: [0x07, 0x2b, 0x5c],
    bg_end: None,
    text: [0xf0, 0xf6, 0xff],
    text_muted: [0x7a, 0xa4, 0xd0],
    accent: [0x3f, 0xd1, 0xff],
    is_dark: true,
};

/// Arcade CRT — pure black with neon magenta accent and phosphor-green
/// body. Maximum contrast, retro-neon energy.
pub const PRESET_ARCADE: ShotTheme = ShotTheme {
    name: "arcade",
    bg: [0x0a, 0x0a, 0x0a],
    bg_end: None,
    text: [0x39, 0xff, 0x14],
    text_muted: [0x3d, 0x8e, 0x3a],
    accent: [0xff, 0x00, 0xaa],
    is_dark: true,
};

pub const PRESETS: [ShotTheme; 6] = [
    PRESET_GLASS,
    PRESET_SYNTHWAVE,
    PRESET_CUTOUT,
    PRESET_MOSS,
    PRESET_BLUEPRINT,
    PRESET_ARCADE,
];

impl ShotTheme {
    /// Snapshot of the TUI theme's palette so screenshots can "match" the
    /// current TUI look. Any named/indexed colors fall back to sensible RGB.
    pub fn from_tui(t: &Theme) -> Self {
        Self {
            name: "match",
            bg: tui_bg(t),
            bg_end: None,
            text: rgb_from_tui(t.text, [0x20, 0x20, 0x20]),
            text_muted: rgb_from_tui(t.text_muted, [0x80, 0x80, 0x80]),
            accent: rgb_from_tui(t.accent, [0x1d, 0x9b, 0xf0]),
            is_dark: t.is_dark,
        }
    }

    /// Build a theme from two user-picked colors. Text color is auto-picked
    /// based on bg luminance so it stays legible on either side.
    pub fn from_colors(bg: [u8; 3], accent: [u8; 3]) -> Self {
        let is_dark = luminance(bg) < 0.5;
        let text = if is_dark {
            [0xee, 0xee, 0xee]
        } else {
            [0x22, 0x22, 0x22]
        };
        let text_muted = mix(text, bg, 0.55);
        Self {
            name: "custom",
            bg,
            bg_end: None,
            text,
            text_muted,
            accent,
            is_dark,
        }
    }

    /// Synthesize a full TUI `Theme` from this palette — used to swap the
    /// active theme briefly while building the tweet's styled lines so that
    /// body text and accents come out in the screenshot's palette, not the
    /// live TUI's. Non-palette semantic colors (like / retweet / error) are
    /// borrowed from x-dark / x-light as a reasonable base.
    pub fn synthesize_tui(&self) -> Theme {
        let mut base = if self.is_dark {
            Theme::x_dark()
        } else {
            Theme::x_light()
        };
        let text = Color::Rgb(self.text[0], self.text[1], self.text[2]);
        let muted = Color::Rgb(self.text_muted[0], self.text_muted[1], self.text_muted[2]);
        let accent = Color::Rgb(self.accent[0], self.accent[1], self.accent[2]);
        base.text = text;
        base.text_muted = muted;
        base.text_dim = mix_color(text, muted, 0.5);
        base.text_faint = mix_color(text, muted, 0.3);
        base.accent = accent;
        base.verified = accent;
        base.url = accent;
        base.mention = accent;
        base.hashtag = accent;
        base.border_active = accent;
        base.sel_marker_active = accent;
        base.card_title = text;
        base.card_body = muted;
        base.card_meta = muted;
        base.card_border = mix_color(text, accent_as_color(self), 0.35);
        base.heading = text;
        base
    }
}

fn accent_as_color(s: &ShotTheme) -> Color {
    Color::Rgb(s.accent[0], s.accent[1], s.accent[2])
}

fn mix_color(a: Color, b: Color, t: f32) -> Color {
    let (ar, ag, ab_) = rgb_triple(a);
    let (br, bg, bb) = rgb_triple(b);
    let r = (ar as f32 * (1.0 - t) + br as f32 * t).round() as u8;
    let g = (ag as f32 * (1.0 - t) + bg as f32 * t).round() as u8;
    let b2 = (ab_ as f32 * (1.0 - t) + bb as f32 * t).round() as u8;
    Color::Rgb(r, g, b2)
}

fn rgb_triple(c: Color) -> (u8, u8, u8) {
    match c {
        Color::Rgb(r, g, b) => (r, g, b),
        _ => (0x80, 0x80, 0x80),
    }
}

fn rgb_from_tui(c: Color, fallback: [u8; 3]) -> [u8; 3] {
    match c {
        Color::Rgb(r, g, b) => [r, g, b],
        _ => fallback,
    }
}

fn tui_bg(t: &Theme) -> [u8; 3] {
    if t.is_dark {
        [0x1a, 0x1a, 0x24]
    } else {
        [0xfd, 0xf6, 0xe3]
    }
}

fn luminance(rgb: [u8; 3]) -> f32 {
    let [r, g, b] = rgb;
    (0.299 * r as f32 + 0.587 * g as f32 + 0.114 * b as f32) / 255.0
}

fn mix(a: [u8; 3], b: [u8; 3], t: f32) -> [u8; 3] {
    [
        (a[0] as f32 * (1.0 - t) + b[0] as f32 * t).round() as u8,
        (a[1] as f32 * (1.0 - t) + b[1] as f32 * t).round() as u8,
        (a[2] as f32 * (1.0 - t) + b[2] as f32 * t).round() as u8,
    ]
}

/// Parse a tune input like `#fdf6e3 #1d9bf0` into `(bg, accent)` tuples.
/// Accepts any whitespace between tokens. Returns `Err` with a user-facing
/// message on malformed input.
pub fn parse_tune(input: &str) -> Result<([u8; 3], [u8; 3]), String> {
    let parts: Vec<&str> = input.split_whitespace().collect();
    if parts.len() != 2 {
        return Err("expected two hex colors, e.g. #fdf6e3 #1d9bf0".to_string());
    }
    let bg = parse_hex(parts[0]).ok_or_else(|| format!("bad bg color: {}", parts[0]))?;
    let accent = parse_hex(parts[1]).ok_or_else(|| format!("bad accent color: {}", parts[1]))?;
    Ok((bg, accent))
}

fn parse_hex(s: &str) -> Option<[u8; 3]> {
    let s = s.trim().trim_start_matches('#');
    if s.len() != 6 {
        return None;
    }
    let r = u8::from_str_radix(&s[0..2], 16).ok()?;
    let g = u8::from_str_radix(&s[2..4], 16).ok()?;
    let b = u8::from_str_radix(&s[4..6], 16).ok()?;
    Some([r, g, b])
}

struct Grid {
    cell_w: u32,
    line_h: u32,
    ascent: f32,
}

impl Grid {
    fn measure() -> Self {
        let scaled = FONT_REG.as_scaled(PxScale::from(FONT_PX));
        let cell_w = scaled.h_advance(scaled.glyph_id(' ')).ceil().max(1.0) as u32;
        let ascent = scaled.ascent();
        let descent = scaled.descent();
        let line_gap = scaled.line_gap();
        let line_h = (ascent - descent + line_gap).ceil().max(1.0) as u32 + LINE_LEADING;
        Self {
            cell_w,
            line_h,
            ascent,
        }
    }
}

pub fn render(args: RenderArgs<'_>) -> Capture {
    let grid = Grid::measure();
    let content_px = CONTENT_COLS as u32 * grid.cell_w;
    let shot = args.shot_theme;

    // Span-aware wrap *before* rasterizing so every continuation row keeps
    // its indent. Lets us drop `Paragraph::wrap` (which strips continuation
    // indent) and render lines one-to-one onto buffer rows.
    let wrapped = wrap_lines_preserve_indent(args.lines.clone(), CONTENT_COLS as usize);
    let rows = wrapped.len() as u16;
    let buf_rect = Rect::new(0, 0, CONTENT_COLS, rows.max(1));
    let mut buf = Buffer::empty(buf_rect);
    Paragraph::new(wrapped).render(buf_rect, &mut buf);
    let used_rows = last_nonblank_row(&buf).saturating_add(1);

    let text_h = used_rows as u32 * grid.line_h;

    let scaled_media = scale_media(&args.media_images, content_px);
    let media_h: u32 = if scaled_media.is_empty() {
        0
    } else {
        MEDIA_GAP_ABOVE
            + scaled_media
                .iter()
                .map(|m| m.height() + MEDIA_GAP_BELOW)
                .sum::<u32>()
    };

    let wm_h = FONT_REG
        .as_scaled(PxScale::from(WATERMARK_PX))
        .ascent()
        .ceil() as u32;
    let canvas_w = ACCENT_BAR_W + ACCENT_BAR_GAP + content_px + PADDING_X * 2;
    let canvas_h = PAD_TOP + text_h + media_h + WATERMARK_GAP + wm_h + PAD_BOTTOM;

    let bg = rgba_from(shot.bg);
    let mut canvas = RgbaImage::from_pixel(canvas_w, canvas_h, bg);
    if let Some(end) = shot.bg_end {
        paint_vertical_gradient(&mut canvas, shot.bg, end);
    }

    let accent = rgba_from(shot.accent);
    fill_rect(
        &mut canvas,
        0,
        PAD_TOP,
        ACCENT_BAR_W,
        text_h + media_h,
        accent,
    );

    let text_origin_x = ACCENT_BAR_W + ACCENT_BAR_GAP + PADDING_X;
    let text_origin_y = PAD_TOP;
    paint_buffer(
        &mut canvas,
        &buf,
        used_rows,
        (text_origin_x, text_origin_y),
        &grid,
        shot,
        bg,
    );

    let mut media_y = text_origin_y + text_h + if media_h > 0 { MEDIA_GAP_ABOVE } else { 0 };
    for m in &scaled_media {
        imageops::overlay(&mut canvas, m, text_origin_x as i64, media_y as i64);
        media_y += m.height() + MEDIA_GAP_BELOW;
    }

    draw_watermark(&mut canvas, shot);

    Capture {
        image: canvas,
        tweet_id: args.tweet_id,
    }
}

fn rgba_from(rgb: [u8; 3]) -> Rgba<u8> {
    Rgba([rgb[0], rgb[1], rgb[2], 255])
}

/// Fill the whole canvas with a vertical linear gradient from `top` at y=0
/// to `bottom` at y=max. Uses simple per-pixel lerp — fine at our output
/// sizes and avoids pulling in a blending crate.
fn paint_vertical_gradient(canvas: &mut RgbaImage, top: [u8; 3], bottom: [u8; 3]) {
    let h = canvas.height();
    if h == 0 {
        return;
    }
    for y in 0..h {
        let t = y as f32 / (h - 1).max(1) as f32;
        let r = (top[0] as f32 * (1.0 - t) + bottom[0] as f32 * t).round() as u8;
        let g = (top[1] as f32 * (1.0 - t) + bottom[1] as f32 * t).round() as u8;
        let b = (top[2] as f32 * (1.0 - t) + bottom[2] as f32 * t).round() as u8;
        let row = Rgba([r, g, b, 255]);
        for x in 0..canvas.width() {
            canvas.put_pixel(x, y, row);
        }
    }
}

impl Capture {
    pub fn to_png(&self) -> Result<Vec<u8>, String> {
        use image::ImageEncoder;
        let mut out = Vec::with_capacity(self.image.len());
        image::codecs::png::PngEncoder::new(&mut out)
            .write_image(
                self.image.as_raw(),
                self.image.width(),
                self.image.height(),
                image::ExtendedColorType::Rgba8,
            )
            .map_err(|e| format!("png encode: {e}"))?;
        Ok(out)
    }

    pub fn save(&self, dir: &Path) -> Result<PathBuf, String> {
        std::fs::create_dir_all(dir).map_err(|e| format!("create {}: {e}", dir.display()))?;
        let ts = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let path = dir.join(format!("{}-{}.png", self.tweet_id, ts));
        let bytes = self.to_png()?;
        std::fs::write(&path, &bytes).map_err(|e| format!("write {}: {e}", path.display()))?;
        Ok(path)
    }

    pub fn copy_to_clipboard(&self) -> Result<(), String> {
        let mut cb = arboard::Clipboard::new().map_err(|e| format!("clipboard open: {e}"))?;
        let data = arboard::ImageData {
            width: self.image.width() as usize,
            height: self.image.height() as usize,
            bytes: std::borrow::Cow::Borrowed(self.image.as_raw()),
        };
        cb.set_image(data)
            .map_err(|e| format!("clipboard set: {e}"))
    }
}

/// Wrap any lines that exceed `max_w` cells, breaking at word boundaries
/// and prepending a 2-space indent to every continuation row so the visual
/// structure of the original (indented body, header metrics) survives the
/// wrap. Lines already ≤ `max_w` pass through untouched. Span styles are
/// preserved per-character so colors don't bleed across breaks.
fn wrap_lines_preserve_indent(lines: Vec<Line<'static>>, max_w: usize) -> Vec<Line<'static>> {
    let mut out = Vec::with_capacity(lines.len());
    for line in lines {
        out.extend(wrap_one_line(line, max_w));
    }
    out
}

fn wrap_one_line(line: Line<'static>, max_w: usize) -> Vec<Line<'static>> {
    use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};

    let total_w: usize = line
        .spans
        .iter()
        .map(|s| UnicodeWidthStr::width(s.content.as_ref()))
        .sum();
    if total_w <= max_w {
        return vec![line];
    }

    let chars: Vec<(char, Style)> = line
        .spans
        .iter()
        .flat_map(|s| {
            let style = s.style;
            s.content.chars().map(move |c| (c, style))
        })
        .collect();

    let indent = "  ";
    let indent_w = 2;
    let mut out: Vec<Line<'static>> = Vec::new();
    let mut i = 0;
    let mut first = true;

    while i < chars.len() {
        let avail = if first {
            max_w
        } else {
            max_w.saturating_sub(indent_w)
        };

        let mut end = i;
        let mut width = 0usize;
        let mut last_space: Option<usize> = None;
        while end < chars.len() {
            let cw = UnicodeWidthChar::width(chars[end].0).unwrap_or(0);
            if width + cw > avail {
                break;
            }
            if chars[end].0 == ' ' {
                last_space = Some(end);
            }
            width += cw;
            end += 1;
        }

        let break_at = if end == chars.len() {
            end
        } else if let Some(ls) = last_space.filter(|ls| *ls > i) {
            ls
        } else {
            end
        };

        let mut spans: Vec<Span<'static>> = Vec::new();
        if !first {
            spans.push(Span::raw(indent));
        }
        let mut j = i;
        while j < break_at {
            let style = chars[j].1;
            let run_start = j;
            while j < break_at && chars[j].1 == style {
                j += 1;
            }
            let run: String = chars[run_start..j].iter().map(|(c, _)| *c).collect();
            spans.push(Span::styled(run, style));
        }
        out.push(Line::from(spans));

        i = break_at;
        while i < chars.len() && chars[i].0 == ' ' {
            i += 1;
        }
        first = false;
    }
    out
}

fn last_nonblank_row(buf: &Buffer) -> u16 {
    for y in (0..buf.area.height).rev() {
        for x in 0..buf.area.width {
            let cell = &buf[(x, y)];
            let sym = cell.symbol();
            if !sym.trim().is_empty() || cell.bg != Color::Reset {
                return y;
            }
        }
    }
    0
}

fn paint_buffer(
    canvas: &mut RgbaImage,
    buf: &Buffer,
    rows: u16,
    origin: (u32, u32),
    grid: &Grid,
    shot: &ShotTheme,
    canvas_bg: Rgba<u8>,
) {
    let (origin_x, origin_y) = origin;
    let default_fg = rgba_from(shot.text);
    for y in 0..rows {
        for x in 0..buf.area.width {
            let cell = &buf[(x, y)];
            let px_x = origin_x + x as u32 * grid.cell_w;
            let px_y = origin_y + y as u32 * grid.line_h;

            let bg = color_to_rgba_opt(cell.bg).unwrap_or(canvas_bg);
            if bg != canvas_bg {
                fill_rect(canvas, px_x, px_y, grid.cell_w, grid.line_h, bg);
            }

            let sym = cell.symbol();
            if sym.is_empty() || sym == " " {
                continue;
            }
            let fg = color_to_rgba_opt(cell.fg).unwrap_or(default_fg);
            let bold = cell.modifier.contains(Modifier::BOLD);
            let font: &FontRef<'static> = if bold { &FONT_BOLD } else { &FONT_REG };
            draw_str(canvas, font, sym, (px_x, px_y), grid, fg);
        }
    }
}

fn draw_str(
    canvas: &mut RgbaImage,
    font: &FontRef<'static>,
    text: &str,
    pos: (u32, u32),
    grid: &Grid,
    color: Rgba<u8>,
) {
    let (x, y) = pos;
    let scaled = font.as_scaled(PxScale::from(FONT_PX));
    let mut pen_x = x as f32;
    let baseline = y as f32 + grid.ascent;
    let cell_advance = grid.cell_w as f32;
    for ch in text.chars() {
        let id = scaled.glyph_id(ch);
        let glyph: Glyph =
            id.with_scale_and_position(PxScale::from(FONT_PX), point(pen_x, baseline));
        rasterize_glyph(canvas, font, glyph, color);
        let advance = scaled.h_advance(id);
        // Monospace: clamp every glyph to exactly one cell of width to keep
        // the grid straight even when a symbol's own advance is fractionally
        // off. Very-wide characters (U+FF..) get two cells because the
        // ratatui buffer already accounted for that upstream.
        let cells = (advance / cell_advance).round().max(1.0);
        pen_x += cells * cell_advance;
    }
}

/// Draw a free-floating text run at an explicit pixel size. No grid snap —
/// used for the watermark, which sits outside the character grid.
fn draw_str_at(
    canvas: &mut RgbaImage,
    font: &FontRef<'static>,
    text: &str,
    pos: (u32, u32),
    size: f32,
    color: Rgba<u8>,
) {
    let (x, y) = pos;
    let scaled = font.as_scaled(PxScale::from(size));
    let mut pen_x = x as f32;
    let baseline = y as f32 + scaled.ascent();
    for ch in text.chars() {
        let id = scaled.glyph_id(ch);
        let glyph: Glyph = id.with_scale_and_position(PxScale::from(size), point(pen_x, baseline));
        rasterize_glyph(canvas, font, glyph, color);
        pen_x += scaled.h_advance(id);
    }
}

fn rasterize_glyph(canvas: &mut RgbaImage, font: &FontRef<'static>, glyph: Glyph, color: Rgba<u8>) {
    let Some(outlined) = font.outline_glyph(glyph) else {
        return;
    };
    let bounds = outlined.px_bounds();
    outlined.draw(|gx, gy, cov| {
        if cov <= 0.0 {
            return;
        }
        let px = (bounds.min.x as i32) + gx as i32;
        let py = (bounds.min.y as i32) + gy as i32;
        if px < 0 || py < 0 {
            return;
        }
        let (px, py) = (px as u32, py as u32);
        if px >= canvas.width() || py >= canvas.height() {
            return;
        }
        let existing = *canvas.get_pixel(px, py);
        let blended = blend(existing, color, cov.clamp(0.0, 1.0));
        canvas.put_pixel(px, py, blended);
    });
}

fn blend(dst: Rgba<u8>, src: Rgba<u8>, alpha: f32) -> Rgba<u8> {
    let a = alpha * (src[3] as f32 / 255.0);
    let inv = 1.0 - a;
    Rgba([
        (dst[0] as f32 * inv + src[0] as f32 * a).round() as u8,
        (dst[1] as f32 * inv + src[1] as f32 * a).round() as u8,
        (dst[2] as f32 * inv + src[2] as f32 * a).round() as u8,
        255,
    ])
}

fn fill_rect(canvas: &mut RgbaImage, x: u32, y: u32, w: u32, h: u32, color: Rgba<u8>) {
    let x_end = (x + w).min(canvas.width());
    let y_end = (y + h).min(canvas.height());
    for py in y..y_end {
        for px in x..x_end {
            canvas.put_pixel(px, py, color);
        }
    }
}

fn scale_media(images: &[RgbaImage], target_w: u32) -> Vec<RgbaImage> {
    let target = target_w.min(MEDIA_MAX_W_PX);
    images
        .iter()
        .map(|img| {
            if img.width() == 0 || img.height() == 0 {
                return img.clone();
            }
            if img.width() <= target {
                return img.clone();
            }
            let new_h = (img.height() as u64 * target as u64 / img.width() as u64) as u32;
            imageops::resize(img, target, new_h.max(1), imageops::FilterType::Lanczos3)
        })
        .collect()
}

fn draw_watermark(canvas: &mut RgbaImage, shot: &ShotTheme) {
    let text = "unrager";
    let scaled = FONT_REG.as_scaled(PxScale::from(WATERMARK_PX));
    let approx_w: f32 = text
        .chars()
        .map(|c| scaled.h_advance(scaled.glyph_id(c)))
        .sum();
    let w = approx_w.ceil() as u32;
    let fg = {
        let mut c = rgba_from(shot.text_muted);
        c[3] = 130;
        c
    };
    let wm_h = scaled.ascent().ceil() as u32;
    let x = canvas.width().saturating_sub(PADDING_X).saturating_sub(w);
    let y = canvas
        .height()
        .saturating_sub(PAD_BOTTOM)
        .saturating_sub(wm_h);
    draw_str_at(canvas, &FONT_REG, text, (x, y), WATERMARK_PX, fg);
}

fn color_to_rgba_opt(c: Color) -> Option<Rgba<u8>> {
    match c {
        Color::Reset => None,
        Color::Rgb(r, g, b) => Some(Rgba([r, g, b, 255])),
        Color::Indexed(n) => Some(xterm_palette(n)),
        Color::Black => Some(Rgba([0, 0, 0, 255])),
        Color::Red => Some(Rgba([0xcd, 0x31, 0x31, 255])),
        Color::Green => Some(Rgba([0x00, 0xba, 0x7c, 255])),
        Color::Yellow => Some(Rgba([0xe5, 0xe5, 0x10, 255])),
        Color::Blue => Some(Rgba([0x1d, 0x9b, 0xf0, 255])),
        Color::Magenta => Some(Rgba([0xcd, 0x31, 0xcd, 255])),
        Color::Cyan => Some(Rgba([0x00, 0xcd, 0xcd, 255])),
        Color::Gray => Some(Rgba([0xa8, 0xa8, 0xa8, 255])),
        Color::DarkGray => Some(Rgba([0x6a, 0x6a, 0x6a, 255])),
        Color::LightRed => Some(Rgba([0xeb, 0x6f, 0x92, 255])),
        Color::LightGreen => Some(Rgba([0x52, 0xe5, 0x8c, 255])),
        Color::LightYellow => Some(Rgba([0xf6, 0xc1, 0x77, 255])),
        Color::LightBlue => Some(Rgba([0x80, 0xbd, 0xf0, 255])),
        Color::LightMagenta => Some(Rgba([0xc4, 0xa7, 0xe7, 255])),
        Color::LightCyan => Some(Rgba([0x9c, 0xcf, 0xd8, 255])),
        Color::White => Some(Rgba([0xff, 0xff, 0xff, 255])),
    }
}

fn xterm_palette(n: u8) -> Rgba<u8> {
    // Minimal mapping for our handle_palette (indices 19..226 used in themes).
    // Falls back to a deterministic HSV ramp for anything else so indexed
    // colors still give reasonable output instead of black.
    let (r, g, b) = match n {
        0..=7 | 16 => (0x20, 0x20, 0x20),
        8..=15 => (0xa8, 0xa8, 0xa8),
        n @ 16..=231 => {
            let v = n - 16;
            let r = v / 36;
            let g = (v % 36) / 6;
            let b = v % 6;
            let step = |c: u8| if c == 0 { 0 } else { 55 + c * 40 };
            (step(r), step(g), step(b))
        }
        n @ 232..=255 => {
            let gray = 8 + (n - 232) * 10;
            (gray, gray, gray)
        }
    };
    Rgba([r, g, b, 255])
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::style::Style;
    use ratatui::text::Span;

    fn plain_lines() -> Vec<Line<'static>> {
        vec![
            Line::from(vec![Span::styled(
                "@user",
                Style::default().fg(Color::Rgb(0x1d, 0x9b, 0xf0)),
            )]),
            Line::from("  hello world"),
        ]
    }

    #[test]
    fn render_smoke() {
        let cap = render(RenderArgs {
            tweet_id: "123".into(),
            lines: plain_lines(),
            media_images: Vec::new(),
            shot_theme: &PRESET_GLASS,
        });
        assert!(cap.image.width() > 100);
        assert!(cap.image.height() > 40);
        assert_eq!(cap.tweet_id, "123");
    }

    #[test]
    fn render_png_roundtrip() {
        let cap = render(RenderArgs {
            tweet_id: "t".into(),
            lines: plain_lines(),
            media_images: Vec::new(),
            shot_theme: &PRESET_SYNTHWAVE,
        });
        let png = cap.to_png().unwrap();
        assert!(png.len() > 100);
        assert_eq!(&png[0..8], b"\x89PNG\r\n\x1a\n");
    }

    #[test]
    fn save_writes_file() {
        let cap = render(RenderArgs {
            tweet_id: "42".into(),
            lines: plain_lines(),
            media_images: Vec::new(),
            shot_theme: &PRESET_GLASS,
        });
        let tmp = tempfile::tempdir().unwrap();
        let path = cap.save(tmp.path()).unwrap();
        assert!(path.exists());
        assert!(
            path.file_name()
                .unwrap()
                .to_str()
                .unwrap()
                .starts_with("42-")
        );
        assert!(path.extension().unwrap() == "png");
    }

    #[test]
    fn scale_media_shrinks_wide_images() {
        let img = RgbaImage::from_pixel(2000, 1000, Rgba([255, 0, 0, 255]));
        let scaled = scale_media(&[img], 400);
        assert_eq!(scaled.len(), 1);
        assert_eq!(scaled[0].width(), 400);
        assert_eq!(scaled[0].height(), 200);
    }

    #[test]
    fn parse_tune_accepts_two_hex_colors() {
        let (bg, accent) = parse_tune("#fdf6e3 #1d9bf0").unwrap();
        assert_eq!(bg, [0xfd, 0xf6, 0xe3]);
        assert_eq!(accent, [0x1d, 0x9b, 0xf0]);
    }

    #[test]
    fn parse_tune_no_hash_ok() {
        let (bg, accent) = parse_tune("fdf6e3 1d9bf0").unwrap();
        assert_eq!(bg, [0xfd, 0xf6, 0xe3]);
        assert_eq!(accent, [0x1d, 0x9b, 0xf0]);
    }

    #[test]
    fn parse_tune_rejects_short() {
        assert!(parse_tune("#fff").is_err());
        assert!(parse_tune("only-one-color").is_err());
    }

    #[test]
    fn parse_tune_rejects_garbage_hex() {
        assert!(parse_tune("#zzzzzz #000000").is_err());
    }

    #[test]
    fn custom_picks_dark_text_on_light_bg() {
        let shot = ShotTheme::from_colors([0xff, 0xff, 0xff], [0x00, 0x00, 0xff]);
        assert!(!shot.is_dark);
        assert!(shot.text[0] < 0x80);
    }

    #[test]
    fn custom_picks_light_text_on_dark_bg() {
        let shot = ShotTheme::from_colors([0x11, 0x11, 0x11], [0xff, 0x00, 0x00]);
        assert!(shot.is_dark);
        assert!(shot.text[0] > 0x80);
    }

    #[test]
    fn synthesize_tui_overrides_accent() {
        let shot = PRESET_SYNTHWAVE;
        let theme = shot.synthesize_tui();
        assert_eq!(theme.accent, Color::Rgb(0x05, 0xd9, 0xe8));
        assert_eq!(theme.verified, Color::Rgb(0x05, 0xd9, 0xe8));
    }

    #[test]
    fn from_tui_snapshots_core_colors() {
        let base = crate::tui::theme::Theme::x_dark();
        let shot = ShotTheme::from_tui(&base);
        assert!(shot.is_dark);
        assert_eq!(shot.accent, [0x1d, 0x9b, 0xf0]);
    }

    #[test]
    fn scale_media_leaves_small_images() {
        let img = RgbaImage::from_pixel(100, 50, Rgba([0, 255, 0, 255]));
        let scaled = scale_media(&[img], 400);
        assert_eq!(scaled[0].width(), 100);
        assert_eq!(scaled[0].height(), 50);
    }

    /// Validation harness: render a representative tweet under every preset
    /// and the custom-from-colors builder, dumping PNGs to $UNRAGER_SHOT_OUT
    /// when set. Used during theme design to inspect each render visually.
    /// No assertions beyond dimensions; the assertion is the image file.
    #[test]
    fn preview_all_themes() {
        let Some(out_dir) = std::env::var_os("UNRAGER_SHOT_OUT") else {
            return;
        };
        let out_dir = std::path::PathBuf::from(out_dir);
        std::fs::create_dir_all(&out_dir).unwrap();

        let accent_blue = Style::default().fg(Color::Rgb(0x1d, 0x9b, 0xf0));
        let muted = Style::default().fg(Color::Rgb(0x80, 0x80, 0x80));
        let text = Style::default().fg(Color::Rgb(0x20, 0x20, 0x20));
        let bold = Style::default().add_modifier(ratatui::style::Modifier::BOLD);

        let sample_lines = vec![
            Line::from(vec![
                Span::styled("● ", Style::default().fg(Color::Rgb(0x00, 0xba, 0x7c))),
                Span::styled(
                    "@emanueledpt",
                    accent_blue.add_modifier(ratatui::style::Modifier::BOLD),
                ),
                Span::styled(" ✓", accent_blue),
                Span::styled("  ·  4h  ", muted),
                Span::styled("↳ 11   ♡ 48   ◎ 1.2K", muted),
            ]),
            Line::from(vec![
                Span::styled("  ", Style::default()),
                Span::styled(
                    "DP Code reached its first 200 stars on GitHub!",
                    text.patch(bold),
                ),
            ]),
            Line::from(vec![
                Span::styled("  ", Style::default()),
                Span::styled(
                    "And also just broke 780 installs across all",
                    text.patch(bold),
                ),
            ]),
            Line::from(vec![
                Span::styled("  ", Style::default()),
                Span::styled("platforms!", text.patch(bold)),
            ]),
            Line::from(vec![
                Span::styled("  ", Style::default()),
                Span::styled("Thank you guys for the support!", text.patch(bold)),
            ]),
        ];

        let custom_mint = ShotTheme::from_colors([0xe7, 0xf5, 0xee], [0xe8, 0x5f, 0x5c]);

        let variants: Vec<(&str, ShotTheme)> = vec![
            ("01-glass", PRESET_GLASS),
            ("02-synthwave", PRESET_SYNTHWAVE),
            ("03-cutout", PRESET_CUTOUT),
            ("04-moss", PRESET_MOSS),
            ("05-blueprint", PRESET_BLUEPRINT),
            ("06-arcade", PRESET_ARCADE),
            ("07-custom-mint", custom_mint),
        ];

        for (name, shot) in variants {
            let synthesized = shot.synthesize_tui();
            let mut recolored = sample_lines.clone();
            for line in &mut recolored {
                for span in &mut line.spans {
                    if span.style.fg == Some(Color::Rgb(0x20, 0x20, 0x20)) {
                        span.style.fg = Some(Color::Rgb(shot.text[0], shot.text[1], shot.text[2]));
                    } else if span.style.fg == Some(Color::Rgb(0x80, 0x80, 0x80)) {
                        span.style.fg = Some(Color::Rgb(
                            shot.text_muted[0],
                            shot.text_muted[1],
                            shot.text_muted[2],
                        ));
                    } else if span.style.fg == Some(Color::Rgb(0x1d, 0x9b, 0xf0)) {
                        span.style.fg =
                            Some(Color::Rgb(shot.accent[0], shot.accent[1], shot.accent[2]));
                    }
                }
            }
            let cap = render(RenderArgs {
                tweet_id: name.to_string(),
                lines: recolored,
                media_images: Vec::new(),
                shot_theme: &shot,
            });
            let path = out_dir.join(format!("{name}.png"));
            let bytes = cap.to_png().unwrap();
            std::fs::write(&path, &bytes).unwrap();
            eprintln!("wrote {}", path.display());
            let _ = synthesized;
        }
    }
}
