use super::chromium::Browser;

pub const PREFIX: &[u8] = b"v10";
pub const ITERS: u32 = 1003;

pub async fn candidate_passwords(browser: &Browser) -> Vec<Vec<u8>> {
    match security_framework::passwords::get_generic_password(
        browser.macos_keychain_service,
        browser.macos_keychain_account,
    ) {
        Ok(pw) if !pw.is_empty() => {
            tracing::debug!(
                "keychain candidate: {:?} ({} bytes)",
                browser.macos_keychain_service,
                pw.len()
            );
            vec![pw]
        }
        Ok(_) => Vec::new(),
        Err(e) => {
            tracing::warn!(
                "keychain lookup failed for {:?}: {}",
                browser.macos_keychain_service,
                e
            );
            Vec::new()
        }
    }
}
