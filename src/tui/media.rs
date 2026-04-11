use crate::model::{Media, MediaKind, Tweet};
use crate::tui::event::{Event, EventTx};
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use std::collections::HashMap;
use std::io::Write;
use std::sync::Arc;
use tokio::sync::Semaphore;

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

pub const COMPACT_COLS: u16 = 14;
pub const COMPACT_ROWS: u16 = 5;
pub const EXPANDED_COLS: u16 = 40;
pub const EXPANDED_ROWS: u16 = 12;

pub fn layout_for(count: usize, wrap_width: usize) -> (usize, usize) {
    let inner = wrap_width.saturating_sub(4);
    match count {
        0 => (0, 0),
        1 => (inner.min(40).max(10), 12),
        2 => {
            let per = inner.saturating_sub(2) / 2;
            (per.min(22).max(8), 10)
        }
        3 => {
            let per = inner.saturating_sub(4) / 3;
            (per.min(16).max(6), 8)
        }
        _ => {
            let per = inner.saturating_sub(6) / 4;
            (per.min(12).max(6), 6)
        }
    }
}

#[derive(Debug, Clone)]
pub enum MediaEntry {
    Loading,
    Ready { id_compact: u32, id_expanded: u32 },
    Failed(String),
    Unsupported { kind: MediaKind },
}

pub struct MediaRegistry {
    pub entries: HashMap<String, MediaEntry>,
    pub supported: bool,
    next_id: u32,
    semaphore: Arc<Semaphore>,
}

impl MediaRegistry {
    pub fn new() -> Self {
        Self {
            entries: HashMap::new(),
            supported: detect_kitty_support(),
            next_id: 1,
            semaphore: Arc::new(Semaphore::new(4)),
        }
    }

    pub fn get(&self, url: &str) -> Option<&MediaEntry> {
        self.entries.get(url)
    }

    pub fn ensure_tweet_media(&mut self, tweet: &Tweet, tx: &EventTx) {
        if !self.supported {
            return;
        }
        for media in &tweet.media {
            if self.entries.contains_key(&media.url) {
                continue;
            }
            match media.kind {
                MediaKind::Photo => {
                    self.entries.insert(media.url.clone(), MediaEntry::Loading);
                    let id_compact = self.next_id;
                    self.next_id += 1;
                    let id_expanded = self.next_id;
                    self.next_id += 1;
                    let url = media.url.clone();
                    let sem = self.semaphore.clone();
                    let tx = tx.clone();
                    tokio::spawn(async move {
                        let _permit = sem.acquire_owned().await.ok();
                        match fetch_and_transmit(id_compact, id_expanded, &url).await {
                            Ok(()) => {
                                let _ = tx.send(Event::MediaLoaded {
                                    url,
                                    id: id_compact,
                                    id_expanded,
                                });
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
                MediaKind::Video | MediaKind::AnimatedGif => {
                    self.entries.insert(
                        media.url.clone(),
                        MediaEntry::Unsupported { kind: media.kind },
                    );
                }
            }
        }
    }

    pub fn mark_ready(&mut self, url: &str, id_compact: u32, id_expanded: u32) {
        self.entries.insert(
            url.to_string(),
            MediaEntry::Ready {
                id_compact,
                id_expanded,
            },
        );
    }

    pub fn mark_failed(&mut self, url: &str, err: String) {
        self.entries.insert(url.to_string(), MediaEntry::Failed(err));
    }
}

fn detect_kitty_support() -> bool {
    if std::env::var("UNRAGER_DISABLE_KITTY").is_ok() {
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
    false
}

async fn fetch_and_transmit(
    id_compact: u32,
    id_expanded: u32,
    url: &str,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
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
            let img = downscale_for_transmit(img);
            let rgba = img.to_rgba8();
            let dims = rgba.dimensions();
            Ok((rgba.into_raw(), dims.0, dims.1))
        })
        .await??;
    let raw = Arc::new(raw);
    let raw_a = raw.clone();
    tokio::task::spawn_blocking(move || {
        transmit_image(id_compact, &raw_a, w, h, COMPACT_COLS, COMPACT_ROWS);
    })
    .await?;
    let raw_b = raw.clone();
    tokio::task::spawn_blocking(move || {
        transmit_image(id_expanded, &raw_b, w, h, EXPANDED_COLS, EXPANDED_ROWS);
    })
    .await?;
    Ok(())
}

fn downscale_for_transmit(img: image::DynamicImage) -> image::DynamicImage {
    use image::GenericImageView;
    const MAX_DIM: u32 = 400;
    let (w, h) = img.dimensions();
    if w <= MAX_DIM && h <= MAX_DIM {
        return img;
    }
    let scale = (MAX_DIM as f32 / w as f32).min(MAX_DIM as f32 / h as f32);
    let new_w = (w as f32 * scale).round() as u32;
    let new_h = (h as f32 * scale).round() as u32;
    img.resize_exact(new_w, new_h, image::imageops::FilterType::Triangle)
}

pub fn transmit_image(id: u32, rgba: &[u8], w: u32, h: u32, _place_cols: u16, _place_rows: u16) {
    let encoded = STANDARD.encode(rgba);
    let bytes = encoded.as_bytes();
    let chunk_size = 4096;
    let mut out = std::io::stdout().lock();
    let total_chunks = bytes.len().div_ceil(chunk_size).max(1);
    for (i, chunk) in bytes.chunks(chunk_size).enumerate() {
        let is_last = i + 1 == total_chunks;
        let m = if is_last { 0 } else { 1 };
        let chunk_str = std::str::from_utf8(chunk).unwrap_or("");
        if i == 0 {
            let _ = write!(
                out,
                "\x1b_Ga=t,f=32,s={w},v={h},i={id},q=2,m={m};{chunk_str}\x1b\\"
            );
        } else {
            let _ = write!(out, "\x1b_Gm={m},q=2;{chunk_str}\x1b\\");
        }
    }
    let _ = out.flush();
}

pub fn cleanup_all() {
    let mut out = std::io::stdout().lock();
    let _ = write!(out, "\x1b_Ga=d,d=A,q=2\x1b\\");
    let _ = out.flush();
}

fn id_color(id: u32) -> Color {
    Color::Rgb(
        ((id >> 16) & 0xff) as u8,
        ((id >> 8) & 0xff) as u8,
        (id & 0xff) as u8,
    )
}

pub fn placeholder_lines(id: u32, rows: usize, cols: usize) -> Vec<Line<'static>> {
    let rows = rows.min(DIACRITICS.len());
    let cols = cols.min(DIACRITICS.len());
    let color = id_color(id);
    let style = Style::default().fg(color);
    let mut out = Vec::with_capacity(rows);
    for r in 0..rows {
        out.push(Line::from(placeholder_row(id, r, cols, style)));
    }
    out
}

pub fn placeholder_row_span(id: u32, row: usize, cols: usize) -> Span<'static> {
    let style = Style::default().fg(id_color(id));
    placeholder_row(id, row, cols, style)
}

fn placeholder_row(id: u32, row: usize, cols: usize, style: Style) -> Span<'static> {
    let _ = id;
    let cols = cols.min(DIACRITICS.len());
    let row = row.min(DIACRITICS.len() - 1);
    let row_dia = DIACRITICS[row];
    let mut s = String::with_capacity(cols * 9);
    for c in 0..cols {
        let col_dia = DIACRITICS[c];
        s.push(PLACEHOLDER);
        s.push(row_dia);
        s.push(col_dia);
    }
    Span::styled(s, style)
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
