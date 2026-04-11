pub mod chromium;

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct XSession {
    pub auth_token: String,
    pub ct0: String,
    pub twid: String,
}

impl XSession {
    pub fn user_id(&self) -> Option<&str> {
        self.twid
            .strip_prefix("u%3D")
            .or_else(|| self.twid.strip_prefix("u="))
    }
}

impl std::fmt::Display for XSession {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "XSession {{ auth_token: <redacted>, ct0: <redacted>, twid: <redacted> }}")
    }
}
