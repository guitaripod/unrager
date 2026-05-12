//! Headless full-frame rasterizer. Turns a rendered ratatui `Buffer`
//! plus a side map of kitty image ids → decoded RGBA pixels into a
//! single PNG. Used by the `unrager snapshot` CLI to regenerate site
//! assets deterministically — every visible cell, status bar, overlay,
//! and avatar chip ends up baked into the output.
//!
//! The rasterizer reuses the screenshot module's bundled monospace
//! fonts and glyph helpers; it diverges in three ways:
//!   1. No tweet-block scaffolding (no accent bar, watermark, theme
//!      preset). The TUI's own theme drives every color.
//!   2. Cell pixel size is caller-supplied, not derived from a target
//!      font size — so the output dimensions follow `(cols × cell_w,
//!      rows × cell_h)`.
//!   3. Kitty image placements are detected by sweeping the buffer for
//!      placeholder cells (`\u{10EEEE}`), grouping contiguous runs by
//!      the id encoded in each cell's fg color, then compositing the
//!      caller-provided `RgbaImage` over each detected rect.

use ab_glyph::{Font, FontRef, PxScale, ScaleFont, point};
use image::{Rgba, RgbaImage, imageops};
use ratatui::buffer::{Buffer, Cell};
use ratatui::style::{Color, Modifier};
use std::collections::HashMap;

use crate::tui::media::CellSize;
use crate::tui::screenshot::{
    FONT_BOLD, FONT_REG, color_to_rgba_opt, fill_rect, pick_font, rasterize_glyph, rgba_from,
};
use crate::tui::theme::Theme;

const PLACEHOLDER_CHAR: char = '\u{10EEEE}';

pub struct RasterizeArgs<'a> {
    pub buf: &'a Buffer,
    pub theme: &'a Theme,
    pub cell: CellSize,
    /// Map from kitty image id → decoded RGBA pixels. Built by the
    /// snapshot CLI before rendering by fetching avatars/media off-band
    /// and registering them with `MediaRegistry::register_snapshot_kitty`.
    pub images: &'a HashMap<u32, RgbaImage>,
}

pub fn rasterize_full_frame(args: RasterizeArgs<'_>) -> RgbaImage {
    let cell_w = args.cell.w;
    let cell_h = args.cell.h;
    let w = args.buf.area.width as u32 * cell_w;
    let h = args.buf.area.height as u32 * cell_h;

    let bg = theme_bg(args.theme);
    let fg = theme_fg(args.theme);
    let mut canvas = RgbaImage::from_pixel(w, h, bg);

    let font_px = (cell_h as f32 * 0.82).max(8.0);
    let ascent_px = FONT_REG.as_scaled(PxScale::from(font_px)).ascent();
    let baseline_offset = (cell_h as f32 - ascent_px) * 0.5 + ascent_px;

    paint_cells(
        &mut canvas,
        args.buf,
        args.cell,
        bg,
        fg,
        font_px,
        baseline_offset,
    );

    let placements = detect_placements(args.buf);
    let mut composited = 0usize;
    let mut missing = 0usize;
    for placement in &placements {
        let Some(img) = args.images.get(&placement.id) else {
            missing += 1;
            continue;
        };
        let dx = placement.x as u32 * cell_w;
        let dy = placement.y as u32 * cell_h;
        let dw = placement.w as u32 * cell_w;
        let dh = placement.h as u32 * cell_h;
        composite_image(&mut canvas, img, dx, dy, dw, dh);
        composited += 1;
    }
    tracing::info!(
        placements = placements.len(),
        composited,
        missing,
        "snapshot rasterize complete"
    );

    canvas
}

fn theme_bg(t: &Theme) -> Rgba<u8> {
    // The live TUI inherits the terminal's bg, so `Theme` has no
    // explicit bg field. Pick a sensible canvas color that matches each
    // built-in theme's intent — the x-dark / x-light defaults mirror
    // the screenshot module's own fallbacks.
    if t.is_dark {
        rgba_from([0x16, 0x1a, 0x24])
    } else {
        rgba_from([0xfd, 0xf6, 0xe3])
    }
}

fn theme_fg(t: &Theme) -> Rgba<u8> {
    match t.text {
        Color::Rgb(r, g, b) => Rgba([r, g, b, 255]),
        _ => {
            if t.is_dark {
                rgba_from([0xe6, 0xe6, 0xea])
            } else {
                rgba_from([0x20, 0x20, 0x20])
            }
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn paint_cells(
    canvas: &mut RgbaImage,
    buf: &Buffer,
    cell: CellSize,
    canvas_bg: Rgba<u8>,
    default_fg: Rgba<u8>,
    font_px: f32,
    baseline_offset: f32,
) {
    for y in 0..buf.area.height {
        for x in 0..buf.area.width {
            let buf_cell = &buf[(x, y)];
            let px_x = x as u32 * cell.w;
            let px_y = y as u32 * cell.h;

            let bg = color_to_rgba_opt(buf_cell.bg).unwrap_or(canvas_bg);
            if bg != canvas_bg {
                fill_rect(canvas, px_x, px_y, cell.w, cell.h, bg);
            }

            let sym = buf_cell.symbol();
            if sym.is_empty() {
                continue;
            }
            // Placeholder cells get overlaid with the actual image
            // later. Skip glyph rendering so the diacritic noise
            // doesn't bleed through the composite.
            if sym.starts_with(PLACEHOLDER_CHAR) {
                continue;
            }
            if sym == " " {
                continue;
            }

            let fg = color_to_rgba_opt(buf_cell.fg).unwrap_or(default_fg);
            let bold = buf_cell.modifier.contains(Modifier::BOLD);
            let font: &FontRef<'static> = if bold { &FONT_BOLD } else { &FONT_REG };
            draw_cell_text(
                canvas,
                font,
                sym,
                px_x,
                px_y,
                cell,
                font_px,
                baseline_offset,
                fg,
            );
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn draw_cell_text(
    canvas: &mut RgbaImage,
    primary: &'static FontRef<'static>,
    text: &str,
    origin_x: u32,
    origin_y: u32,
    cell: CellSize,
    font_px: f32,
    baseline_offset: f32,
    color: Rgba<u8>,
) {
    let mut pen_x = origin_x as f32;
    let baseline = origin_y as f32 + baseline_offset;
    let cell_advance = cell.w as f32;
    for ch in text.chars() {
        let chosen = pick_font(primary, ch);
        let scaled = chosen.as_scaled(PxScale::from(font_px));
        let id = scaled.glyph_id(ch);
        let glyph = id.with_scale_and_position(PxScale::from(font_px), point(pen_x, baseline));
        rasterize_glyph(canvas, chosen, glyph, color);
        let advance = scaled.h_advance(id);
        let cells = (advance / cell_advance).round().max(1.0);
        pen_x += cells * cell_advance;
    }
}

#[derive(Debug, Clone, Copy)]
struct Placement {
    id: u32,
    x: u16,
    y: u16,
    w: u16,
    h: u16,
}

/// Scan the buffer row-by-row for runs of placeholder cells, keyed by
/// the id encoded in each cell's fg color. A placement closes when its
/// id stops appearing, or when its horizontal extent changes (the
/// terminal can't render a non-rectangular placement, but we still want
/// to defensively close + reopen rather than smear the image). Returns
/// every detected rectangle, including multiple non-contiguous
/// rectangles with the same id (e.g. the focal-tweet avatar showing in
/// both the source pane and detail pane in split layout).
fn detect_placements(buf: &Buffer) -> Vec<Placement> {
    let mut closed: Vec<Placement> = Vec::new();
    let mut open: HashMap<u32, Placement> = HashMap::new();

    for y in 0..buf.area.height {
        let mut row_ranges: HashMap<u32, (u16, u16)> = HashMap::new();
        for x in 0..buf.area.width {
            let Some(id) = placeholder_id(&buf[(x, y)]) else {
                continue;
            };
            let entry = row_ranges.entry(id).or_insert((x, x));
            entry.0 = entry.0.min(x);
            entry.1 = entry.1.max(x);
        }

        let to_close: Vec<u32> = open
            .keys()
            .copied()
            .filter(|id| !row_ranges.contains_key(id))
            .collect();
        for id in to_close {
            if let Some(p) = open.remove(&id) {
                closed.push(p);
            }
        }

        for (id, (min_x, max_x)) in row_ranges {
            let w = max_x - min_x + 1;
            let extend = matches!(open.get(&id), Some(p) if p.x == min_x && p.w == w);
            if extend {
                if let Some(p) = open.get_mut(&id) {
                    p.h += 1;
                }
            } else {
                if let Some(p) = open.remove(&id) {
                    closed.push(p);
                }
                open.insert(
                    id,
                    Placement {
                        id,
                        x: min_x,
                        y,
                        w,
                        h: 1,
                    },
                );
            }
        }
    }

    for (_, p) in open {
        closed.push(p);
    }
    closed
}

fn placeholder_id(cell: &Cell) -> Option<u32> {
    if !cell.symbol().starts_with(PLACEHOLDER_CHAR) {
        return None;
    }
    match cell.fg {
        Color::Rgb(r, g, b) => Some(((r as u32) << 16) | ((g as u32) << 8) | (b as u32)),
        _ => None,
    }
}

fn composite_image(canvas: &mut RgbaImage, src: &RgbaImage, dx: u32, dy: u32, dw: u32, dh: u32) {
    if dw == 0 || dh == 0 {
        return;
    }
    let scaled = imageops::resize(src, dw, dh, imageops::FilterType::Lanczos3);
    imageops::overlay(canvas, &scaled, dx as i64, dy as i64);
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::layout::Rect;
    use ratatui::style::Style;

    fn id_color(id: u32) -> Color {
        Color::Rgb(
            ((id >> 16) & 0xff) as u8,
            ((id >> 8) & 0xff) as u8,
            (id & 0xff) as u8,
        )
    }

    fn make_buf(w: u16, h: u16) -> Buffer {
        Buffer::empty(Rect::new(0, 0, w, h))
    }

    fn place_placeholder(buf: &mut Buffer, x: u16, y: u16, id: u32) {
        let cell = &mut buf[(x, y)];
        cell.set_symbol(&format!("{}\u{0305}\u{030D}", PLACEHOLDER_CHAR));
        cell.set_style(Style::default().fg(id_color(id)));
    }

    #[test]
    fn detect_single_rect() {
        let mut buf = make_buf(10, 5);
        for y in 1..4 {
            for x in 2..6 {
                place_placeholder(&mut buf, x, y, 0x123456);
            }
        }
        let placements = detect_placements(&buf);
        assert_eq!(placements.len(), 1);
        assert_eq!(placements[0].id, 0x123456);
        assert_eq!(placements[0].x, 2);
        assert_eq!(placements[0].y, 1);
        assert_eq!(placements[0].w, 4);
        assert_eq!(placements[0].h, 3);
    }

    #[test]
    fn detect_two_non_contiguous_rects_same_id() {
        let mut buf = make_buf(20, 10);
        for y in 0..2 {
            for x in 0..3 {
                place_placeholder(&mut buf, x, y, 42);
            }
        }
        for y in 5..7 {
            for x in 10..13 {
                place_placeholder(&mut buf, x, y, 42);
            }
        }
        let mut placements = detect_placements(&buf);
        placements.sort_by_key(|p| (p.y, p.x));
        assert_eq!(placements.len(), 2);
        assert_eq!(placements[0].x, 0);
        assert_eq!(placements[0].y, 0);
        assert_eq!(placements[1].x, 10);
        assert_eq!(placements[1].y, 5);
    }

    #[test]
    fn rasterize_produces_sized_canvas() {
        let theme = Theme::x_dark();
        let buf = make_buf(8, 4);
        let images = HashMap::new();
        let cell = CellSize { w: 12, h: 24 };
        let img = rasterize_full_frame(RasterizeArgs {
            buf: &buf,
            theme: &theme,
            cell,
            images: &images,
        });
        assert_eq!(img.width(), 8 * 12);
        assert_eq!(img.height(), 4 * 24);
    }

    #[test]
    fn rasterize_composites_image_at_placement() {
        let theme = Theme::x_dark();
        let mut buf = make_buf(10, 5);
        for y in 0..2 {
            for x in 0..2 {
                place_placeholder(&mut buf, x, y, 7);
            }
        }
        let mut images = HashMap::new();
        let src = RgbaImage::from_pixel(20, 20, Rgba([255, 0, 0, 255]));
        images.insert(7, src);

        let cell = CellSize { w: 8, h: 16 };
        let img = rasterize_full_frame(RasterizeArgs {
            buf: &buf,
            theme: &theme,
            cell,
            images: &images,
        });
        // The 2x2 placeholder area should now be red, not the dark
        // background.
        let sample = img.get_pixel(4, 4);
        assert_eq!(sample[0], 255);
        assert_eq!(sample[1], 0);
        assert_eq!(sample[2], 0);
    }
}
