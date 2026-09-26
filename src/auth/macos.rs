use super::chromium::Browser;

pub const PREFIXES: &[&[u8]] = &[b"v10"];
pub const ITERS: u32 = 1003;

/// The Keychain lookup blocks, and on first use waits for the user to
/// answer macOS's access prompt, so it runs on the blocking pool.
pub async fn candidate_passwords(browser: &Browser) -> Vec<Vec<u8>> {
    let (service, account) = (
        browser.macos_keychain_service,
        browser.macos_keychain_account,
    );
    let lookup = tokio::task::spawn_blocking(move || {
        security_framework::passwords::get_generic_password(service, account)
    })
    .await;
    match lookup {
        Ok(Ok(pw)) if !pw.is_empty() => {
            tracing::debug!("keychain candidate: {:?} ({} bytes)", service, pw.len());
            vec![pw]
        }
        Ok(Ok(_)) => Vec::new(),
        Ok(Err(e)) => {
            tracing::warn!("keychain lookup failed for {:?}: {}", service, e);
            Vec::new()
        }
        Err(e) => {
            tracing::warn!("keychain lookup task failed for {:?}: {}", service, e);
            Vec::new()
        }
    }
}
