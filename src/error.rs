use thiserror::Error;

pub type Result<T> = std::result::Result<T, Error>;

#[derive(Debug, Error)]
pub enum Error {
    #[error("cookie store not found at {path}: make sure Vivaldi is installed and has been run at least once")]
    CookieStoreMissing { path: std::path::PathBuf },

    #[error("no X session found in browser cookies: log in to x.com in Vivaldi first")]
    NotLoggedIn,

    #[error("keyring access failed: {0}")]
    Keyring(String),

    #[error("cookie decryption failed: {0}")]
    CookieDecrypt(&'static str),

    #[error("graphql request failed with status {status}: {body}")]
    GraphqlStatus { status: u16, body: String },

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
