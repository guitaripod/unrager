use crate::error::{Error, Result};
use std::sync::OnceLock;

static STATUS_ID_RE: OnceLock<regex::Regex> = OnceLock::new();

fn status_id_re() -> &'static regex::Regex {
    STATUS_ID_RE.get_or_init(|| regex::Regex::new(r"/status/(\d{1,25})").expect("status id regex"))
}

pub fn short_count(n: u64) -> String {
    // 999_950+ would render as "1000.0K"; promote it so it reads "1.0M".
    if n >= 999_950 {
        format!("{:.1}M", n as f64 / 1_000_000.0)
    } else if n >= 1_000 {
        format!("{:.1}K", n as f64 / 1_000.0)
    } else {
        n.to_string()
    }
}

pub fn parse_tweet_ref(raw: &str) -> Result<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err(Error::BadTweetRef(raw.to_string()));
    }

    if trimmed.chars().all(|c| c.is_ascii_digit()) && (1..=25).contains(&trimmed.len()) {
        return Ok(trimmed.to_string());
    }

    if let Some(cap) = status_id_re().captures(trimmed) {
        return Ok(cap[1].to_string());
    }

    Err(Error::BadTweetRef(raw.to_string()))
}

/// Replaces `path` with `bytes` all at once: they go to a sibling temp file
/// that is then renamed over the target, so a crash mid-write leaves the old
/// file rather than half of the new one. A symlink is followed, even one
/// whose target doesn't exist yet, so the file it points at is written and
/// the link survives, and the file keeps its permissions (a `filter.toml`
/// holding an API key stays private).
pub fn write_atomic(path: &std::path::Path, bytes: &[u8]) -> std::io::Result<()> {
    let target = resolve_link(path);
    if let Some(parent) = target.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let mut tmp_name = target.file_name().unwrap_or_default().to_os_string();
    tmp_name.push(".tmp");
    let tmp = target.with_file_name(tmp_name);
    std::fs::write(&tmp, bytes)?;
    if let Ok(existing) = std::fs::metadata(&target) {
        std::fs::set_permissions(&tmp, existing.permissions())?;
    }
    std::fs::rename(&tmp, &target)
}

/// The file `path` stands for: itself, or where its symlinks lead, as far as
/// they go when the last one points at nothing yet.
fn resolve_link(path: &std::path::Path) -> std::path::PathBuf {
    if let Ok(real) = std::fs::canonicalize(path) {
        return real;
    }
    let mut current = path.to_path_buf();
    for _ in 0..40 {
        let Ok(next) = std::fs::read_link(&current) else {
            break;
        };
        current = match current.parent() {
            Some(parent) => parent.join(next),
            None => next,
        };
    }
    current
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn raw_numeric_id() {
        assert_eq!(
            parse_tweet_ref("1234567890123456789").unwrap(),
            "1234567890123456789"
        );
    }

    #[test]
    fn x_com_url() {
        assert_eq!(
            parse_tweet_ref("https://x.com/foo/status/1234567890123456789").unwrap(),
            "1234567890123456789"
        );
    }

    #[test]
    fn twitter_com_url_with_query() {
        assert_eq!(
            parse_tweet_ref("https://twitter.com/foo/status/9876543210?s=20&t=abc").unwrap(),
            "9876543210"
        );
    }

    #[test]
    fn short_numeric_id() {
        assert_eq!(parse_tweet_ref("20").unwrap(), "20");
    }

    #[test]
    fn rejects_garbage() {
        assert!(parse_tweet_ref("").is_err());
        assert!(parse_tweet_ref("not a tweet").is_err());
    }

    #[test]
    fn short_count_below_thousand() {
        assert_eq!(short_count(0), "0");
        assert_eq!(short_count(1), "1");
        assert_eq!(short_count(999), "999");
    }

    #[test]
    fn short_count_thousands() {
        assert_eq!(short_count(1000), "1.0K");
        assert_eq!(short_count(1500), "1.5K");
        assert_eq!(short_count(999_499), "999.5K");
    }

    #[test]
    fn short_count_millions() {
        assert_eq!(short_count(1_000_000), "1.0M");
        assert_eq!(short_count(1_500_000), "1.5M");
        assert_eq!(short_count(42_300_000), "42.3M");
        assert_eq!(short_count(999_999), "1.0M");
    }

    #[test]
    fn write_atomic_replaces_the_file_and_leaves_no_temp_behind() {
        let dir = tempfile::TempDir::new().unwrap();
        let path = dir.path().join("nested").join("state.json");
        write_atomic(&path, b"one").unwrap();
        write_atomic(&path, b"two").unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), b"two");
        let names: Vec<_> = std::fs::read_dir(path.parent().unwrap())
            .unwrap()
            .map(|e| e.unwrap().file_name())
            .collect();
        assert_eq!(names, vec![std::ffi::OsString::from("state.json")]);
    }

    #[cfg(unix)]
    #[test]
    fn write_atomic_keeps_a_symlink_pointing_at_the_new_contents() {
        let dir = tempfile::TempDir::new().unwrap();
        let real = dir.path().join("real.toml");
        let link = dir.path().join("link.toml");
        std::fs::write(&real, b"old").unwrap();
        std::os::unix::fs::symlink(&real, &link).unwrap();
        write_atomic(&link, b"new").unwrap();
        assert!(
            std::fs::symlink_metadata(&link)
                .unwrap()
                .file_type()
                .is_symlink()
        );
        assert_eq!(std::fs::read(&real).unwrap(), b"new");
    }

    #[cfg(unix)]
    #[test]
    fn write_atomic_writes_through_a_link_to_a_file_not_made_yet() {
        let dir = tempfile::TempDir::new().unwrap();
        let link = dir.path().join("filter.toml");
        std::os::unix::fs::symlink("dotfiles/filter.toml", &link).unwrap();
        write_atomic(&link, b"rules").unwrap();
        assert!(
            std::fs::symlink_metadata(&link)
                .unwrap()
                .file_type()
                .is_symlink()
        );
        assert_eq!(
            std::fs::read(dir.path().join("dotfiles/filter.toml")).unwrap(),
            b"rules"
        );
    }

    #[cfg(unix)]
    #[test]
    fn write_atomic_keeps_a_private_file_private() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::TempDir::new().unwrap();
        let path = dir.path().join("filter.toml");
        std::fs::write(&path, b"api_key = \"secret\"").unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        write_atomic(&path, b"api_key = \"rotated\"").unwrap();
        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
    }
}
