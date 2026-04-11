use crate::error::{Error, Result};
use aes::Aes128;
use cbc::cipher::{BlockDecryptMut, KeyIvInit, block_padding::Pkcs7};
use directories::BaseDirs;
use hmac::Hmac;
use rusqlite::{Connection, OpenFlags};
use sha1::Sha1;
use std::path::{Path, PathBuf};

use super::XSession;

type Aes128CbcDec = cbc::Decryptor<Aes128>;

const SAFE_STORAGE_SUFFIX: &str = "Safe Storage";
const PORTAL_SERVER: &str = "xdg-desktop-portal";
const PEANUTS_PASSWORD: &[u8] = b"peanuts";
const PBKDF2_SALT: &[u8] = b"saltysalt";
const PBKDF2_ITERATIONS: u32 = 1;
const PBKDF2_KEY_LEN: usize = 16;
const V11_PREFIX: &[u8] = b"v11";
const AES_IV: [u8; 16] = [0x20; 16];
const INTEGRITY_PREFIX_LEN: usize = 32;

const COOKIE_NAMES: &[&str] = &["auth_token", "ct0", "twid"];

pub async fn load_session() -> Result<XSession> {
    let cookies_path = default_cookies_path()?;
    if !cookies_path.exists() {
        return Err(Error::CookieStoreMissing { path: cookies_path });
    }

    let encrypted = read_encrypted_cookies(&cookies_path)?;
    let passwords = candidate_passwords().await;
    tracing::debug!("trying {} candidate decryption passwords", passwords.len());

    let mut winning_key: Option<[u8; PBKDF2_KEY_LEN]> = None;
    let mut auth_token = None;
    let mut ct0 = None;
    let mut twid = None;

    for (name, ciphertext) in &encrypted {
        let plain = if let Some(key) = winning_key {
            decrypt_and_extract(ciphertext, &key)?
        } else {
            let (key, plain) = try_all(ciphertext, &passwords)?;
            winning_key = Some(key);
            plain
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

fn default_cookies_path() -> Result<PathBuf> {
    let base = BaseDirs::new().ok_or_else(|| Error::Config("HOME not set".into()))?;
    Ok(base.config_dir().join("vivaldi").join("Default").join("Cookies"))
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
    if out.len() < COOKIE_NAMES.len() {
        return Err(Error::NotLoggedIn);
    }
    Ok(out)
}

async fn candidate_passwords() -> Vec<Vec<u8>> {
    let mut out = Vec::new();
    match collect_keyring_secrets().await {
        Ok(secrets) => {
            tracing::debug!("collected {} keyring secrets", secrets.len());
            out.extend(secrets);
        }
        Err(e) => {
            tracing::warn!("keyring enumeration failed: {e}");
        }
    }
    out.push(PEANUTS_PASSWORD.to_vec());
    out
}

async fn collect_keyring_secrets() -> Result<Vec<Vec<u8>>> {
    let ss = secret_service::SecretService::connect(secret_service::EncryptionType::Dh)
        .await
        .map_err(|e| Error::Keyring(e.to_string()))?;

    let collection = ss
        .get_default_collection()
        .await
        .map_err(|e| Error::Keyring(e.to_string()))?;
    collection
        .unlock()
        .await
        .map_err(|e| Error::Keyring(e.to_string()))?;

    let items = collection
        .get_all_items()
        .await
        .map_err(|e| Error::Keyring(e.to_string()))?;

    let mut out = Vec::new();
    for item in items {
        let label = item
            .get_label()
            .await
            .map_err(|e| Error::Keyring(e.to_string()))?;
        let is_safe_storage = label.contains(SAFE_STORAGE_SUFFIX);
        let is_portal_blob = label.starts_with(PORTAL_SERVER);
        if !is_safe_storage && !is_portal_blob {
            continue;
        }
        let secret = item
            .get_secret()
            .await
            .map_err(|e| Error::Keyring(e.to_string()))?;
        if !secret.is_empty() {
            tracing::debug!("keyring candidate: {label:?} ({} bytes)", secret.len());
            out.push(secret);
        }
    }
    Ok(out)
}

fn derive_key(password: &[u8]) -> Option<[u8; PBKDF2_KEY_LEN]> {
    let mut key = [0u8; PBKDF2_KEY_LEN];
    pbkdf2::pbkdf2::<Hmac<Sha1>>(password, PBKDF2_SALT, PBKDF2_ITERATIONS, &mut key).ok()?;
    Some(key)
}

fn try_all(
    encrypted: &[u8],
    passwords: &[Vec<u8>],
) -> Result<([u8; PBKDF2_KEY_LEN], String)> {
    let mut last_err = Error::CookieDecrypt("no candidate keys produced a valid plaintext");
    for password in passwords {
        let Some(key) = derive_key(password) else {
            continue;
        };
        match decrypt_and_extract(encrypted, &key) {
            Ok(text) => {
                tracing::debug!("decrypt succeeded with a {}-byte password", password.len());
                return Ok((key, text));
            }
            Err(e) => last_err = e,
        }
    }
    Err(last_err)
}

fn decrypt_and_extract(encrypted: &[u8], key: &[u8; PBKDF2_KEY_LEN]) -> Result<String> {
    let plain = decrypt_v11(encrypted, key)?;
    let stripped = if plain.len() > INTEGRITY_PREFIX_LEN {
        &plain[INTEGRITY_PREFIX_LEN..]
    } else {
        plain.as_slice()
    };
    if stripped.is_empty() || !is_printable(stripped) {
        return Err(Error::CookieDecrypt(
            "decrypted bytes don't look like a printable cookie value",
        ));
    }
    Ok(String::from_utf8_lossy(stripped).into_owned())
}

fn decrypt_v11(encrypted: &[u8], key: &[u8; PBKDF2_KEY_LEN]) -> Result<Vec<u8>> {
    if !encrypted.starts_with(V11_PREFIX) {
        return Err(Error::CookieDecrypt(
            "encrypted value missing v11 prefix; unsupported Chromium encryption version",
        ));
    }
    let body = &encrypted[V11_PREFIX.len()..];
    if body.is_empty() || body.len() % 16 != 0 {
        return Err(Error::CookieDecrypt("ciphertext length not a multiple of 16"));
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
