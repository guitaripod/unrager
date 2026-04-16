use crate::error::{Error, Result};
use directories::ProjectDirs;
use serde::Deserialize;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Deserialize, Default)]
pub struct AppConfig {
    #[serde(default = "default_browser")]
    pub browser: String,
    #[serde(default)]
    pub query_ids: std::collections::HashMap<String, String>,
}

fn default_browser() -> String {
    "xdg-open".into()
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
        let program = parts.next().unwrap_or("xdg-open");
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
