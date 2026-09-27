pub mod chromium;
pub mod oauth;

#[cfg(target_os = "linux")]
pub(crate) mod linux;
#[cfg(target_os = "macos")]
pub(crate) mod macos;

use serde::{Deserialize, Serialize};

#[derive(Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct XSession {
    pub auth_token: String,
    pub ct0: String,
    pub twid: String,
}

impl XSession {
    /// The signed-in account's numeric id. X keeps it in the `twid` cookie
    /// as `u=<id>`, usually percent-encoded and sometimes quoted.
    pub fn user_id(&self) -> Option<String> {
        let decoded = self
            .twid
            .trim_matches('"')
            .replace("%3D", "=")
            .replace("%3d", "=");
        let id = decoded.strip_prefix("u=")?;
        (!id.is_empty() && id.bytes().all(|b| b.is_ascii_digit())).then(|| id.to_string())
    }
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

#[cfg(test)]
mod tests {
    use super::*;

    fn with_twid(twid: &str) -> XSession {
        XSession {
            twid: twid.into(),
            ..XSession::default()
        }
    }

    #[test]
    fn the_account_id_comes_from_the_twid_cookie_in_any_encoding() {
        for twid in [
            "u%3D1160223221037305856",
            "\"u=1160223221037305856\"",
            "u=1160223221037305856",
        ] {
            assert_eq!(
                with_twid(twid).user_id().as_deref(),
                Some("1160223221037305856"),
                "{twid}"
            );
        }
        for twid in ["", "u%3D", "x=1", "u=12ab"] {
            assert_eq!(with_twid(twid).user_id(), None, "{twid}");
        }
    }
}
