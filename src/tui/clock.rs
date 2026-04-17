use crate::config::{ClockConfig, ClockPosition, HourFormat};
use chrono::Local;
use ratatui::Frame;
use ratatui::layout::{Alignment, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, BorderType, Borders, Clear, Padding, Paragraph};

fn parse_color(name: &str) -> Color {
    match name.to_ascii_lowercase().as_str() {
        "black" => Color::Black,
        "red" => Color::Red,
        "green" => Color::Green,
        "yellow" => Color::Yellow,
        "blue" => Color::Blue,
        "magenta" => Color::Magenta,
        "cyan" => Color::Cyan,
        "white" => Color::White,
        "gray" | "grey" => Color::Gray,
        "darkgray" | "darkgrey" => Color::DarkGray,
        "lightred" => Color::LightRed,
        "lightgreen" => Color::LightGreen,
        "lightyellow" => Color::LightYellow,
        "lightblue" => Color::LightBlue,
        "lightmagenta" => Color::LightMagenta,
        "lightcyan" => Color::LightCyan,
        hex if hex.starts_with('#') && hex.len() == 7 => {
            let r = u8::from_str_radix(&hex[1..3], 16).unwrap_or(0);
            let g = u8::from_str_radix(&hex[3..5], 16).unwrap_or(255);
            let b = u8::from_str_radix(&hex[5..7], 16).unwrap_or(255);
            Color::Rgb(r, g, b)
        }
        idx if idx.parse::<u8>().is_ok() => Color::Indexed(idx.parse().unwrap()),
        _ => Color::Cyan,
    }
}

/// Lowercased `lang_REGION` pulled from the OS locale, with separators
/// normalized and the codeset/modifier stripped. Returns None if the
/// platform doesn't expose one.
fn locale_tag() -> Option<String> {
    let raw = sys_locale::get_locale()?;
    let base = raw.replace('-', "_");
    let stripped = base.split(['.', '@']).next().unwrap_or("");
    if stripped.is_empty() {
        None
    } else {
        Some(stripped.to_string())
    }
}

/// Heuristic: locales whose CLDR "medium time" pattern uses 12-hour form.
/// Covers ~99% of users; anyone misclassified can set `hour_format` explicitly.
fn locale_prefers_12h() -> bool {
    let Some(tag) = locale_tag() else {
        return false;
    };
    matches!(
        tag.as_str(),
        "en_US"
            | "en_CA"
            | "en_AU"
            | "en_NZ"
            | "en_PH"
            | "en_IN"
            | "en_PK"
            | "en_MY"
            | "en_HK"
            | "en_SG"
            | "fr_CA"
            | "es_US"
            | "es_MX"
            | "es_CO"
            | "es_PE"
            | "es_VE"
            | "ar_EG"
            | "ar_SA"
            | "ar_AE"
            | "ar_JO"
            | "ar_LB"
            | "ar_SY"
            | "hi_IN"
            | "bn_IN"
            | "ta_IN"
            | "te_IN"
            | "mr_IN"
            | "gu_IN"
            | "kn_IN"
            | "ml_IN"
            | "pa_IN"
            | "ur_PK"
            | "ur_IN"
    )
}

fn prefers_12h(cfg: &ClockConfig) -> bool {
    match cfg.hour_format {
        HourFormat::H12 => true,
        HourFormat::H24 => false,
        HourFormat::Auto => locale_prefers_12h(),
    }
}

fn time_string(cfg: &ClockConfig) -> String {
    let now = Local::now();
    let fmt = match (prefers_12h(cfg), cfg.show_seconds) {
        (false, true) => "%H:%M:%S",
        (false, false) => "%H:%M",
        (true, true) => "%-I:%M:%S %p",
        (true, false) => "%-I:%M %p",
    };
    now.format(fmt).to_string()
}

/// If the user set a literal strftime, honor it. If `auto`, pick a compact
/// locale-reasonable default: US-style "Fri, Apr 17" for 12h locales, ISO-ish
/// "Fri 17 Apr" for everyone else.
fn date_string(cfg: &ClockConfig) -> String {
    let now = Local::now();
    let raw = cfg.date_format.as_str();
    let fmt = if raw.eq_ignore_ascii_case("auto") {
        if prefers_12h(cfg) {
            "%a, %b %-d"
        } else {
            "%a %-d %b"
        }
    } else {
        raw
    };
    now.format(fmt).to_string()
}

fn place_rect(area: Rect, w: u16, h: u16, pos: ClockPosition) -> Rect {
    let w = w.min(area.width);
    let h = h.min(area.height);
    let (x, y) = match pos {
        ClockPosition::TopLeft | ClockPosition::Header => (area.x, area.y),
        ClockPosition::TopRight => (area.x + area.width.saturating_sub(w), area.y),
        ClockPosition::BottomLeft => (area.x, area.y + area.height.saturating_sub(h)),
        ClockPosition::BottomRight | ClockPosition::Footer => (
            area.x + area.width.saturating_sub(w),
            area.y + area.height.saturating_sub(h),
        ),
    };
    Rect {
        x,
        y,
        width: w,
        height: h,
    }
}

pub fn is_inline(cfg: &ClockConfig) -> bool {
    matches!(cfg.position, ClockPosition::Header | ClockPosition::Footer)
}

/// Right-aligned single-line rendering for the header/footer row. Returns
/// early if the area is empty, the clock is disabled, or every element is off.
pub fn render_inline(frame: &mut Frame, area: Rect, cfg: &ClockConfig) {
    if !cfg.enabled || (!cfg.show_time && !cfg.show_date) || area.width == 0 || area.height == 0 {
        return;
    }
    let accent = parse_color(&cfg.accent);
    let time_style = Style::default().fg(accent).add_modifier(Modifier::BOLD);
    let dim = Style::default().fg(Color::DarkGray);
    let mut spans: Vec<Span<'static>> = Vec::new();
    if cfg.show_time {
        spans.push(Span::styled(time_string(cfg), time_style));
    }
    if cfg.show_time && cfg.show_date {
        spans.push(Span::styled(" · ", dim));
    }
    if cfg.show_date {
        spans.push(Span::styled(date_string(cfg), dim));
    }
    let para = Paragraph::new(Line::from(spans)).alignment(Alignment::Right);
    frame.render_widget(para, area);
}

/// Monospace width of the inline rendering, including the ` · ` separator
/// when both time and date are shown. Caller reserves this much room on the
/// right of the host line.
pub fn inline_width(cfg: &ClockConfig) -> u16 {
    if !cfg.enabled {
        return 0;
    }
    let mut w: usize = 0;
    if cfg.show_time {
        w += unicode_width::UnicodeWidthStr::width(time_string(cfg).as_str());
    }
    if cfg.show_time && cfg.show_date {
        w += 3;
    }
    if cfg.show_date {
        w += unicode_width::UnicodeWidthStr::width(date_string(cfg).as_str());
    }
    w as u16
}

/// Minimal two-line clock overlay. Plain text, no big digit font — we let the
/// terminal's own type do the work. Silently bails if disabled or the terminal
/// is too small to fit.
pub fn render(frame: &mut Frame, area: Rect, cfg: &ClockConfig) {
    if !cfg.enabled || (!cfg.show_time && !cfg.show_date) || is_inline(cfg) {
        return;
    }

    let accent = parse_color(&cfg.accent);
    let time_style = Style::default().fg(accent).add_modifier(Modifier::BOLD);
    let date_style = Style::default().fg(Color::DarkGray);

    let time = cfg.show_time.then(|| time_string(cfg));
    let date = cfg.show_date.then(|| date_string(cfg));

    let time_w = time
        .as_deref()
        .map(unicode_width::UnicodeWidthStr::width)
        .unwrap_or(0);
    let date_w = date
        .as_deref()
        .map(unicode_width::UnicodeWidthStr::width)
        .unwrap_or(0);
    let inner_w = time_w.max(date_w) as u16;
    let mut inner_h: u16 = 0;
    if time.is_some() {
        inner_h += 1;
    }
    if date.is_some() {
        inner_h += 1;
    }

    let (pad_x, pad_y): (u16, u16) = if cfg.border { (4, 2) } else { (2, 0) };
    let w = inner_w.saturating_add(pad_x);
    let h = inner_h.saturating_add(pad_y);
    if w == 0 || h == 0 || area.width < w || area.height < h {
        return;
    }

    let target = place_rect(area, w, h, cfg.position);
    frame.render_widget(Clear, target);

    let mut lines: Vec<Line<'static>> = Vec::new();
    if let Some(t) = time {
        lines.push(Line::from(Span::styled(t, time_style)));
    }
    if let Some(d) = date {
        lines.push(Line::from(Span::styled(d, date_style)));
    }

    let para = Paragraph::new(lines);
    let bg = Style::default().bg(Color::Indexed(234));
    if cfg.border {
        let block = Block::default()
            .borders(Borders::ALL)
            .border_type(BorderType::Rounded)
            .border_style(Style::default().fg(Color::DarkGray))
            .padding(Padding::horizontal(1))
            .style(bg);
        frame.render_widget(para.block(block), target);
    } else {
        let block = Block::default().padding(Padding::horizontal(1)).style(bg);
        frame.render_widget(para.block(block), target);
    }
}
