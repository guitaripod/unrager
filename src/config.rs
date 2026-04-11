use crate::error::{Error, Result};
use directories::ProjectDirs;
use std::path::PathBuf;

pub fn project_dirs() -> Result<ProjectDirs> {
    ProjectDirs::from("", "", "unrager")
        .ok_or_else(|| Error::Config("could not resolve XDG project dirs".into()))
}

pub fn cache_dir() -> Result<PathBuf> {
    let dirs = project_dirs()?;
    let path = dirs.cache_dir().to_path_buf();
    std::fs::create_dir_all(&path)?;
    Ok(path)
}

pub fn config_dir() -> Result<PathBuf> {
    let dirs = project_dirs()?;
    let path = dirs.config_dir().to_path_buf();
    std::fs::create_dir_all(&path)?;
    Ok(path)
}
