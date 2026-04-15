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

    #[error("x rate-limited · retry in {}s", remaining_secs)]
    RateLimited { remaining_secs: u64 },

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
