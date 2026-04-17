use crate::model::{Media, MediaKind, Tweet};
use crate::tui::event::{Event, EventTx};
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use std::collections::{HashMap, VecDeque};
use std::io::Write;
use std::sync::Arc;
use tokio::sync::Semaphore;

const MAX_MEDIA_ENTRIES: usize = 128;

const PLACEHOLDER: char = '\u{10EEEE}';

#[rustfmt::skip]
const DIACRITICS: [char; 297] = [
    '\u{0305}','\u{030D}','\u{030E}','\u{0310}','\u{0312}','\u{033D}','\u{033E}','\u{033F}',
    '\u{0346}','\u{034A}','\u{034B}','\u{034C}','\u{0350}','\u{0351}','\u{0352}','\u{0357}',
    '\u{035B}','\u{0363}','\u{0364}','\u{0365}','\u{0366}','\u{0367}','\u{0368}','\u{0369}',
    '\u{036A}','\u{036B}','\u{036C}','\u{036D}','\u{036E}','\u{036F}','\u{0483}','\u{0484}',
    '\u{0485}','\u{0486}','\u{0487}','\u{0592}','\u{0593}','\u{0594}','\u{0595}','\u{0597}',
    '\u{0598}','\u{0599}','\u{059C}','\u{059D}','\u{059E}','\u{059F}','\u{05A0}','\u{05A1}',
    '\u{05A8}','\u{05A9}','\u{05AB}','\u{05AC}','\u{05AF}','\u{05C4}','\u{0610}','\u{0611}',
    '\u{0612}','\u{0613}','\u{0614}','\u{0615}','\u{0616}','\u{0617}','\u{0657}','\u{0658}',
    '\u{0659}','\u{065A}','\u{065B}','\u{065D}','\u{065E}','\u{06D6}','\u{06D7}','\u{06D8}',
    '\u{06D9}','\u{06DA}','\u{06DB}','\u{06DC}','\u{06DF}','\u{06E0}','\u{06E1}','\u{06E2}',
    '\u{06E4}','\u{06E7}','\u{06E8}','\u{06EB}','\u{06EC}','\u{0730}','\u{0732}','\u{0733}',
    '\u{0735}','\u{0736}','\u{073A}','\u{073D}','\u{073F}','\u{0740}','\u{0741}','\u{0743}',
    '\u{0745}','\u{0747}','\u{0749}','\u{074A}','\u{07EB}','\u{07EC}','\u{07ED}','\u{07EE}',
    '\u{07EF}','\u{07F0}','\u{07F1}','\u{07F3}','\u{0816}','\u{0817}','\u{0818}','\u{0819}',
    '\u{081B}','\u{081C}','\u{081D}','\u{081E}','\u{081F}','\u{0820}','\u{0821}','\u{0822}',
    '\u{0823}','\u{0825}','\u{0826}','\u{0827}','\u{0829}','\u{082A}','\u{082B}','\u{082C}',
    '\u{082D}','\u{0951}','\u{0953}','\u{0954}','\u{0F82}','\u{0F83}','\u{0F86}','\u{0F87}',
    '\u{135D}','\u{135E}','\u{135F}','\u{17DD}','\u{193A}','\u{1A17}','\u{1A75}','\u{1A76}',
    '\u{1A77}','\u{1A78}','\u{1A79}','\u{1A7A}','\u{1A7B}','\u{1A7C}','\u{1B6B}','\u{1B6D}',
    '\u{1B6E}','\u{1B6F}','\u{1B70}','\u{1B71}','\u{1B72}','\u{1B73}','\u{1CD0}','\u{1CD1}',
    '\u{1CD2}','\u{1CDA}','\u{1CDB}','\u{1CE0}','\u{1DC0}','\u{1DC1}','\u{1DC3}','\u{1DC4}',
    '\u{1DC5}','\u{1DC6}','\u{1DC7}','\u{1DC8}','\u{1DC9}','\u{1DCB}','\u{1DCC}','\u{1DD1}',
    '\u{1DD2}','\u{1DD3}','\u{1DD4}','\u{1DD5}','\u{1DD6}','\u{1DD7}','\u{1DD8}','\u{1DD9}',
    '\u{1DDA}','\u{1DDB}','\u{1DDC}','\u{1DDD}','\u{1DDE}','\u{1DDF}','\u{1DE0}','\u{1DE1}',
    '\u{1DE2}','\u{1DE3}','\u{1DE4}','\u{1DE5}','\u{1DE6}','\u{1DFE}','\u{20D0}','\u{20D1}',
    '\u{20D4}','\u{20D5}','\u{20D6}','\u{20D7}','\u{20DB}','\u{20DC}','\u{20E1}','\u{20E7}',
    '\u{20E9}','\u{20F0}','\u{2CEF}','\u{2CF0}','\u{2CF1}','\u{2DE0}','\u{2DE1}','\u{2DE2}',
    '\u{2DE3}','\u{2DE4}','\u{2DE5}','\u{2DE6}','\u{2DE7}','\u{2DE8}','\u{2DE9}','\u{2DEA}',
    '\u{2DEB}','\u{2DEC}','\u{2DED}','\u{2DEE}','\u{2DEF}','\u{2DF0}','\u{2DF1}','\u{2DF2}',
    '\u{2DF3}','\u{2DF4}','\u{2DF5}','\u{2DF6}','\u{2DF7}','\u{2DF8}','\u{2DF9}','\u{2DFA}',
    '\u{2DFB}','\u{2DFC}','\u{2DFD}','\u{2DFE}','\u{2DFF}','\u{A66F}','\u{A67C}','\u{A67D}',
    '\u{A6F0}','\u{A6F1}','\u{A8E0}','\u{A8E1}','\u{A8E2}','\u{A8E3}','\u{A8E4}','\u{A8E5}',
    '\u{A8E6}','\u{A8E7}','\u{A8E8}','\u{A8E9}','\u{A8EA}','\u{A8EB}','\u{A8EC}','\u{A8ED}',
    '\u{A8EE}','\u{A8EF}','\u{A8F0}','\u{A8F1}','\u{AAB0}','\u{AAB2}','\u{AAB3}','\u{AAB7}',
    '\u{AAB8}','\u{AABE}','\u{AABF}','\u{AAC1}','\u{FE20}','\u{FE21}','\u{FE22}','\u{FE23}',
    '\u{FE24}','\u{FE25}','\u{FE26}','\u{10A0F}','\u{10A38}','\u{1D185}','\u{1D186}','\u{1D187}',
    '\u{1D188}','\u{1D189}','\u{1D1AA}','\u{1D1AB}','\u{1D1AC}','\u{1D1AD}','\u{1D242}','\u{1D243}',
    '\u{1D244}',
];

#[derive(Debug, Clone, Copy)]
pub struct CellSize {
    pub w: u32,
    pub h: u32,
}

impl CellSize {
    pub fn aspect(&self) -> f32 {
        self.h as f32 / self.w as f32
    }
}

pub fn detect_cell_size() -> Option<CellSize> {
    if let Ok(ws) = crossterm::terminal::window_size() {
        if ws.rows > 0 && ws.columns > 0 && ws.width > 0 && ws.height > 0 {
            let w = ws.width as u32 / ws.columns as u32;
            let h = ws.height as u32 / ws.rows as u32;
            if w > 0 && h > 0 {
                tracing::info!(w, h, source = "ioctl", "detected cell pixel size");
                return Some(CellSize { w, h });
            }
        }
    }
    if let Some(cs) = query_cell_pixels_csi() {
        tracing::info!(
            w = cs.w,
            h = cs.h,
            source = "csi_16t",
            "detected cell pixel size"
        );
        return Some(cs);
    }
    tracing::warn!("cell pixel size unknown; using default aspect");
    None
}

fn query_cell_pixels_csi() -> Option<CellSize> {
    use crossterm::terminal::{disable_raw_mode, enable_raw_mode};
    use std::io::{Read, Write};
    use std::os::unix::io::AsRawFd;

    enable_raw_mode().ok()?;
    let result = (|| -> Option<CellSize> {
        {
            let mut out = std::io::stdout().lock();
            out.write_all(b"\x1b[16t").ok()?;
            out.flush().ok()?;
        }
        let stdin = std::io::stdin();
        let fd = stdin.as_raw_fd();
        let mut pfd = libc::pollfd {
            fd,
            events: libc::POLLIN,
            revents: 0,
        };
        let ret = unsafe { libc::poll(&mut pfd, 1, 200) };
        if ret <= 0 {
            return None;
        }
        let mut buf = [0u8; 64];
        let mut handle = stdin.lock();
        let n = handle.read(&mut buf).ok()?;
        let s = std::str::from_utf8(&buf[..n]).ok()?;
        let s = s.strip_prefix("\x1b[6;")?;
        let s = s.strip_suffix('t')?;
        let mut parts = s.split(';');
        let h: u32 = parts.next()?.parse().ok()?;
        let w: u32 = parts.next()?.parse().ok()?;
        if w > 0 && h > 0 {
            Some(CellSize { w, h })
        } else {
            None
        }
    })();
    let _ = disable_raw_mode();
    result
}

#[derive(Debug, Clone, Copy)]
pub enum MediaMode {
    Kitty { cell: CellSize },
    Halfblocks,
    Disabled,
}

#[derive(Debug, Clone)]
pub enum MediaEntry {
    Loading,
    ReadyKitty {
        id: u32,
        w: u32,
        h: u32,
    },
    ReadyPixels {
        pixels: Arc<Vec<u8>>,
        w: u32,
        h: u32,
    },
    Failed(String),
    Unsupported {
        kind: MediaKind,
    },
}

impl MediaEntry {
    pub fn dims(&self) -> Option<(u32, u32)> {
        match self {
            MediaEntry::ReadyKitty { w, h, .. } | MediaEntry::ReadyPixels { w, h, .. } => {
                Some((*w, *h))
            }
            _ => None,
        }
    }
}

pub struct MediaRegistry {
    pub entries: HashMap<String, MediaEntry>,
    pub mode: MediaMode,
    next_id: u32,
    semaphore: Arc<Semaphore>,
    insertion_order: VecDeque<String>,
}

impl Default for MediaRegistry {
    fn default() -> Self {
        Self::new()
    }
}

impl MediaRegistry {
    pub fn new() -> Self {
        let mode = if std::env::var("UNRAGER_DISABLE_IMAGES").ok().as_deref() == Some("1") {
            MediaMode::Disabled
        } else if detect_kitty_support() {
            match detect_cell_size() {
                Some(cell) => MediaMode::Kitty { cell },
                None => MediaMode::Halfblocks,
            }
        } else {
            MediaMode::Halfblocks
        };
        tracing::info!(?mode, "media mode selected");
        Self {
            entries: HashMap::new(),
            mode,
            next_id: 1,
            semaphore: Arc::new(Semaphore::new(4)),
            insertion_order: VecDeque::new(),
        }
    }

    pub fn supported(&self) -> bool {
        !matches!(self.mode, MediaMode::Disabled)
    }

    pub fn cell_size(&self) -> Option<CellSize> {
        match self.mode {
            MediaMode::Kitty { cell } => Some(cell),
            _ => None,
        }
    }

    pub fn is_kitty(&self) -> bool {
        matches!(self.mode, MediaMode::Kitty { .. })
    }

    pub fn get(&self, url: &str) -> Option<&MediaEntry> {
        self.entries.get(url)
    }

    fn insert_entry(&mut self, url: String, entry: MediaEntry) {
        self.insertion_order.push_back(url.clone());
        self.entries.insert(url, entry);
        while self.entries.len() > MAX_MEDIA_ENTRIES {
            let Some(old) = self.insertion_order.pop_front() else {
                break;
            };
            if let Some(MediaEntry::ReadyKitty { id, .. }) = self.entries.remove(&old) {
                delete_image(id);
            }
        }
    }

    pub fn ensure_tweet_media(&mut self, tweet: &Tweet, tx: &EventTx) {
        self.ensure_tweet_media_filtered(tweet, tx, |_| true);
    }

    /// Variant that only queues YouTube thumbnail downloads, used in the source
    /// feed where photos stay cold until the user expands them but YouTube
    /// cards always render and need their thumbnail eagerly.
    pub fn ensure_tweet_youtube_thumbnails(&mut self, tweet: &Tweet, tx: &EventTx) {
        self.ensure_tweet_media_filtered(tweet, tx, |k| matches!(k, MediaKind::YouTube { .. }));
    }

    fn ensure_tweet_media_filtered(
        &mut self,
        tweet: &Tweet,
        tx: &EventTx,
        keep: impl Fn(&MediaKind) -> bool + Copy,
    ) {
        if !self.supported() {
            return;
        }
        if let Some(qt) = &tweet.quoted_tweet {
            self.ensure_tweet_media_filtered(qt, tx, keep);
        }
        let is_kitty = self.is_kitty();
        for media in &tweet.media {
            if !keep(&media.kind) {
                continue;
            }
            if self.entries.contains_key(&media.url) {
                continue;
            }
            match &media.kind {
                MediaKind::Photo | MediaKind::YouTube { .. } => {
                    self.insert_entry(media.url.clone(), MediaEntry::Loading);
                    let url = media.url.clone();
                    let sem = self.semaphore.clone();
                    let tx = tx.clone();
                    if is_kitty {
                        let id = self.next_id;
                        self.next_id += 1;
                        tokio::spawn(async move {
                            let _permit = sem.acquire_owned().await.ok();
                            match fetch_and_transmit_kitty(id, &url).await {
                                Ok((w, h)) => {
                                    let _ = tx.send(Event::MediaLoadedKitty { url, id, w, h });
                                }
                                Err(e) => {
                                    let _ = tx.send(Event::MediaFailed {
                                        url,
                                        err: e.to_string(),
                                    });
                                }
                            }
                        });
                    } else {
                        tokio::spawn(async move {
                            let _permit = sem.acquire_owned().await.ok();
                            match fetch_and_decode(&url).await {
                                Ok((pixels, w, h)) => {
                                    let _ = tx.send(Event::MediaLoadedPixels { url, pixels, w, h });
                                }
                                Err(e) => {
                                    let _ = tx.send(Event::MediaFailed {
                                        url,
                                        err: e.to_string(),
                                    });
                                }
                            }
                        });
                    }
                }
                MediaKind::Video | MediaKind::AnimatedGif => {
                    self.insert_entry(
                        media.url.clone(),
                        MediaEntry::Unsupported {
                            kind: media.kind.clone(),
                        },
                    );
                }
            }
        }
    }

    pub fn mark_ready_kitty(&mut self, url: &str, id: u32, w: u32, h: u32) {
        self.entries
            .insert(url.to_string(), MediaEntry::ReadyKitty { id, w, h });
    }

    pub fn mark_ready_pixels(&mut self, url: &str, pixels: Arc<Vec<u8>>, w: u32, h: u32) {
        self.entries
            .insert(url.to_string(), MediaEntry::ReadyPixels { pixels, w, h });
    }

    pub fn mark_failed(&mut self, url: &str, err: String) {
        self.entries
            .insert(url.to_string(), MediaEntry::Failed(err));
    }
}

fn delete_image(id: u32) {
    let mut out = std::io::stdout().lock();
    let _ = write!(out, "\x1b_Ga=d,d=i,i={id},q=2\x1b\\");
    let _ = out.flush();
}

pub fn cleanup_all() {
    let mut out = std::io::stdout().lock();
    let _ = write!(out, "\x1b_Ga=d,d=A,q=2\x1b\\");
    let _ = out.flush();
}

fn detect_kitty_support() -> bool {
    if std::env::var("UNRAGER_DISABLE_KITTY").is_ok() {
        return false;
    }
    if std::env::var("UNRAGER_FORCE_HALFBLOCKS").is_ok() {
        return false;
    }
    if std::env::var("KITTY_WINDOW_ID").is_ok() {
        return true;
    }
    if let Ok(term_program) = std::env::var("TERM_PROGRAM") {
        let lower = term_program.to_ascii_lowercase();
        if lower.contains("ghostty") || lower.contains("wezterm") {
            return true;
        }
    }
    if let Ok(term) = std::env::var("TERM") {
        let lower = term.to_ascii_lowercase();
        if lower.contains("kitty") || lower.contains("ghostty") {
            return true;
        }
    }
    if let Ok(konsole) = std::env::var("KONSOLE_VERSION") {
        if let Ok(ver) = konsole.parse::<u32>() {
            if ver >= 220370 {
                return true;
            }
        }
    }
    false
}

const SRC_MAX_DIM: u32 = 800;

async fn fetch_and_transmit_kitty(
    id: u32,
    url: &str,
) -> Result<(u32, u32), Box<dyn std::error::Error + Send + Sync>> {
    let bytes = reqwest::Client::new()
        .get(url)
        .send()
        .await?
        .error_for_status()?
        .bytes()
        .await?;
    let (raw, w, h) =
        tokio::task::spawn_blocking(move || -> Result<(Vec<u8>, u32, u32), image::ImageError> {
            let img = image::load_from_memory(&bytes)?;
            let img = downscale(img, SRC_MAX_DIM);
            let rgba = img.to_rgba8();
            let (w, h) = rgba.dimensions();
            Ok((rgba.into_raw(), w, h))
        })
        .await??;
    tokio::task::spawn_blocking(move || transmit_image(id, &raw, w, h)).await?;
    Ok((w, h))
}

async fn fetch_and_decode(
    url: &str,
) -> Result<(Arc<Vec<u8>>, u32, u32), Box<dyn std::error::Error + Send + Sync>> {
    let bytes = reqwest::Client::new()
        .get(url)
        .send()
        .await?
        .error_for_status()?
        .bytes()
        .await?;
    let (raw, w, h) =
        tokio::task::spawn_blocking(move || -> Result<(Vec<u8>, u32, u32), image::ImageError> {
            let img = image::load_from_memory(&bytes)?;
            let img = downscale(img, 512);
            let rgba = img.to_rgba8();
            let (w, h) = rgba.dimensions();
            Ok((rgba.into_raw(), w, h))
        })
        .await??;
    Ok((Arc::new(raw), w, h))
}

fn downscale(img: image::DynamicImage, max_dim: u32) -> image::DynamicImage {
    use image::GenericImageView;
    let (w, h) = img.dimensions();
    if w <= max_dim && h <= max_dim {
        return img;
    }
    let scale = (max_dim as f32 / w as f32).min(max_dim as f32 / h as f32);
    let new_w = ((w as f32 * scale).round() as u32).max(1);
    let new_h = ((h as f32 * scale).round() as u32).max(1);
    img.resize_exact(new_w, new_h, image::imageops::FilterType::Lanczos3)
}

fn transmit_image(id: u32, rgba: &[u8], w: u32, h: u32) {
    let encoded = STANDARD.encode(rgba);
    let bytes = encoded.as_bytes();
    let chunk_size = 4096;
    let total_chunks = bytes.len().div_ceil(chunk_size).max(1);
    let mut payload = Vec::with_capacity(encoded.len() + total_chunks * 64);
    for (i, chunk) in bytes.chunks(chunk_size).enumerate() {
        let is_last = i + 1 == total_chunks;
        let m = if is_last { 0 } else { 1 };
        let chunk_str = std::str::from_utf8(chunk).unwrap_or("");
        if i == 0 {
            let _ = write!(
                payload,
                "\x1b_Ga=t,f=32,s={w},v={h},i={id},q=2,m={m};{chunk_str}\x1b\\"
            );
        } else {
            let _ = write!(payload, "\x1b_Gm={m},q=2;{chunk_str}\x1b\\");
        }
    }
    let mut out = std::io::stdout().lock();
    let _ = out.write_all(&payload);
    let _ = out.flush();
}

pub fn kitty_image_cells(cell: CellSize, img_w: u32, img_h: u32, max_cols: u32) -> (u32, u32) {
    if img_w == 0 || img_h == 0 || cell.w == 0 || cell.h == 0 {
        return (0, 0);
    }
    let natural_cols = img_w.div_ceil(cell.w);
    let natural_rows = img_h.div_ceil(cell.h);
    if natural_cols <= max_cols {
        return (natural_cols.max(1), natural_rows.max(1));
    }
    let scale = max_cols as f32 / natural_cols as f32;
    let cols = max_cols;
    let rows = (natural_rows as f32 * scale).round().max(1.0) as u32;
    (cols, rows)
}

pub fn fit_cells_to_pane(cols: u32, rows: u32, max_cols: u32, max_rows: u32) -> (u32, u32) {
    if cols == 0 || rows == 0 {
        return (0, 0);
    }
    let mut c = cols.min(max_cols);
    let mut r = (rows as u64 * c as u64 / cols as u64) as u32;
    if r > max_rows {
        r = max_rows;
        c = (cols as u64 * r as u64 / rows as u64) as u32;
    }
    (c.max(1), r.max(1))
}

pub fn emit_kitty_placement(id: u32, cols: u32, rows: u32) {
    let mut out = std::io::stdout().lock();
    let _ = write!(out, "\x1b_Ga=p,U=1,i={id},c={cols},r={rows},q=2\x1b\\");
    let _ = out.flush();
}

pub fn placeholder_lines(
    id: u32,
    rows: u32,
    cols: u32,
    indent: &Span<'static>,
) -> Vec<Line<'static>> {
    let rows = (rows as usize).min(DIACRITICS.len());
    let cols = (cols as usize).min(DIACRITICS.len());
    let color = id_color(id);
    let style = Style::default().fg(color);
    let mut out = Vec::with_capacity(rows);
    for r in 0..rows {
        let spans: Vec<Span<'static>> = vec![indent.clone(), placeholder_row(r, cols, style)];
        out.push(Line::from(spans));
    }
    out
}

fn placeholder_row(row: usize, cols: usize, style: Style) -> Span<'static> {
    let row = row.min(DIACRITICS.len() - 1);
    let row_dia = DIACRITICS[row];
    let mut s = String::with_capacity(cols * 9);
    for &col_dia in DIACRITICS.iter().take(cols) {
        s.push(PLACEHOLDER);
        s.push(row_dia);
        s.push(col_dia);
    }
    Span::styled(s, style)
}

/// Builds a single placeholder row span for a kitty image with the given id.
/// Useful when the caller wants to embed the row inside a custom layout
/// (like a bordered card) rather than using `placeholder_lines`.
pub fn placeholder_row_for(id: u32, row: usize, cols: usize) -> Span<'static> {
    placeholder_row(row, cols, Style::default().fg(id_color(id)))
}

fn id_color(id: u32) -> Color {
    Color::Rgb(
        ((id >> 16) & 0xff) as u8,
        ((id >> 8) & 0xff) as u8,
        (id & 0xff) as u8,
    )
}

fn rgba_at(rgba: &[u8], w: u32, x: u32, y: u32) -> (u8, u8, u8) {
    let idx = ((y * w + x) * 4) as usize;
    (rgba[idx], rgba[idx + 1], rgba[idx + 2])
}

fn brightness(p: (u8, u8, u8)) -> u32 {
    p.0 as u32 + p.1 as u32 + p.2 as u32
}

fn avg_color(pixels: &[(u8, u8, u8)]) -> Option<(u8, u8, u8)> {
    if pixels.is_empty() {
        return None;
    }
    let n = pixels.len() as u32;
    let (r, g, b) = pixels.iter().fold((0u32, 0u32, 0u32), |acc, p| {
        (acc.0 + p.0 as u32, acc.1 + p.1 as u32, acc.2 + p.2 as u32)
    });
    Some(((r / n) as u8, (g / n) as u8, (b / n) as u8))
}

#[rustfmt::skip]
const SEXTANT_CHARS: [&str; 64] = [
    " ",
    "🬀","🬁","🬂","🬃","🬄","🬅","🬆","🬇","🬈","🬉","🬊","🬋","🬌","🬍","🬎","🬏","🬐","🬑","🬒","🬓",
    "▌",
    "🬔","🬕","🬖","🬗","🬘","🬙","🬚","🬛","🬜","🬝","🬞","🬟","🬠","🬡","🬢","🬣","🬤","🬥","🬦","🬧",
    "▐",
    "🬨","🬩","🬪","🬫","🬬","🬭","🬮","🬯","🬰","🬱","🬲","🬳","🬴","🬵","🬶","🬷","🬸","🬹","🬺","🬻",
    "█",
];

fn sextant_char(mask: u8) -> &'static str {
    SEXTANT_CHARS[(mask & 0x3F) as usize]
}

fn fit_grid_halfblocks(aspect: f32, max_cols: usize, max_rows: usize) -> (usize, usize) {
    if max_cols == 0 || max_rows == 0 {
        return (0, 0);
    }
    let ideal_rows = (max_cols as f32 * aspect / 2.0).round().max(1.0) as usize;
    if ideal_rows <= max_rows {
        (max_cols, ideal_rows)
    } else {
        let cols = ((max_rows as f32 * 2.0 / aspect).round().max(1.0) as usize).min(max_cols);
        (cols, max_rows)
    }
}

pub fn render_sextants(
    pixels: &[u8],
    src_w: u32,
    src_h: u32,
    max_cols: usize,
    max_rows: usize,
    indent: &Span<'static>,
) -> Vec<Line<'static>> {
    if max_cols == 0 || max_rows == 0 || src_w == 0 || src_h == 0 {
        return vec![];
    }
    let aspect = src_h as f32 / src_w as f32;
    let (cols, rows) = fit_grid_halfblocks(aspect, max_cols, max_rows);
    if cols == 0 || rows == 0 {
        return vec![];
    }
    let target_w = (cols as u32).saturating_mul(2).max(2);
    let target_h = (rows as u32).saturating_mul(3).max(3);

    let src = image::RgbaImage::from_raw(src_w, src_h, pixels.to_vec());
    let Some(src) = src else {
        return vec![];
    };
    let resized = image::imageops::resize(
        &src,
        target_w,
        target_h,
        image::imageops::FilterType::Lanczos3,
    );
    let rgba = resized.as_raw();

    let mut out = Vec::with_capacity(rows);
    for y in 0..rows {
        let mut spans: Vec<Span<'static>> = Vec::with_capacity(cols + 1);
        spans.push(indent.clone());
        for x in 0..cols {
            let px = x as u32 * 2;
            let py = y as u32 * 3;
            let sub = [
                rgba_at(rgba, target_w, px, py),
                rgba_at(rgba, target_w, px + 1, py),
                rgba_at(rgba, target_w, px, py + 1),
                rgba_at(rgba, target_w, px + 1, py + 1),
                rgba_at(rgba, target_w, px, py + 2),
                rgba_at(rgba, target_w, px + 1, py + 2),
            ];
            let bs: [u32; 6] = [
                brightness(sub[0]),
                brightness(sub[1]),
                brightness(sub[2]),
                brightness(sub[3]),
                brightness(sub[4]),
                brightness(sub[5]),
            ];
            let avg = bs.iter().sum::<u32>() / 6;
            let mut fg_pix: Vec<(u8, u8, u8)> = Vec::with_capacity(6);
            let mut bg_pix: Vec<(u8, u8, u8)> = Vec::with_capacity(6);
            let mut mask = 0u8;
            for i in 0..6 {
                if bs[i] >= avg {
                    fg_pix.push(sub[i]);
                    mask |= 1 << i;
                } else {
                    bg_pix.push(sub[i]);
                }
            }
            let fg = avg_color(&fg_pix).unwrap_or((0, 0, 0));
            let bg = avg_color(&bg_pix).unwrap_or(fg);

            spans.push(Span::styled(
                sextant_char(mask),
                Style::default()
                    .fg(Color::Rgb(fg.0, fg.1, fg.2))
                    .bg(Color::Rgb(bg.0, bg.1, bg.2)),
            ));
        }
        out.push(Line::from(spans));
    }
    out
}

pub fn media_badge_loading() -> Line<'static> {
    Line::from(vec![
        Span::raw("  "),
        Span::styled("[img ↓]", Style::default().fg(Color::DarkGray)),
    ])
}

pub fn media_badge_failed() -> Line<'static> {
    Line::from(vec![
        Span::raw("  "),
        Span::styled("[img ×]", Style::default().fg(Color::Red)),
    ])
}

pub fn media_badge_video() -> Line<'static> {
    Line::from(vec![
        Span::raw("  "),
        Span::styled(
            "[▶ video]",
            Style::default()
                .fg(Color::DarkGray)
                .add_modifier(Modifier::ITALIC),
        ),
    ])
}

pub fn media_badge_gif() -> Line<'static> {
    Line::from(vec![
        Span::raw("  "),
        Span::styled(
            "[gif]",
            Style::default()
                .fg(Color::DarkGray)
                .add_modifier(Modifier::ITALIC),
        ),
    ])
}

pub fn first_renderable_photo(tweet: &Tweet) -> Option<&Media> {
    tweet
        .media
        .iter()
        .find(|m| matches!(m.kind, MediaKind::Photo))
}
