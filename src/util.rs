use crate::error::{Error, Result};
use std::sync::OnceLock;

static STATUS_ID_RE: OnceLock<regex::Regex> = OnceLock::new();

fn status_id_re() -> &'static regex::Regex {
    STATUS_ID_RE.get_or_init(|| regex::Regex::new(r"/status/(\d{1,25})").expect("status id regex"))
}

pub fn parse_tweet_ref(raw: &str) -> Result<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err(Error::BadTweetRef(raw.to_string()));
    }

    if trimmed.chars().all(|c| c.is_ascii_digit()) && (1..=25).contains(&trimmed.len()) {
        return Ok(trimmed.to_string());
    }

    if let Some(cap) = status_id_re().captures(trimmed) {
        return Ok(cap[1].to_string());
    }

    Err(Error::BadTweetRef(raw.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn raw_numeric_id() {
        assert_eq!(
            parse_tweet_ref("1234567890123456789").unwrap(),
            "1234567890123456789"
        );
    }

    #[test]
    fn x_com_url() {
        assert_eq!(
            parse_tweet_ref("https://x.com/foo/status/1234567890123456789").unwrap(),
            "1234567890123456789"
        );
    }

    #[test]
    fn twitter_com_url_with_query() {
        assert_eq!(
            parse_tweet_ref("https://twitter.com/foo/status/9876543210?s=20&t=abc").unwrap(),
            "9876543210"
        );
    }

    #[test]
    fn short_numeric_id() {
        assert_eq!(parse_tweet_ref("20").unwrap(), "20");
    }

    #[test]
    fn rejects_garbage() {
        assert!(parse_tweet_ref("").is_err());
        assert!(parse_tweet_ref("not a tweet").is_err());
    }
}
