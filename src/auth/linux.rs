use crate::error::{Error, Result};

use super::chromium::Browser;

pub const PREFIX: &[u8] = b"v11";
pub const ITERS: u32 = 1;

const PEANUTS_PASSWORD: &[u8] = b"peanuts";
const SAFE_STORAGE_SUFFIX: &str = "Safe Storage";
const PORTAL_SERVER: &str = "xdg-desktop-portal";

pub async fn candidate_passwords(_browser: &Browser) -> Vec<Vec<u8>> {
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
    let ss = secret_service::SecretService::connect(secret_service::EncryptionType::Plain)
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

    let label_futs: Vec<_> = items.iter().map(|item| item.get_label()).collect();
    let labels: Vec<_> = futures::future::join_all(label_futs)
        .await
        .into_iter()
        .map(|r| r.unwrap_or_default())
        .collect();

    let mut out = Vec::new();
    for (item, label) in items.iter().zip(labels.iter()) {
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
