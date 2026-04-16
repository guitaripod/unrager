use crate::error::Result;
use serde::Deserialize;
use std::path::Path;

const REPO: &str = "guitaripod/unrager";
const CURRENT_VERSION: &str = env!("CARGO_PKG_VERSION");

#[derive(Debug, Deserialize)]
struct GithubRelease {
    tag_name: String,
}

fn http_client() -> reqwest::Client {
    reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .user_agent(format!("unrager/{CURRENT_VERSION}"))
        .build()
        .unwrap_or_default()
}

pub fn current_version() -> &'static str {
    CURRENT_VERSION
}

pub async fn check_latest() -> Result<Option<String>> {
    let client = http_client();
    let release: GithubRelease = client
        .get(format!(
            "https://api.github.com/repos/{REPO}/releases/latest"
        ))
        .send()
        .await?
        .error_for_status()?
        .json()
        .await?;

    let latest = release.tag_name.trim();
    if is_newer(latest, CURRENT_VERSION) {
        Ok(Some(latest.to_string()))
    } else {
        Ok(None)
    }
}

fn detect_target() -> Option<&'static str> {
    match (std::env::consts::OS, std::env::consts::ARCH) {
        ("linux", "x86_64") => Some("x86_64-unknown-linux-gnu"),
        ("linux", "aarch64") => Some("aarch64-unknown-linux-gnu"),
        ("macos", "x86_64") => Some("x86_64-apple-darwin"),
        ("macos", "aarch64") => Some("aarch64-apple-darwin"),
        _ => None,
    }
}

pub async fn perform_update(version: &str) -> Result<()> {
    let target = detect_target()
        .ok_or_else(|| crate::error::Error::Config("unsupported platform for update".into()))?;
    let client = http_client();
    let base = format!("https://github.com/{REPO}/releases/download/{version}");
    let asset = format!("unrager-{version}-{target}.tar.gz");

    let sums_text = client
        .get(format!("{base}/SHA256SUMS"))
        .send()
        .await?
        .error_for_status()?
        .text()
        .await?;

    let expected_hash = sums_text
        .lines()
        .find(|l| l.ends_with(&asset))
        .and_then(|l| l.split_whitespace().next())
        .ok_or_else(|| crate::error::Error::Config(format!("SHA256SUMS has no entry for {asset}")))?
        .to_string();

    let tarball = client
        .get(format!("{base}/{asset}"))
        .send()
        .await?
        .error_for_status()?
        .bytes()
        .await?;

    verify_sha256(&tarball, &expected_hash)?;

    let tmp = tempfile::tempdir()?;
    let tarball_path = tmp.path().join(&asset);
    std::fs::write(&tarball_path, &tarball)?;

    let binary_path = extract_binary_from_tarball(&tarball_path, tmp.path())?;

    self_replace::self_replace(&binary_path)
        .map_err(|e| crate::error::Error::Config(format!("self-replace failed: {e}")))?;

    Ok(())
}

fn verify_sha256(data: &[u8], expected: &str) -> Result<()> {
    use sha2::{Digest, Sha256};
    let actual = hex_encode(&Sha256::digest(data));
    if actual != expected {
        return Err(crate::error::Error::Config(format!(
            "checksum mismatch: expected {expected}, got {actual}"
        )));
    }
    Ok(())
}

fn hex_encode(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        out.push(HEX[(*b >> 4) as usize] as char);
        out.push(HEX[(*b & 0x0f) as usize] as char);
    }
    out
}

fn extract_binary_from_tarball(tarball: &Path, dest_dir: &Path) -> Result<std::path::PathBuf> {
    use std::io::Read;
    let file = std::fs::File::open(tarball)?;
    let gz = flate2::read::GzDecoder::new(file);
    let mut archive = tar::Archive::new(gz);
    for entry in archive.entries()? {
        let mut entry = entry?;
        let entry_path = entry.path()?;
        if entry_path.file_name().and_then(|n| n.to_str()) == Some("unrager") {
            let out_path = dest_dir.join("unrager");
            let mut buf = Vec::new();
            entry.read_to_end(&mut buf)?;
            std::fs::write(&out_path, &buf)?;
            return Ok(out_path);
        }
    }
    Err(crate::error::Error::Config(
        "binary not found in tarball".into(),
    ))
}

fn is_newer(latest: &str, current: &str) -> bool {
    let parse = |v: &str| -> Option<(u32, u32, u32)> {
        let mut parts = v.split('.');
        Some((
            parts.next()?.parse().ok()?,
            parts.next()?.parse().ok()?,
            parts.next()?.parse().ok()?,
        ))
    };
    match (parse(latest), parse(current)) {
        (Some(l), Some(c)) => l > c,
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn newer_version_detected() {
        assert!(is_newer("1.0.0", "0.9.2"));
        assert!(is_newer("0.10.0", "0.9.2"));
        assert!(is_newer("0.9.3", "0.9.2"));
    }

    #[test]
    fn same_or_older_not_newer() {
        assert!(!is_newer("0.9.2", "0.9.2"));
        assert!(!is_newer("0.9.1", "0.9.2"));
        assert!(!is_newer("0.8.0", "0.9.2"));
    }
}
