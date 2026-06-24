//! Client-side preferences, the Linux/XDG analog of
//! `UnragerKit/Support/AppSettings.swift`. The server owns source/seen/filter
//! *state*; this only holds what the client decides — where the server is and
//! how the UI looks. Persisted as TOML at
//! `~/.config/unrager-gtk/config.toml` (distinct from the TUI's
//! `~/.config/unrager/session.json`).

use directories::ProjectDirs;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use url::Url;

const DEFAULT_SERVER: &str = "http://localhost:7777";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AppearanceMode {
    #[default]
    System,
    Light,
    Dark,
}

impl AppearanceMode {
    pub const ALL: [AppearanceMode; 3] = [Self::System, Self::Light, Self::Dark];

    pub fn title(self) -> &'static str {
        match self {
            Self::System => "System",
            Self::Light => "Light",
            Self::Dark => "Dark",
        }
    }
}

/// A stepped text-size multiplier applied across every font the app renders.
/// `Standard` is the unscaled default; multipliers match the Apple apps exactly.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FontScale {
    Small,
    #[default]
    Standard,
    Large,
    XLarge,
    XxLarge,
}

impl FontScale {
    pub const ALL: [FontScale; 5] = [
        Self::Small,
        Self::Standard,
        Self::Large,
        Self::XLarge,
        Self::XxLarge,
    ];

    pub fn multiplier(self) -> f64 {
        match self {
            Self::Small => 0.85,
            Self::Standard => 1.0,
            Self::Large => 1.15,
            Self::XLarge => 1.3,
            Self::XxLarge => 1.5,
        }
    }

    pub fn title(self) -> &'static str {
        match self {
            Self::Small => "S",
            Self::Standard => "M",
            Self::Large => "L",
            Self::XLarge => "XL",
            Self::XxLarge => "XXL",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct NotificationSettings {
    pub banners_enabled: bool,
    pub last_seen_id: String,
    pub last_seen_timestamp: f64,
}

impl Default for NotificationSettings {
    fn default() -> Self {
        Self {
            banners_enabled: false,
            last_seen_id: String::new(),
            last_seen_timestamp: 0.0,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct AppSettings {
    pub server_url: String,
    pub appearance: AppearanceMode,
    pub font_scale: FontScale,
    pub images_enabled: bool,
    pub filter_enabled: bool,
    pub track_seen: bool,
    pub notifications: NotificationSettings,
}

impl Default for AppSettings {
    fn default() -> Self {
        Self {
            server_url: default_server_url().to_string(),
            appearance: AppearanceMode::System,
            font_scale: FontScale::Standard,
            images_enabled: true,
            filter_enabled: false,
            track_seen: true,
            notifications: NotificationSettings::default(),
        }
    }
}

impl AppSettings {
    pub fn config_dir() -> Option<PathBuf> {
        ProjectDirs::from("ml", "rawdog", "unrager-gtk").map(|d| d.config_dir().to_path_buf())
    }

    pub fn config_path() -> Option<PathBuf> {
        Self::config_dir().map(|d| d.join("config.toml"))
    }

    /// Loads settings, falling back to defaults if the file is missing or
    /// unparseable so the client always has a usable config.
    pub fn load() -> Self {
        let Some(path) = Self::config_path() else {
            return Self::default();
        };
        match std::fs::read_to_string(&path) {
            Ok(text) => toml::from_str(&text).unwrap_or_else(|e| {
                tracing::warn!(target: "settings", "config parse failed, using defaults: {e}");
                Self::default()
            }),
            Err(_) => Self::default(),
        }
    }

    /// Atomically persists settings (temp file + rename) so a crash mid-write
    /// can't corrupt the config.
    pub fn save(&self) -> std::io::Result<()> {
        let path = Self::config_path()
            .ok_or_else(|| std::io::Error::other("no config directory available"))?;
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let text = toml::to_string_pretty(self)
            .map_err(|e| std::io::Error::other(format!("serialize settings: {e}")))?;
        let tmp = path.with_extension("toml.tmp");
        std::fs::write(&tmp, text)?;
        std::fs::rename(&tmp, &path)
    }

    /// The normalized base URL; falls back to the default if the stored string
    /// is unparseable, so the client never ends up with no server.
    pub fn server_url(&self) -> Url {
        normalize_server_url(&self.server_url).unwrap_or_else(default_server_url)
    }
}

/// The fallback server: a `UNRAGER_DEFAULT_SERVER` env var if it's a valid URL
/// (lets a build ship pointed at a Tailscale address), else localhost.
pub fn default_server_url() -> Url {
    if let Ok(configured) = std::env::var("UNRAGER_DEFAULT_SERVER")
        && let Some(url) = normalize_server_url(&configured)
    {
        return url;
    }
    Url::parse(DEFAULT_SERVER).expect("default server URL is valid")
}

fn normalize_server_url(raw: &str) -> Option<Url> {
    let trimmed = raw.trim();
    let url = Url::parse(trimmed).ok()?;
    if url.has_host() && !url.scheme().is_empty() {
        Some(url)
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn font_scale_multipliers_match_apple() {
        assert_eq!(FontScale::Small.multiplier(), 0.85);
        assert_eq!(FontScale::Standard.multiplier(), 1.0);
        assert_eq!(FontScale::Large.multiplier(), 1.15);
        assert_eq!(FontScale::XLarge.multiplier(), 1.3);
        assert_eq!(FontScale::XxLarge.multiplier(), 1.5);
    }

    #[test]
    fn defaults_are_sane() {
        let s = AppSettings::default();
        assert!(s.images_enabled);
        assert!(!s.filter_enabled);
        assert!(s.track_seen);
        assert_eq!(s.appearance, AppearanceMode::System);
        assert_eq!(s.font_scale, FontScale::Standard);
        assert!(s.server_url().has_host());
    }

    #[test]
    fn invalid_server_url_falls_back_to_default() {
        let s = AppSettings {
            server_url: "not a url".to_string(),
            ..Default::default()
        };
        assert_eq!(s.server_url(), default_server_url());
    }

    #[test]
    fn server_url_trims_whitespace() {
        let s = AppSettings {
            server_url: "  http://example.com:9000  ".to_string(),
            ..Default::default()
        };
        assert_eq!(s.server_url().as_str(), "http://example.com:9000/");
    }

    #[test]
    fn partial_toml_fills_defaults() {
        let toml = r#"server_url = "http://host:1234""#;
        let s: AppSettings = toml::from_str(toml).unwrap();
        assert_eq!(s.server_url().as_str(), "http://host:1234/");
        assert!(s.images_enabled);
        assert_eq!(s.font_scale, FontScale::Standard);
    }

    #[test]
    fn font_scale_serializes_snake_case() {
        let toml = toml::to_string(&FontScaleHolder {
            scale: FontScale::XxLarge,
        })
        .unwrap();
        assert!(toml.contains("\"xx_large\""), "got: {toml}");
    }

    #[derive(Serialize)]
    struct FontScaleHolder {
        scale: FontScale,
    }
}
