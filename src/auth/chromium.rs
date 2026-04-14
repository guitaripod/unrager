use crate::error::{Error, Result};
use aes::Aes128;
use cbc::cipher::{BlockDecryptMut, KeyIvInit, block_padding::Pkcs7};
use directories::BaseDirs;
use hmac::Hmac;
use rusqlite::{Connection, OpenFlags};
use sha1::Sha1;
use std::path::{Path, PathBuf};

use super::XSession;

#[cfg(target_os = "linux")]
use super::linux as backend;
#[cfg(target_os = "macos")]
use super::macos as backend;

type Aes128CbcDec = cbc::Decryptor<Aes128>;

const COOKIES_PATH_ENV: &str = "UNRAGER_COOKIES_PATH";
const PBKDF2_SALT: &[u8] = b"saltysalt";
const PBKDF2_KEY_LEN: usize = 16;
const AES_IV: [u8; 16] = [0x20; 16];
const INTEGRITY_PREFIX_LEN: usize = 32;

const COOKIE_NAMES: &[&str] = &["auth_token", "ct0", "twid"];

pub struct Browser {
    pub label: &'static str,
    pub linux_roots: &'static [&'static str],
    pub macos_roots: &'static [&'static str],
    pub macos_keychain_service: &'static str,
    pub macos_keychain_account: &'static str,
}

const BROWSERS: &[Browser] = &[
    Browser {
        label: "Vivaldi",
        linux_roots: &["vivaldi", "vivaldi-snapshot"],
        macos_roots: &["Vivaldi", "Vivaldi Snapshot"],
        macos_keychain_service: "Vivaldi Safe Storage",
        macos_keychain_account: "Vivaldi",
    },
    Browser {
        label: "Chrome",
        linux_roots: &[
            "google-chrome",
            "google-chrome-beta",
            "google-chrome-unstable",
        ],
        macos_roots: &[
            "Google/Chrome",
            "Google/Chrome Beta",
            "Google/Chrome Dev",
            "Google/Chrome Canary",
        ],
        macos_keychain_service: "Chrome Safe Storage",
        macos_keychain_account: "Chrome",
    },
    Browser {
        label: "Chromium",
        linux_roots: &["chromium"],
        macos_roots: &["Chromium"],
        macos_keychain_service: "Chromium Safe Storage",
        macos_keychain_account: "Chromium",
    },
    Browser {
        label: "Brave",
        linux_roots: &[
            "BraveSoftware/Brave-Browser",
            "BraveSoftware/Brave-Browser-Beta",
            "BraveSoftware/Brave-Browser-Nightly",
        ],
        macos_roots: &[
            "BraveSoftware/Brave-Browser",
            "BraveSoftware/Brave-Browser-Beta",
            "BraveSoftware/Brave-Browser-Nightly",
        ],
        macos_keychain_service: "Brave Safe Storage",
        macos_keychain_account: "Brave",
    },
    Browser {
        label: "Microsoft Edge",
        linux_roots: &[
            "microsoft-edge",
            "microsoft-edge-beta",
            "microsoft-edge-dev",
            "microsoft-edge-canary",
        ],
        macos_roots: &[
            "Microsoft Edge",
            "Microsoft Edge Beta",
            "Microsoft Edge Dev",
            "Microsoft Edge Canary",
        ],
        macos_keychain_service: "Microsoft Edge Safe Storage",
        macos_keychain_account: "Microsoft Edge",
    },
    Browser {
        label: "Opera",
        linux_roots: &["opera"],
        macos_roots: &[
            "com.operasoftware.Opera",
            "com.operasoftware.OperaDeveloper",
            "com.operasoftware.OperaNext",
        ],
        macos_keychain_service: "Opera Safe Storage",
        macos_keychain_account: "Opera",
    },
    Browser {
        label: "Arc",
        linux_roots: &[],
        macos_roots: &["Arc/User Data"],
        macos_keychain_service: "Arc Safe Storage",
        macos_keychain_account: "Arc",
    },
];

pub async fn load_session() -> Result<XSession> {
    if let Some(cached) = load_cached_session() {
        tracing::debug!("using cached session");
        return Ok(cached);
    }

    let session = extract_session_from_browser().await?;
    save_cached_session(&session);
    Ok(session)
}

fn session_cache_path() -> Option<PathBuf> {
    Some(crate::config::cache_dir().ok()?.join("session-cache.json"))
}

fn load_cached_session() -> Option<XSession> {
    let path = session_cache_path()?;
    let meta = std::fs::metadata(&path).ok()?;
    let age = meta.modified().ok()?.elapsed().ok()?;
    if age > std::time::Duration::from_secs(24 * 3600) {
        tracing::debug!(
            "session cache too old ({:.0}h), re-extracting",
            age.as_secs_f64() / 3600.0
        );
        return None;
    }
    let bytes = std::fs::read(&path).ok()?;
    serde_json::from_slice(&bytes).ok()
}

fn save_cached_session(session: &XSession) {
    let Some(path) = session_cache_path() else {
        return;
    };
    if let Ok(json) = serde_json::to_vec(session) {
        let tmp = path.with_extension("json.tmp");
        if std::fs::write(&tmp, &json).is_ok() {
            let _ = std::fs::rename(&tmp, &path);
        }
    }
}

async fn extract_session_from_browser() -> Result<XSession> {
    let candidates = candidate_paths()?;
    tracing::debug!("checking {} candidate cookie paths", candidates.len());

    let mut tried = Vec::new();
    for Candidate { browser, path } in &candidates {
        if !path.exists() {
            continue;
        }
        tried.push(format!("{} ({})", browser.label, path.display()));
        let encrypted = match read_encrypted_cookies(path) {
            Ok(rows) if rows.len() == COOKIE_NAMES.len() => rows,
            Ok(_) => {
                tracing::debug!("{} {} has no .x.com session", browser.label, path.display());
                continue;
            }
            Err(e) => {
                tracing::debug!(
                    "{} {} cookies unreadable: {e}",
                    browser.label,
                    path.display()
                );
                continue;
            }
        };
        let passwords = backend::candidate_passwords(browser).await;
        if passwords.is_empty() {
            tracing::debug!("{} has no candidate passwords", browser.label);
            continue;
        }
        match decrypt_all(&encrypted, &passwords) {
            Ok(session) => {
                tracing::debug!("loaded session from {} {}", browser.label, path.display());
                return Ok(session);
            }
            Err(e) => {
                tracing::debug!("{} {} decrypt failed: {e}", browser.label, path.display());
            }
        }
    }

    if tried.is_empty() {
        Err(Error::CookieStoreMissing)
    } else {
        Err(Error::NotLoggedIn)
    }
}

struct Candidate {
    browser: &'static Browser,
    path: PathBuf,
}

pub struct ProbeResult {
    pub browser: &'static str,
    pub path: PathBuf,
    pub has_x_session: bool,
}

pub fn probe() -> Result<Vec<ProbeResult>> {
    let mut out = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for Candidate { browser, path } in candidate_paths()? {
        if !path.exists() || !seen.insert(path.clone()) {
            continue;
        }
        let has_x_session = matches!(
            read_encrypted_cookies(&path),
            Ok(rows) if rows.len() == COOKIE_NAMES.len()
        );
        out.push(ProbeResult {
            browser: browser.label,
            path,
            has_x_session,
        });
    }
    Ok(out)
}

fn candidate_paths() -> Result<Vec<Candidate>> {
    if let Some(override_path) = std::env::var_os(COOKIES_PATH_ENV) {
        return Ok(vec![Candidate {
            browser: &BROWSERS[0],
            path: PathBuf::from(override_path),
        }]);
    }

    let base = BaseDirs::new().ok_or_else(|| Error::Config("HOME not set".into()))?;
    let config = base.config_dir();

    let mut out = Vec::new();
    for browser in BROWSERS {
        let roots = browser_roots(browser);
        for root in roots {
            let root_path = config.join(root);
            if !root_path.exists() {
                continue;
            }
            for profile in profile_dirs(&root_path) {
                for rel in ["Network/Cookies", "Cookies"] {
                    out.push(Candidate {
                        browser,
                        path: profile.join(rel),
                    });
                }
            }
        }
    }
    Ok(out)
}

fn browser_roots(browser: &Browser) -> &'static [&'static str] {
    #[cfg(target_os = "linux")]
    {
        browser.linux_roots
    }
    #[cfg(target_os = "macos")]
    {
        browser.macos_roots
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    {
        &[]
    }
}

fn profile_dirs(root: &Path) -> Vec<PathBuf> {
    let mut out = vec![root.to_path_buf(), root.join("Default")];
    if let Ok(entries) = std::fs::read_dir(root) {
        for entry in entries.flatten() {
            let name = entry.file_name();
            let Some(name) = name.to_str() else { continue };
            if name.starts_with("Profile ") {
                out.push(entry.path());
            }
        }
    }
    out
}

fn read_encrypted_cookies(path: &Path) -> Result<Vec<(String, Vec<u8>)>> {
    let tmp = tempfile::NamedTempFile::new()?;
    std::fs::copy(path, tmp.path())?;

    let conn = Connection::open_with_flags(
        tmp.path(),
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;

    let placeholders = COOKIE_NAMES
        .iter()
        .map(|_| "?")
        .collect::<Vec<_>>()
        .join(",");
    let query = format!(
        "SELECT name, encrypted_value FROM cookies \
         WHERE host_key = '.x.com' AND name IN ({placeholders})"
    );

    let mut stmt = conn.prepare(&query)?;
    let params: Vec<&dyn rusqlite::ToSql> = COOKIE_NAMES
        .iter()
        .map(|n| n as &dyn rusqlite::ToSql)
        .collect();

    let rows = stmt.query_map(params.as_slice(), |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, Vec<u8>>(1)?))
    })?;

    let mut out = Vec::with_capacity(COOKIE_NAMES.len());
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

fn decrypt_all(encrypted: &[(String, Vec<u8>)], passwords: &[Vec<u8>]) -> Result<XSession> {
    let mut winning_key: Option<[u8; PBKDF2_KEY_LEN]> = None;
    let mut auth_token = None;
    let mut ct0 = None;
    let mut twid = None;

    for (name, ciphertext) in encrypted {
        let plain = match winning_key {
            Some(key) => decrypt_and_extract(ciphertext, &key)?,
            None => {
                let (key, plain) = try_all(ciphertext, passwords)?;
                winning_key = Some(key);
                plain
            }
        };
        match name.as_str() {
            "auth_token" => auth_token = Some(plain),
            "ct0" => ct0 = Some(plain),
            "twid" => twid = Some(plain),
            _ => {}
        }
    }

    match (auth_token, ct0, twid) {
        (Some(auth_token), Some(ct0), Some(twid)) => Ok(XSession {
            auth_token,
            ct0,
            twid,
        }),
        _ => Err(Error::NotLoggedIn),
    }
}

fn derive_key(password: &[u8]) -> Option<[u8; PBKDF2_KEY_LEN]> {
    let mut key = [0u8; PBKDF2_KEY_LEN];
    pbkdf2::pbkdf2::<Hmac<Sha1>>(password, PBKDF2_SALT, backend::ITERS, &mut key).ok()?;
    Some(key)
}

fn try_all(encrypted: &[u8], passwords: &[Vec<u8>]) -> Result<([u8; PBKDF2_KEY_LEN], String)> {
    let mut last_err = Error::CookieDecrypt("no candidate keys produced a valid plaintext");
    for password in passwords {
        let Some(key) = derive_key(password) else {
            continue;
        };
        match decrypt_and_extract(encrypted, &key) {
            Ok(text) => return Ok((key, text)),
            Err(e) => last_err = e,
        }
    }
    Err(last_err)
}

fn decrypt_and_extract(encrypted: &[u8], key: &[u8; PBKDF2_KEY_LEN]) -> Result<String> {
    let plain = decrypt_aes_cbc(encrypted, key)?;

    if !plain.is_empty() && is_printable(&plain) {
        return Ok(String::from_utf8_lossy(&plain).into_owned());
    }

    if plain.len() > INTEGRITY_PREFIX_LEN && is_printable(&plain[INTEGRITY_PREFIX_LEN..]) {
        return Ok(String::from_utf8_lossy(&plain[INTEGRITY_PREFIX_LEN..]).into_owned());
    }

    Err(Error::CookieDecrypt(
        "decrypted bytes don't look like a printable cookie value",
    ))
}

fn decrypt_aes_cbc(encrypted: &[u8], key: &[u8; PBKDF2_KEY_LEN]) -> Result<Vec<u8>> {
    if !encrypted.starts_with(backend::PREFIX) {
        return Err(Error::CookieDecrypt(
            "encrypted value missing expected version prefix",
        ));
    }
    let body = &encrypted[backend::PREFIX.len()..];
    if body.is_empty() || body.len() % 16 != 0 {
        return Err(Error::CookieDecrypt(
            "ciphertext length not a multiple of 16",
        ));
    }
    let mut buf = body.to_vec();
    let plaintext = Aes128CbcDec::new(key.into(), &AES_IV.into())
        .decrypt_padded_mut::<Pkcs7>(&mut buf)
        .map_err(|_| Error::CookieDecrypt("AES-CBC decrypt or PKCS7 unpad failed"))?;
    Ok(plaintext.to_vec())
}

fn is_printable(bytes: &[u8]) -> bool {
    bytes
        .iter()
        .all(|b| *b == b'\t' || *b == b'\n' || *b == b'\r' || (*b >= 0x20 && *b < 0x7f))
}
