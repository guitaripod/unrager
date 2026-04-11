use crate::error::{Error, Result};
use directories::ProjectDirs;
use std::path::{Path, PathBuf};

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
