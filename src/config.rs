use crate::error::{Error, Result};
use crate::tui::theme::ThemeConfig;
use directories::ProjectDirs;
use serde::Deserialize;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Deserialize, Default)]
pub struct AppConfig {
    #[serde(default = "default_browser")]
    pub browser: String,
    #[serde(default)]
    pub query_ids: std::collections::HashMap<String, String>,
    #[serde(default)]
    pub clock: ClockConfig,
    #[serde(default)]
    pub theme: ThemeConfig,
    #[serde(default)]
    pub sound: SoundConfig,
}

/// Mordor-mode audio configuration. Only `source` is required. When a
/// valid source is present AND `ffmpeg` is on `$PATH`, `sound::Player`
/// slices/fades/downmixes the file into a small Opus loop under
/// `~/.cache/unrager/`. Everything else degrades gracefully.
#[derive(Debug, Clone, Deserialize, Default)]
pub struct SoundConfig {
    pub source: Option<String>,
    #[serde(default)]
    pub start: Option<String>,
    #[serde(default)]
    pub end: Option<String>,
    #[serde(default)]
    pub duration: Option<f32>,
    #[serde(default = "default_fade_ms")]
    pub fade_ms: u32,
    #[serde(default = "default_volume")]
    pub volume: f32,
}

fn default_fade_ms() -> u32 {
    50
}

fn default_volume() -> f32 {
    0.5
}

#[derive(Debug, Clone, Deserialize)]
pub struct ClockConfig {
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default)]
    pub position: ClockPosition,
    #[serde(default = "default_true")]
    pub show_time: bool,
    #[serde(default = "default_true")]
    pub show_date: bool,
    #[serde(default)]
    pub show_seconds: bool,
    #[serde(default)]
    pub hour_format: HourFormat,
    #[serde(default)]
    pub date_format: DateFormatSetting,
    #[serde(default = "default_accent")]
    pub accent: String,
    #[serde(default = "default_true")]
    pub border: bool,
}

impl Default for ClockConfig {
    fn default() -> Self {
        Self {
            enabled: default_true(),
            position: ClockPosition::default(),
            show_time: default_true(),
            show_date: default_true(),
            show_seconds: false,
            hour_format: HourFormat::default(),
            date_format: DateFormatSetting::default(),
            accent: default_accent(),
            border: default_true(),
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, Default, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum HourFormat {
    #[default]
    Auto,
    H24,
    H12,
}

/// Either a literal strftime string (e.g. `"%a %d %b"`) or the sentinel
/// `"auto"`, which lets the renderer pick a locale-appropriate format.
#[derive(Debug, Clone, Deserialize)]
#[serde(untagged)]
pub enum DateFormatSetting {
    Literal(String),
}

impl Default for DateFormatSetting {
    fn default() -> Self {
        Self::Literal("auto".into())
    }
}

impl DateFormatSetting {
    pub fn as_str(&self) -> &str {
        match self {
            Self::Literal(s) => s.as_str(),
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, Default, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ClockPosition {
    TopLeft,
    TopRight,
    BottomLeft,
    BottomRight,
    Header,
    #[default]
    Footer,
}

fn default_true() -> bool {
    true
}

fn default_accent() -> String {
    "cyan".into()
}

/// Platform-native "open a URL or path in the default app" command.
/// `xdg-open` doesn't exist on macOS; `open` doesn't exist on Linux.
#[cfg(target_os = "macos")]
pub const fn default_opener() -> &'static str {
    "open"
}

#[cfg(not(target_os = "macos"))]
pub const fn default_opener() -> &'static str {
    "xdg-open"
}

fn default_browser() -> String {
    default_opener().into()
}

impl AppConfig {
    pub fn load(config_dir: &Path) -> Self {
        let path = config_dir.join("config.toml");
        let Ok(raw) = std::fs::read_to_string(&path) else {
            return Self::default();
        };
        match toml::from_str(&raw) {
            Ok(cfg) => cfg,
            Err(e) => {
                tracing::warn!("failed to parse config.toml: {e} — using defaults");
                Self::default()
            }
        }
    }

    pub fn browser_parts(&self) -> (&str, Vec<&str>) {
        let mut parts = self.browser.split_whitespace();
        let program = parts.next().unwrap_or(default_opener());
        let args: Vec<&str> = parts.collect();
        (program, args)
    }

    pub fn has_url_placeholder(&self) -> bool {
        self.browser.contains("{}")
    }
}

pub fn project_dirs() -> Result<ProjectDirs> {
    ProjectDirs::from("", "", "unrager")
        .ok_or_else(|| Error::Config("could not resolve XDG project dirs".into()))
}

pub fn cache_dir() -> Result<PathBuf> {
    let path = project_dirs()?.cache_dir().to_path_buf();
    ensure_private_dir(&path)?;
    Ok(path)
}

pub fn config_dir() -> Result<PathBuf> {
    let path = project_dirs()?.config_dir().to_path_buf();
    ensure_private_dir(&path)?;
    Ok(path)
}

fn ensure_private_dir(path: &Path) -> Result<()> {
    std::fs::create_dir_all(path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let meta = std::fs::metadata(path)?;
        let mut perms = meta.permissions();
        if perms.mode() & 0o777 != 0o700 {
            perms.set_mode(0o700);
            std::fs::set_permissions(path, perms)?;
        }
    }
    Ok(())
}
