pub mod chromium;
pub mod oauth;

use serde::{Deserialize, Serialize};

#[derive(Clone, Serialize, Deserialize)]
pub struct XSession {
    pub auth_token: String,
    pub ct0: String,
    pub twid: String,
}

impl std::fmt::Debug for XSession {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("XSession")
            .field("auth_token", &"<redacted>")
            .field("ct0", &"<redacted>")
            .field("twid", &"<redacted>")
            .finish()
    }
}

impl std::fmt::Display for XSession {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("XSession { <redacted> }")
    }
}
