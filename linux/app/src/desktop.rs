//! Desktop integration. The compositor shows a window's icon by matching its
//! Wayland app-id (our `ml.rawdog.unrager`) to a `.desktop` launcher and an
//! icon in the hicolor theme — neither of which a bare `cargo run` provides. So
//! on every launch we install the bundled unrager icon and a launcher into the
//! user's XDG data dir (idempotent: only writes when the bytes differ), and the
//! app sets it as the GTK default icon. Without this the window falls back to a
//! generic placeholder.

use std::fs;
use std::path::{Path, PathBuf};

pub const APP_ID: &str = "ml.rawdog.unrager";

const ICONS: &[(u32, &[u8])] = &[
    (64, include_bytes!("../data/icons/unrager-64.png")),
    (128, include_bytes!("../data/icons/unrager-128.png")),
    (256, include_bytes!("../data/icons/unrager-256.png")),
    (512, include_bytes!("../data/icons/unrager-512.png")),
];

/// Installs the icon (several sizes) into `hicolor` and a `.desktop` launcher
/// so the window picks up the unrager icon. Best-effort; failures only warn.
pub fn install() {
    let Some(data) = data_home() else {
        return;
    };

    for (size, bytes) in ICONS {
        let path = data
            .join("icons/hicolor")
            .join(format!("{size}x{size}"))
            .join("apps")
            .join(format!("{APP_ID}.png"));
        write_if_changed(&path, bytes);
    }

    let exec = std::env::current_exe()
        .ok()
        .and_then(|p| p.to_str().map(str::to_string))
        .unwrap_or_else(|| "unrager-gtk".to_string());
    let desktop = format!(
        "[Desktop Entry]\n\
         Type=Application\n\
         Name=Unrager\n\
         Comment=A calm reader for X\n\
         Exec={exec}\n\
         Icon={APP_ID}\n\
         Terminal=false\n\
         Categories=Network;\n\
         StartupNotify=true\n\
         StartupWMClass={APP_ID}\n"
    );
    let desktop_path = data.join("applications").join(format!("{APP_ID}.desktop"));
    write_if_changed(&desktop_path, desktop.as_bytes());
}

fn data_home() -> Option<PathBuf> {
    std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".local/share")))
}

/// Writes `bytes` to `path` only when it isn't already identical — so a normal
/// launch doesn't needlessly rewrite files (or churn the icon cache).
fn write_if_changed(path: &Path, bytes: &[u8]) {
    if fs::read(path).is_ok_and(|existing| existing == bytes) {
        return;
    }
    if let Some(dir) = path.parent() {
        let _ = fs::create_dir_all(dir);
    }
    if let Err(error) = fs::write(path, bytes) {
        tracing::warn!(target: "ui", "desktop integration: write {} failed: {error}", path.display());
    }
}
