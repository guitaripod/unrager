use crate::error::Result;
use crate::tui::app::{DisplayNameStyle, FeedMode, MetricsStyle, ReplySortOrder, TimestampStyle};
use crate::tui::source::SourceKind;
use serde::{Deserialize, Serialize};
use std::path::Path;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionState {
    pub source_kind: SourceKind,
    pub selected: usize,
    #[serde(default)]
    pub metrics: Option<MetricsStyle>,
    #[serde(default)]
    pub display_names: Option<DisplayNameStyle>,
    #[serde(default)]
    pub timestamps: Option<TimestampStyle>,
    #[serde(default)]
    pub feed_mode: Option<FeedMode>,
    #[serde(default)]
    pub reply_sort: Option<ReplySortOrder>,
    #[serde(default)]
    pub whisper_cursor: Option<String>,
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
            metrics: Some(MetricsStyle::Hidden),
            display_names: Some(DisplayNameStyle::Hidden),
            timestamps: Some(TimestampStyle::Absolute),
            feed_mode: Some(FeedMode::Originals),
            reply_sort: Some(ReplySortOrder::Likes),
            whisper_cursor: Some("cursor-abc".into()),
        };
        save(tmp.path(), &state).unwrap();
        let loaded = load(tmp.path()).unwrap();
        assert!(matches!(
            loaded.source_kind,
            SourceKind::Home { following: true }
        ));
        assert_eq!(loaded.selected, 7);
        assert_eq!(loaded.metrics, Some(MetricsStyle::Hidden));
        assert_eq!(loaded.display_names, Some(DisplayNameStyle::Hidden));
    }

    #[test]
    fn roundtrip_user() {
        let tmp = NamedTempFile::new().unwrap();
        let state = SessionState {
            source_kind: SourceKind::User {
                handle: "jack".into(),
            },
            selected: 0,
            metrics: None,
            display_names: None,
            timestamps: None,
            feed_mode: None,
            reply_sort: None,
            whisper_cursor: None,
        };
        save(tmp.path(), &state).unwrap();
        let loaded = load(tmp.path()).unwrap();
        match loaded.source_kind {
            SourceKind::User { handle } => assert_eq!(handle, "jack"),
            _ => panic!("wrong variant"),
        }
    }

    #[test]
    fn roundtrip_notifications() {
        let tmp = NamedTempFile::new().unwrap();
        let state = SessionState {
            source_kind: SourceKind::Notifications,
            selected: 3,
            metrics: None,
            display_names: None,
            timestamps: None,
            feed_mode: None,
            reply_sort: None,
            whisper_cursor: Some("1234567890".into()),
        };
        save(tmp.path(), &state).unwrap();
        let loaded = load(tmp.path()).unwrap();
        assert!(matches!(loaded.source_kind, SourceKind::Notifications));
        assert_eq!(loaded.selected, 3);
    }

    #[test]
    fn missing_file_returns_none() {
        assert!(load(Path::new("/tmp/definitely-not-a-real-file-xyz-9999.json")).is_none());
    }
}
