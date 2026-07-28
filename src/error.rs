use thiserror::Error;

pub type Result<T> = std::result::Result<T, Error>;

#[derive(Debug, Error)]
pub enum Error {
    #[error(
        "no Chromium-family cookie store found at any known location; \
         install Vivaldi / Chromium / Chrome / Brave / Edge and run it at least once, \
         or set UNRAGER_COOKIES_PATH=/path/to/Cookies"
    )]
    CookieStoreMissing,

    #[error(
        "no x.com session found in any browser cookie store; log in to x.com in Vivaldi / Chrome / Chromium / Brave / Edge first"
    )]
    NotLoggedIn,

    #[error("keyring access failed: {0}")]
    Keyring(String),

    #[error("cookie decryption failed: {0}")]
    CookieDecrypt(&'static str),

    #[error("graphql request failed with status {status}: {body}")]
    GraphqlStatus { status: u16, body: String },

    /// An error X named itself, with its own numeric code preserved. X
    /// reports the same condition as a 200 carrying an `errors` array about
    /// as often as it reports it as a 4xx, and the code is the only thing
    /// that distinguishes "no such post" from "this request looks
    /// automated" — a caller that must stop rather than retry needs it.
    #[error("x rejected the request{}{}: {message}",
        .code.map(|c| format!(" (code {c})")).unwrap_or_default(),
        .status.map(|s| format!(" [http {s}]")).unwrap_or_default())]
    GraphqlApi {
        status: Option<u16>,
        code: Option<i64>,
        message: String,
    },

    #[error("x rate-limited · retry in {}s", remaining_secs)]
    RateLimited { remaining_secs: u64 },

    #[error(
        "no query id for operation {operation}; the query id scraper hasn't found it yet — \
         retry with network access, or set [query_ids] {operation} = \"...\" in config.toml"
    )]
    MissingQueryId { operation: &'static str },

    #[error("graphql response shape unexpected: {0}")]
    GraphqlShape(String),

    #[error("tweet id could not be parsed from {0:?}")]
    BadTweetRef(String),

    #[error("config load failed: {0}")]
    Config(String),

    #[error(transparent)]
    Sqlite(#[from] rusqlite::Error),

    #[error(transparent)]
    Io(#[from] std::io::Error),

    #[error(transparent)]
    Http(#[from] reqwest::Error),

    #[error(transparent)]
    Json(#[from] serde_json::Error),
}

impl Error {
    /// X's own numeric error code, when X named one.
    pub fn x_code(&self) -> Option<i64> {
        match self {
            Error::GraphqlApi { code, .. } => *code,
            _ => None,
        }
    }

    /// Whether X is refusing because it believes the client is automated,
    /// or because the account itself is restricted — the cases where the
    /// only correct response is to stop rather than retry. Retrying into
    /// one of these is the behavior that turns a soft block into a hard
    /// one, so every write loop should check it.
    ///
    /// 226 is "this request looks like it might be automated", 326 is a
    /// temporary lock pending verification, and 63/64 are suspensions. The
    /// text checks catch the same conditions when X answers with a 403 and
    /// a body that carries no code.
    pub fn is_automation_block(&self) -> bool {
        match self {
            Error::GraphqlApi {
                code: Some(226 | 326 | 63 | 64),
                ..
            } => true,
            Error::GraphqlApi {
                status: Some(403),
                message,
                ..
            } => reads_like_a_block(message),
            Error::GraphqlStatus { status: 403, body } => reads_like_a_block(body),
            _ => false,
        }
    }
}

fn reads_like_a_block(text: &str) -> bool {
    let lowered = text.to_ascii_lowercase();
    lowered.contains("automated")
        || lowered.contains("temporarily locked")
        || lowered.contains("suspended")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn api(code: Option<i64>, status: Option<u16>, message: &str) -> Error {
        Error::GraphqlApi {
            status,
            code,
            message: message.to_string(),
        }
    }

    #[test]
    fn automation_and_account_codes_are_blocks() {
        for code in [226, 326, 63, 64] {
            assert!(
                api(Some(code), None, "nope").is_automation_block(),
                "code {code} should stop a write loop"
            );
        }
    }

    #[test]
    fn ordinary_api_errors_are_not_blocks() {
        for code in [144, 179, 183, 88] {
            assert!(!api(Some(code), None, "nope").is_automation_block());
        }
        assert!(!Error::GraphqlShape("weird".into()).is_automation_block());
        assert!(
            !Error::RateLimited {
                remaining_secs: 900
            }
            .is_automation_block()
        );
    }

    #[test]
    fn a_codeless_403_is_read_for_its_wording() {
        assert!(
            api(
                None,
                Some(403),
                "This request looks like it might be automated."
            )
            .is_automation_block()
        );
        assert!(
            Error::GraphqlStatus {
                status: 403,
                body: "your account is temporarily locked".into(),
            }
            .is_automation_block()
        );
        assert!(
            !Error::GraphqlStatus {
                status: 403,
                body: "missing csrf token".into(),
            }
            .is_automation_block()
        );
    }

    #[test]
    fn the_code_is_reachable_for_callers() {
        assert_eq!(api(Some(226), None, "x").x_code(), Some(226));
        assert_eq!(Error::GraphqlShape("x".into()).x_code(), None);
    }

    #[test]
    fn the_message_carries_the_code_and_status() {
        let rendered = api(Some(226), Some(403), "looks automated").to_string();
        assert!(rendered.contains("226"), "{rendered}");
        assert!(rendered.contains("403"), "{rendered}");
        assert!(rendered.contains("looks automated"), "{rendered}");
    }
}
