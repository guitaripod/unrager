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
            tracing::info!(bytes = BG_PNG.len(), "mordor wallpaper transmitted");
        }
    }

    pub fn enabled(&self) -> bool {
        self.enabled
    }

    pub fn is_placed(&self) -> bool {
        self.placed_dims.is_some()
    }

    /// Emits placement covering the full terminal. Idempotent while the
    /// dimensions are unchanged. When dimensions *do* change, the stale
    /// placement is explicitly removed before the new one is emitted —
    /// relying on kitty's "replace same (i,p)" semantics is unreliable
    /// across terminals (ghostty drops the visual on resize otherwise).
    /// Returns `true` if the placement was newly created or re-sized.
    pub fn show(&mut self, cols: u16, rows: u16) -> bool {
        if !self.enabled || cols == 0 || rows == 0 {
            return false;
        }
        if self.placed_dims == Some((cols, rows)) {
            return false;
        }
        if self.placed_dims.is_some() {
            remove_placement();
        }
        place(cols, rows);
        let was = self.placed_dims;
        self.placed_dims = Some((cols, rows));
        tracing::info!(cols, rows, prev = ?was, "mordor wallpaper placed");
        true
    }

    /// Fully deletes the image from the terminal's cache and resets
    /// session state so the next activation retransmits and re-places
    /// cleanly. The ~300 KB retransmit happens at most once per Mordor
    /// entry, which is negligible compared to the reliability win — some
    /// terminals (notably ghostty at time of writing) don't fully clear
    /// the on-screen pixels for `d=p` placement-only deletes.
    pub fn hide(&mut self) -> bool {
        if !self.enabled {
            return false;
        }
        delete_image();
        self.enabled = false;
        self.transmitted = false;
        self.placed_dims = None;
        tracing::info!("mordor wallpaper hidden");
        true
    }

    /// Force-deletes the image itself (and any placements) so a prior
    /// session's cached wallpaper can't bleed through. Called once at
    /// startup before we transmit our own copy. Safe when nothing exists —
    /// kitty silently ignores deletes for unknown image ids.
    pub fn clear_stale(&self) {
        delete_image();
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

/// Deletes only the on-screen placement identified by `(BG_IMAGE_ID,
/// BG_PLACEMENT_ID)`. The transmitted image stays in kitty's cache so a
/// subsequent `place()` is cheap.
fn remove_placement() {
    let mut out = std::io::stdout().lock();
    let _ = write!(
        out,
        "\x1b_Ga=d,d=p,i={BG_IMAGE_ID},p={BG_PLACEMENT_ID},q=2\x1b\\"
    );
    let _ = out.flush();
}

/// Deletes the image and frees its storage. Used only for startup cleanup
/// — during normal toggles `remove_placement()` is correct.
fn delete_image() {
    let mut out = std::io::stdout().lock();
    let _ = write!(out, "\x1b_Ga=d,d=I,i={BG_IMAGE_ID},q=2\x1b\\");
    let _ = out.flush();
}
