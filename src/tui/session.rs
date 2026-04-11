use crate::error::Result;
use crate::tui::source::SourceKind;
use serde::{Deserialize, Serialize};
use std::path::Path;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionState {
    pub source_kind: SourceKind,
    pub selected: usize,
}

pub fn load(path: &Path) -> Option<SessionState> {
    let bytes = std::fs::read(path).ok()?;
    serde_json::from_slice(&bytes).ok()
}

pub fn save(path: &Path, state: &SessionState) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, serde_json::to_vec_pretty(state)?)?;
    std::fs::rename(&tmp, path)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::NamedTempFile;

    #[test]
    fn roundtrip_home() {
        let tmp = NamedTempFile::new().unwrap();
        let state = SessionState {
            source_kind: SourceKind::Home { following: true },
            selected: 7,
        };
        save(tmp.path(), &state).unwrap();
        let loaded = load(tmp.path()).unwrap();
        assert!(matches!(
            loaded.source_kind,
            SourceKind::Home { following: true }
        ));
        assert_eq!(loaded.selected, 7);
    }

    #[test]
    fn roundtrip_user() {
        let tmp = NamedTempFile::new().unwrap();
        let state = SessionState {
            source_kind: SourceKind::User {
                handle: "jack".into(),
            },
            selected: 0,
        };
        save(tmp.path(), &state).unwrap();
        let loaded = load(tmp.path()).unwrap();
        match loaded.source_kind {
            SourceKind::User { handle } => assert_eq!(handle, "jack"),
            _ => panic!("wrong variant"),
        }
    }

    #[test]
    fn missing_file_returns_none() {
        assert!(load(Path::new("/tmp/definitely-not-a-real-file-xyz-9999.json")).is_none());
    }
}
