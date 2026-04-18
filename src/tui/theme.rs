use ratatui::style::Color;
use serde::Deserialize;
use std::sync::{OnceLock, RwLock, RwLockReadGuard};

const fn rgb(r: u8, g: u8, b: u8) -> Color {
    Color::Rgb(r, g, b)
}

const X_BLUE: Color = rgb(0x1d, 0x9b, 0xf0);
const X_LIKE: Color = rgb(0xf9, 0x18, 0x80);
const X_RETWEET: Color = rgb(0x00, 0xba, 0x7c);
const YT_RED: Color = rgb(0xff, 0x00, 0x33);
const WHITE: Color = rgb(0xff, 0xff, 0xff);

#[derive(Debug, Clone)]
pub struct Theme {
    pub name: &'static str,
    pub is_dark: bool,

    pub text: Color,
    pub text_muted: Color,
    pub text_dim: Color,
    pub text_faint: Color,

    pub border: Color,
    pub border_active: Color,
    pub card_border: Color,
    pub divider: Color,
    pub zebra_bg: Color,
    pub clock_bg: Color,

    pub sel_bg_active: Color,
    pub sel_bg_inactive: Color,
    pub sel_marker_active: Color,
    pub sel_marker_inactive: Color,

    pub brand_bg: Color,
    pub brand_fg: Color,

    pub accent: Color,
    pub error: Color,
    pub success: Color,
    pub warning: Color,
    pub info: Color,
    pub unread_dot: Color,
    pub update: Color,
    pub new_unread: Color,

    pub like: Color,
    pub liked: Color,
    pub retweet: Color,
    pub follow: Color,
    pub reply_notif: Color,
    pub quote: Color,
    pub mention: Color,
    pub milestone: Color,

    pub media_photo: Color,
    pub media_video: Color,
    pub media_gif: Color,
    pub media_article: Color,
    pub media_link: Color,
    pub media_poll: Color,
    pub media_loading: Color,
    pub media_failed: Color,
    pub youtube_red: Color,

    pub hashtag: Color,
    pub url: Color,
    pub verified: Color,
    pub translation: Color,
    pub code: Color,

    pub mode_normal_bg: Color,
    pub mode_normal_fg: Color,
    pub mode_cmd_bg: Color,
    pub mode_cmd_fg: Color,
    pub mode_cmd_cursor: Color,
    pub mode_vim_insert: Color,
    pub mode_vim_normal: Color,

    pub ask_user: Color,
    pub ask_assistant: Color,
    pub quote_block: Color,
    pub heading: Color,

    pub whisper_quiet: Color,
    pub whisper_active: Color,
    pub whisper_surge: Color,
    pub whisper_cooling: Color,

    pub card_title: Color,
    pub card_body: Color,
    pub card_meta: Color,

    pub handle_palette: Vec<Color>,
}

impl Theme {
    pub fn x_dark() -> Self {
        Self {
            name: "x-dark",
            is_dark: true,

            text: rgb(0xe0, 0xde, 0xf4),
            text_muted: rgb(0x90, 0x8c, 0xaa),
            text_dim: rgb(0x6e, 0x6a, 0x86),
            text_faint: rgb(0x52, 0x4f, 0x67),

            border: rgb(0x40, 0x3d, 0x52),
            border_active: X_BLUE,
            card_border: rgb(0x40, 0x3d, 0x52),
            divider: rgb(0x26, 0x23, 0x3a),
            zebra_bg: rgb(0x26, 0x23, 0x3a),
            clock_bg: rgb(0x1f, 0x1d, 0x2e),

            sel_bg_active: rgb(0x26, 0x23, 0x3a),
            sel_bg_inactive: rgb(0x21, 0x20, 0x2e),
            sel_marker_active: X_BLUE,
            sel_marker_inactive: rgb(0x52, 0x4f, 0x67),

            brand_bg: X_BLUE,
            brand_fg: WHITE,

            accent: X_BLUE,
            error: rgb(0xeb, 0x6f, 0x92),
            success: X_RETWEET,
            warning: rgb(0xf6, 0xc1, 0x77),
            info: rgb(0x9c, 0xcf, 0xd8),
            unread_dot: X_RETWEET,
            update: rgb(0xf6, 0xc1, 0x77),
            new_unread: rgb(0xc4, 0xa7, 0xe7),

            like: X_LIKE,
            liked: X_LIKE,
            retweet: X_RETWEET,
            follow: X_BLUE,
            reply_notif: rgb(0xf6, 0xc1, 0x77),
            quote: rgb(0xc4, 0xa7, 0xe7),
            mention: rgb(0x9c, 0xcf, 0xd8),
            milestone: rgb(0xf6, 0xc1, 0x77),

            media_photo: X_BLUE,
            media_video: X_LIKE,
            media_gif: rgb(0xf6, 0xc1, 0x77),
            media_article: X_BLUE,
            media_link: rgb(0x90, 0x8c, 0xaa),
            media_poll: rgb(0xf6, 0xc1, 0x77),
            media_loading: rgb(0x52, 0x4f, 0x67),
            media_failed: rgb(0xeb, 0x6f, 0x92),
            youtube_red: YT_RED,

            hashtag: rgb(0xc4, 0xa7, 0xe7),
            url: X_BLUE,
            verified: X_BLUE,
            translation: rgb(0x9c, 0xcf, 0xd8),
            code: rgb(0xf6, 0xc1, 0x77),

            mode_normal_bg: rgb(0xf6, 0xc1, 0x77),
            mode_normal_fg: rgb(0x19, 0x17, 0x24),
            mode_cmd_bg: rgb(0xc4, 0xa7, 0xe7),
            mode_cmd_fg: rgb(0x19, 0x17, 0x24),
            mode_cmd_cursor: rgb(0xf6, 0xc1, 0x77),
            mode_vim_insert: X_RETWEET,
            mode_vim_normal: rgb(0xf6, 0xc1, 0x77),

            ask_user: rgb(0x9c, 0xcf, 0xd8),
            ask_assistant: rgb(0xc4, 0xa7, 0xe7),
            quote_block: X_BLUE,
            heading: WHITE,

            whisper_quiet: rgb(0x52, 0x4f, 0x67),
            whisper_active: rgb(0xe0, 0xde, 0xf4),
            whisper_surge: rgb(0xf6, 0xc1, 0x77),
            whisper_cooling: rgb(0x52, 0x4f, 0x67),

            card_title: WHITE,
            card_body: rgb(0xc6, 0xc3, 0xdb),
            card_meta: rgb(0x90, 0x8c, 0xaa),

            handle_palette: vec![
                Color::Indexed(39),
                Color::Indexed(45),
                Color::Indexed(51),
                Color::Indexed(48),
                Color::Indexed(82),
                Color::Indexed(118),
                Color::Indexed(154),
                Color::Indexed(226),
                Color::Indexed(220),
                Color::Indexed(214),
                Color::Indexed(208),
                Color::Indexed(203),
                Color::Indexed(198),
                Color::Indexed(205),
                Color::Indexed(213),
                Color::Indexed(177),
                Color::Indexed(141),
                Color::Indexed(105),
                Color::Indexed(75),
                Color::Indexed(80),
            ],
        }
    }

    pub fn x_light() -> Self {
        Self {
            name: "x-light",
            is_dark: false,

            text: rgb(0x07, 0x36, 0x42),
            text_muted: rgb(0x65, 0x7b, 0x83),
            text_dim: rgb(0x83, 0x94, 0x96),
            text_faint: rgb(0x93, 0xa1, 0xa1),

            border: rgb(0x93, 0xa1, 0xa1),
            border_active: X_BLUE,
            card_border: rgb(0x93, 0xa1, 0xa1),
            divider: rgb(0xee, 0xe8, 0xd5),
            zebra_bg: rgb(0xee, 0xe8, 0xd5),
            clock_bg: rgb(0xee, 0xe8, 0xd5),

            sel_bg_active: rgb(0xee, 0xe8, 0xd5),
            sel_bg_inactive: rgb(0xf5, 0xee, 0xd8),
            sel_marker_active: X_BLUE,
            sel_marker_inactive: rgb(0x93, 0xa1, 0xa1),

            brand_bg: X_BLUE,
            brand_fg: WHITE,

            accent: X_BLUE,
            error: rgb(0xdc, 0x32, 0x2f),
            success: X_RETWEET,
            warning: rgb(0xb5, 0x89, 0x00),
            info: rgb(0x2a, 0xa1, 0x98),
            unread_dot: X_RETWEET,
            update: rgb(0xcb, 0x4b, 0x16),
            new_unread: rgb(0x6c, 0x71, 0xc4),

            like: X_LIKE,
            liked: X_LIKE,
            retweet: X_RETWEET,
            follow: X_BLUE,
            reply_notif: rgb(0xb5, 0x89, 0x00),
            quote: rgb(0x6c, 0x71, 0xc4),
            mention: rgb(0x2a, 0xa1, 0x98),
            milestone: rgb(0xb5, 0x89, 0x00),

            media_photo: X_BLUE,
            media_video: X_LIKE,
            media_gif: rgb(0xb5, 0x89, 0x00),
            media_article: X_BLUE,
            media_link: rgb(0x93, 0xa1, 0xa1),
            media_poll: rgb(0xb5, 0x89, 0x00),
            media_loading: rgb(0x93, 0xa1, 0xa1),
            media_failed: rgb(0xdc, 0x32, 0x2f),
            youtube_red: YT_RED,

            hashtag: rgb(0x6c, 0x71, 0xc4),
            url: X_BLUE,
            verified: X_BLUE,
            translation: rgb(0x2a, 0xa1, 0x98),
            code: rgb(0xb5, 0x89, 0x00),

            mode_normal_bg: rgb(0xb5, 0x89, 0x00),
            mode_normal_fg: rgb(0xfd, 0xf6, 0xe3),
            mode_cmd_bg: rgb(0xd3, 0x36, 0x82),
            mode_cmd_fg: rgb(0xfd, 0xf6, 0xe3),
            mode_cmd_cursor: rgb(0xb5, 0x89, 0x00),
            mode_vim_insert: rgb(0x85, 0x99, 0x00),
            mode_vim_normal: rgb(0xb5, 0x89, 0x00),

            ask_user: rgb(0x26, 0x8b, 0xd2),
            ask_assistant: rgb(0xd3, 0x36, 0x82),
            quote_block: X_BLUE,
            heading: rgb(0x07, 0x36, 0x42),

            whisper_quiet: rgb(0x93, 0xa1, 0xa1),
            whisper_active: rgb(0x58, 0x6e, 0x75),
            whisper_surge: rgb(0xb5, 0x89, 0x00),
            whisper_cooling: rgb(0x93, 0xa1, 0xa1),

            card_title: rgb(0x07, 0x36, 0x42),
            card_body: rgb(0x58, 0x6e, 0x75),
            card_meta: rgb(0x65, 0x7b, 0x83),

            handle_palette: vec![
                Color::Indexed(19),
                Color::Indexed(25),
                Color::Indexed(24),
                Color::Indexed(22),
                Color::Indexed(28),
                Color::Indexed(29),
                Color::Indexed(64),
                Color::Indexed(100),
                Color::Indexed(94),
                Color::Indexed(130),
                Color::Indexed(124),
                Color::Indexed(88),
                Color::Indexed(52),
                Color::Indexed(126),
                Color::Indexed(132),
                Color::Indexed(90),
                Color::Indexed(92),
                Color::Indexed(55),
                Color::Indexed(57),
                Color::Indexed(60),
            ],
        }
    }

    pub fn for_mode(is_dark: bool) -> Self {
        if is_dark {
            Self::x_dark()
        } else {
            Self::x_light()
        }
    }

    /// Derives a Mordor-tinted variant from `base`, overriding the cool
    /// blue/pink accents with the image's fiery palette so UI highlights read
    /// naturally over the For You wallpaper. Preserves text, error, and
    /// semantic colors (retweet green, like pink) so engagement glyphs keep
    /// their conventional meaning.
    pub fn mordor_from(base: &Theme) -> Self {
        const FIRE: Color = rgb(0xf4, 0x74, 0x38);
        const EMBER: Color = rgb(0xe8, 0x90, 0x40);
        const FORGE: Color = rgb(0x5c, 0x18, 0x10);
        const GOLD: Color = rgb(0xf4, 0xc0, 0x3f);
        const ASH: Color = rgb(0x2a, 0x1e, 0x1c);
        const ASH_DIM: Color = rgb(0x1f, 0x16, 0x12);
        const WARM_WHITE: Color = rgb(0xfd, 0xe3, 0xb5);

        Self {
            name: "mordor",
            is_dark: true,

            accent: FIRE,
            border_active: FIRE,
            sel_marker_active: FIRE,
            brand_bg: FORGE,
            brand_fg: WARM_WHITE,

            url: EMBER,
            verified: GOLD,
            follow: FIRE,
            hashtag: GOLD,
            mention: EMBER,
            quote: EMBER,
            quote_block: EMBER,

            media_photo: EMBER,
            media_article: EMBER,

            sel_bg_active: ASH,
            sel_bg_inactive: ASH_DIM,
            zebra_bg: ASH_DIM,
            clock_bg: ASH_DIM,
            divider: ASH,

            new_unread: FIRE,
            update: GOLD,
            milestone: GOLD,

            mode_normal_bg: FIRE,
            mode_normal_fg: rgb(0x1a, 0x0c, 0x06),
            mode_cmd_bg: GOLD,
            mode_cmd_fg: rgb(0x1a, 0x0c, 0x06),
            mode_cmd_cursor: FIRE,
            mode_vim_normal: FIRE,

            ask_user: GOLD,
            ask_assistant: EMBER,
            heading: WARM_WHITE,

            ..base.clone()
        }
    }

    pub fn by_name(name: &str, is_dark: bool) -> Option<Self> {
        match name.trim().to_ascii_lowercase().as_str() {
            "x-dark" | "xdark" | "dark" => Some(Self::x_dark()),
            "x-light" | "xlight" | "light" => Some(Self::x_light()),
            "auto" => Some(Self::for_mode(is_dark)),
            _ => None,
        }
    }

    pub fn builtin_names() -> &'static [&'static str] {
        &["auto", "x-dark", "x-light"]
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct ThemeConfig {
    #[serde(default = "default_theme_name")]
    pub name: String,
}

impl Default for ThemeConfig {
    fn default() -> Self {
        Self {
            name: default_theme_name(),
        }
    }
}

fn default_theme_name() -> String {
    "auto".into()
}

static ACTIVE: OnceLock<RwLock<Theme>> = OnceLock::new();

fn cell() -> &'static RwLock<Theme> {
    ACTIVE.get_or_init(|| RwLock::new(Theme::x_dark()))
}

pub fn set_active(theme: Theme) {
    if let Ok(mut guard) = cell().write() {
        *guard = theme;
    }
}

pub fn active() -> RwLockReadGuard<'static, Theme> {
    cell().read().expect("theme lock poisoned")
}

pub fn with<R>(f: impl FnOnce(&Theme) -> R) -> R {
    f(&active())
}

pub fn handle_color(handle: &str) -> Color {
    let mut h: u64 = 0xcbf29ce484222325;
    for b in handle.as_bytes() {
        h ^= b.to_ascii_lowercase() as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    with(|t| t.handle_palette[(h as usize) % t.handle_palette.len()])
}

pub fn parse_color(s: &str) -> Color {
    match s.to_ascii_lowercase().as_str() {
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
            let g = u8::from_str_radix(&hex[3..5], 16).unwrap_or(0);
            let b = u8::from_str_radix(&hex[5..7], 16).unwrap_or(0);
            Color::Rgb(r, g, b)
        }
        idx if idx.parse::<u8>().is_ok() => Color::Indexed(idx.parse().unwrap()),
        _ => Color::Cyan,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn handle_color_is_deterministic() {
        set_active(Theme::x_dark());
        assert_eq!(handle_color("jack"), handle_color("jack"));
    }

    #[test]
    fn by_name_resolves_builtins() {
        assert!(Theme::by_name("x-dark", true).is_some());
        assert!(Theme::by_name("X-LIGHT", false).is_some());
        assert!(Theme::by_name("auto", true).is_some());
        assert!(Theme::by_name("nonsense", true).is_none());
    }

    #[test]
    fn auto_flips_on_mode() {
        let dark = Theme::by_name("auto", true).unwrap();
        let light = Theme::by_name("auto", false).unwrap();
        assert!(dark.is_dark);
        assert!(!light.is_dark);
    }

    #[test]
    fn parse_hex() {
        assert_eq!(parse_color("#1d9bf0"), Color::Rgb(0x1d, 0x9b, 0xf0));
        assert_eq!(parse_color("red"), Color::Red);
        assert_eq!(parse_color("244"), Color::Indexed(244));
    }
}
