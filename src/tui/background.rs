use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use std::io::Write;

/// Reserved kitty image id for the For You wallpaper. Picked far above the
/// counter used by `MediaRegistry::next_id` so it will never collide with
/// tweet media placements.
const BG_IMAGE_ID: u32 = 0x0BAD_F00D_u32;
const BG_PLACEMENT_ID: u32 = 1;

/// Kitty z-index for "behind cells with a default background". Any value
/// below -1_073_741_824 lets the image show through every transparent cell
/// without being occluded by ratatui's blank-cell writes.
const BG_Z_INDEX: i32 = i32::MIN;

/// Pre-darkened, downscaled (768x469) wallpaper. Embedding as PNG keeps the
/// binary under 300 KB and lets kitty decode it server-side via `f=100`, so
/// we never need to materialize the RGBA buffer in-process.
const BG_PNG: &[u8] = include_bytes!("../../assets/for-you-bg.png");

pub struct Background {
    transmitted: bool,
    enabled: bool,
    placed_dims: Option<(u16, u16)>,
}

impl Default for Background {
    fn default() -> Self {
        Self::new()
    }
}

impl Background {
    pub fn new() -> Self {
        Self {
            transmitted: false,
            enabled: false,
            placed_dims: None,
        }
    }

    /// Called once at app startup when kitty graphics support is confirmed.
    /// Transmits the PNG payload eagerly so it never competes with ratatui's
    /// diff writes during the render loop — the 300 KB of base64 stays out of
    /// the tick-by-tick critical path.
    pub fn enable_and_prime(&mut self) {
        if self.enabled {
            return;
        }
        self.enabled = true;
        if !self.transmitted {
            transmit_png();
            self.transmitted = true;
        }
    }

    pub fn enabled(&self) -> bool {
        self.enabled
    }

    pub fn is_placed(&self) -> bool {
        self.placed_dims.is_some()
    }

    /// Emits placement covering the full terminal. Idempotent while the
    /// dimensions are unchanged; re-emits when the terminal resizes.
    /// Returns `true` if the placement was newly created or re-sized, so the
    /// caller can force a full redraw to settle cell alignment.
    pub fn show(&mut self, cols: u16, rows: u16) -> bool {
        if !self.enabled || cols == 0 || rows == 0 {
            return false;
        }
        if self.placed_dims == Some((cols, rows)) {
            return false;
        }
        place(cols, rows);
        self.placed_dims = Some((cols, rows));
        true
    }

    /// Deletes the active placement (keeps the transmitted image cached for
    /// the next activation). Returns `true` if a placement was actually
    /// removed.
    pub fn hide(&mut self) -> bool {
        if !self.enabled || self.placed_dims.is_none() {
            return false;
        }
        unplace();
        self.placed_dims = None;
        true
    }

    /// Force-deletes any kitty image with our reserved id, regardless of
    /// whether this session ever enabled the wallpaper. Kitty caches
    /// transmitted images across program invocations, so a previous run that
    /// placed the wallpaper can leave it visible on start-up. Safe to call
    /// when no such image exists — kitty silently ignores the delete.
    pub fn clear_stale(&self) {
        unplace();
    }
}

fn transmit_png() {
    let encoded = STANDARD.encode(BG_PNG);
    let bytes = encoded.as_bytes();
    let chunk_size = 4096;
    let total = bytes.len().div_ceil(chunk_size).max(1);
    let mut payload = Vec::with_capacity(encoded.len() + total * 48);
    for (i, chunk) in bytes.chunks(chunk_size).enumerate() {
        let is_last = i + 1 == total;
        let m = if is_last { 0 } else { 1 };
        let chunk_str = std::str::from_utf8(chunk).unwrap_or("");
        if i == 0 {
            let _ = write!(
                payload,
                "\x1b_Ga=t,f=100,i={BG_IMAGE_ID},q=2,m={m};{chunk_str}\x1b\\"
            );
        } else {
            let _ = write!(payload, "\x1b_Gm={m},q=2;{chunk_str}\x1b\\");
        }
    }
    let mut out = std::io::stdout().lock();
    let _ = out.write_all(&payload);
    let _ = out.flush();
}

fn place(cols: u16, rows: u16) {
    let mut out = std::io::stdout().lock();
    let _ = write!(
        out,
        "\x1b7\x1b[H\x1b_Ga=p,i={BG_IMAGE_ID},p={BG_PLACEMENT_ID},c={cols},r={rows},z={BG_Z_INDEX},C=1,q=2\x1b\\\x1b8"
    );
    let _ = out.flush();
}

fn unplace() {
    let mut out = std::io::stdout().lock();
    let _ = write!(out, "\x1b_Ga=d,d=i,i={BG_IMAGE_ID},q=2\x1b\\");
    let _ = out.flush();
}
