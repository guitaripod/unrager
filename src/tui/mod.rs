pub mod app;
mod app_fetch;
mod app_keys;
mod app_llm;
mod app_nav;
mod app_screenshot;
pub mod ask;
pub mod background;
pub mod brief;
pub mod clock;
pub mod command;
pub mod compose;
pub mod demo;
pub mod editor;
pub mod emoji_cache;
pub mod engage;
pub mod eval;
pub mod event;
pub mod external;
pub mod filter;
pub mod focus;
pub mod media;
pub mod screenshot;
pub mod seen;
pub mod session;
pub mod songlink;
pub mod sound;
pub mod source;
#[cfg(test)]
pub(crate) mod test_util;
pub mod theme;
pub mod ui;
pub mod whisper;
pub mod youtube;

use crate::error::Result;
use app::App;
use crossterm::event::{
    DisableFocusChange, EnableFocusChange, KeyboardEnhancementFlags, PopKeyboardEnhancementFlags,
    PushKeyboardEnhancementFlags,
};
use crossterm::execute;
use event::EventLoop;
use std::io::stdout;
use std::time::Duration;

pub async fn run() -> Result<()> {
    let is_dark = detect_is_dark();
    let mut terminal = ratatui::init();
    let _ = execute!(stdout(), EnableFocusChange);
    let kbd_enhanced = matches!(
        crossterm::terminal::supports_keyboard_enhancement(),
        Ok(true)
    ) && execute!(
        stdout(),
        PushKeyboardEnhancementFlags(KeyboardEnhancementFlags::DISAMBIGUATE_ESCAPE_CODES)
    )
    .is_ok();
    let result = run_inner(&mut terminal, is_dark).await;
    if kbd_enhanced {
        let _ = execute!(stdout(), PopKeyboardEnhancementFlags);
    }
    let _ = execute!(stdout(), DisableFocusChange);
    media::cleanup_all();
    ratatui::restore();
    result
}

/// Whether the terminal's background is dark, from its answer to an OSC 11
/// query. No answer (or no terminal) counts as dark, the common setup.
fn detect_is_dark() -> bool {
    match terminal_background(Duration::from_secs(1)) {
        Some((r, g, b)) => {
            let dark =
                f64::from(r) * 0.299 + f64::from(g) * 0.587 + f64::from(b) * 0.114 <= 32768.0;
            tracing::info!(r, g, b, dark, "terminal background");
            dark
        }
        None => {
            tracing::info!("terminal didn't report its background; assuming dark");
            true
        }
    }
}

#[cfg(unix)]
fn terminal_background(timeout: Duration) -> Option<(u16, u16, u16)> {
    use std::io::IsTerminal;
    if !std::io::stdin().is_terminal() || !std::io::stdout().is_terminal() {
        return None;
    }
    crossterm::terminal::enable_raw_mode().ok()?;
    let reply = ask_background(timeout);
    let _ = crossterm::terminal::disable_raw_mode();
    parse_background_reply(&reply?)
}

#[cfg(not(unix))]
fn terminal_background(_timeout: Duration) -> Option<(u16, u16, u16)> {
    None
}

/// Sends the plain xterm query, which tmux answers itself, then a primary
/// device attributes query (DA1), which every terminal answers, and reads the
/// replies byte by byte straight off stdin behind `poll` until the DA1 answer
/// arrives. Terminals answer in order, so one that ignores OSC 11 costs a
/// round trip instead of the whole timeout, and a slow SSH link can't leave a
/// late reply behind to be read as keystrokes. termbg sent tmux a passthrough
/// query it drops by default, and the reader it left blocked on stdin hung
/// startup until the first key, which it then swallowed.
#[cfg(unix)]
fn ask_background(timeout: Duration) -> Option<Vec<u8>> {
    use std::io::Write;
    let mut out = std::io::stdout();
    out.write_all(b"\x1b]11;?\x1b\\\x1b[c").ok()?;
    out.flush().ok()?;
    let deadline = std::time::Instant::now() + timeout;
    let mut reply = Vec::new();
    while reply.len() < 256 {
        let Some(left) = deadline.checked_duration_since(std::time::Instant::now()) else {
            break;
        };
        let mut stdin = libc::pollfd {
            fd: libc::STDIN_FILENO,
            events: libc::POLLIN,
            revents: 0,
        };
        let millis = left.as_millis().min(i32::MAX as u128) as i32;
        if unsafe { libc::poll(&mut stdin, 1, millis) } <= 0 {
            break;
        }
        let mut byte = 0u8;
        let read = unsafe {
            libc::read(
                libc::STDIN_FILENO,
                (&mut byte as *mut u8).cast::<libc::c_void>(),
                1,
            )
        };
        if read != 1 {
            break;
        }
        reply.push(byte);
        if ends_with_device_attributes(&reply) {
            break;
        }
    }
    (!reply.is_empty()).then_some(reply)
}

/// Whether `reply` ends with a DA1 answer, `ESC [ ? <digits and ;> c`.
fn ends_with_device_attributes(reply: &[u8]) -> bool {
    let Some((b'c', body)) = reply.split_last() else {
        return false;
    };
    body.windows(3)
        .rposition(|w| w == b"\x1b[?")
        .is_some_and(|start| {
            body[start + 3..]
                .iter()
                .all(|b| b.is_ascii_digit() || *b == b';')
        })
}

/// `rgb:RRRR/GGGG/BBBB` out of an OSC 11 reply, each channel scaled to 16
/// bits whatever its width (terminals answer with 1 to 4 hex digits).
fn parse_background_reply(reply: &[u8]) -> Option<(u16, u16, u16)> {
    let text = std::str::from_utf8(reply).ok()?;
    let rgb = &text[text.find("rgb:")? + 4..];
    let end = rgb
        .find(|c: char| !(c.is_ascii_hexdigit() || c == '/'))
        .unwrap_or(rgb.len());
    let mut channels = rgb[..end].split('/').map(|hex| {
        let digits = u32::try_from(hex.len())
            .ok()
            .filter(|d| (1..=4).contains(d))?;
        let value = u32::from_str_radix(hex, 16).ok()?;
        let max = 16u32.pow(digits) - 1;
        Some((value * 0xffff / max) as u16)
    });
    let rgb = (channels.next()??, channels.next()??, channels.next()??);
    channels.next().is_none().then_some(rgb)
}

async fn run_inner(terminal: &mut ratatui::DefaultTerminal, is_dark: bool) -> Result<()> {
    let mut events = EventLoop::new();
    let tx = events.sender();
    let mut app = App::new(tx, is_dark).await?;
    events.start();
    app.load_initial();

    while app.running {
        let Some(event) = events.next().await else {
            break;
        };
        app.handle_event(event, terminal)?;
    }

    if let Some(llm) = app.filter_cfg.as_ref().map(|c| c.llm.clone()) {
        ask::unload_blocking(&llm).await;
    }
    app.save_session();
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{ends_with_device_attributes, parse_background_reply};

    #[test]
    fn osc11_replies_parse_at_any_channel_width() {
        assert_eq!(
            parse_background_reply(b"\x1b]11;rgb:1e1e/1e1e/2e2e\x1b\\"),
            Some((0x1e1e, 0x1e1e, 0x2e2e))
        );
        assert_eq!(
            parse_background_reply(b"\x1b]11;rgb:ff/ff/ff\x07"),
            Some((0xffff, 0xffff, 0xffff))
        );
        assert_eq!(
            parse_background_reply(b"\x1b]11;rgb:0/0/0\x07"),
            Some((0, 0, 0))
        );
    }

    #[test]
    fn the_background_is_read_ahead_of_the_device_attributes() {
        let reply = b"\x1b]11;rgb:ffff/ffff/ffff\x1b\\\x1b[?64;1;2;4c";
        assert!(ends_with_device_attributes(reply));
        assert_eq!(
            parse_background_reply(reply),
            Some((0xffff, 0xffff, 0xffff))
        );
        assert_eq!(parse_background_reply(b"\x1b[?62;22c"), None);
    }

    #[test]
    fn reading_stops_only_at_a_complete_device_attributes_answer() {
        assert!(ends_with_device_attributes(b"\x1b[?1;2c"));
        assert!(!ends_with_device_attributes(b"\x1b[?1;2"));
        assert!(!ends_with_device_attributes(b"\x1b]11;rgb:0/0/c"));
        assert!(!ends_with_device_attributes(b"c"));
    }

    #[test]
    fn malformed_replies_are_rejected() {
        assert_eq!(parse_background_reply(b"\x1b]11;?\x07"), None);
        assert_eq!(parse_background_reply(b"\x1b]11;rgb:12/34\x07"), None);
        assert_eq!(parse_background_reply(b"\x1b]11;rgb:12345/0/0\x07"), None);
        assert_eq!(parse_background_reply(b"\x1b]11;rgb:zz/00/00\x07"), None);
    }
}
