use crate::tui::source::{SearchProduct, SourceKind};

#[derive(Debug, Clone)]
pub enum Command {
    SwitchSource(SourceKind),
    OpenTweet(String),
    Quit,
    Help,
}

#[derive(Debug, thiserror::Error)]
#[error("{0}")]
pub struct ParseError(pub String);

pub fn parse(input: &str) -> Result<Command, ParseError> {
    let trimmed = input.trim_start_matches(':').trim();
    if trimmed.is_empty() {
        return Err(ParseError("empty command".into()));
    }

    let (head, tail) = match trimmed.split_once(char::is_whitespace) {
        Some((h, t)) => (h, t.trim()),
        None => (trimmed, ""),
    };

    match head {
        "q" | "quit" => Ok(Command::Quit),
        "help" | "h" => Ok(Command::Help),
        "home" => match tail {
            "" | "for-you" | "foryou" | "fy" => {
                Ok(Command::SwitchSource(SourceKind::Home { following: false }))
            }
            "following" | "latest" => {
                Ok(Command::SwitchSource(SourceKind::Home { following: true }))
            }
            other => Err(ParseError(format!(
                "home takes 'for-you' or 'following', not '{other}'"
            ))),
        },
        "user" => {
            if tail.is_empty() {
                return Err(ParseError("user requires a handle".into()));
            }
            let handle = tail.trim_start_matches('@').to_string();
            Ok(Command::SwitchSource(SourceKind::User { handle }))
        }
        "search" => {
            if tail.is_empty() {
                return Err(ParseError("search requires a query".into()));
            }
            let (query, product) = parse_search_tail(tail);
            Ok(Command::SwitchSource(SourceKind::Search { query, product }))
        }
        "mentions" => {
            let target = if tail.is_empty() {
                None
            } else {
                Some(tail.trim_start_matches('@').to_string())
            };
            Ok(Command::SwitchSource(SourceKind::Mentions { target }))
        }
        "bookmarks" | "bm" => {
            if tail.is_empty() {
                return Err(ParseError(
                    "bookmarks requires a non-empty search query".into(),
                ));
            }
            Ok(Command::SwitchSource(SourceKind::Bookmarks {
                query: tail.to_string(),
            }))
        }
        "read" | "thread" | "open" | "o" => {
            if tail.is_empty() {
                return Err(ParseError(format!("{head} requires a tweet id or url")));
            }
            let id = crate::util::parse_tweet_ref(tail)
                .map_err(|e| ParseError(format!("bad tweet ref: {e}")))?;
            Ok(Command::OpenTweet(id))
        }
        other => Err(ParseError(format!("unknown command: {other}"))),
    }
}

fn parse_search_tail(tail: &str) -> (String, SearchProduct) {
    let lower = tail.to_lowercase();
    for (suffix, product) in [
        (" !top", SearchProduct::Top),
        (" !latest", SearchProduct::Latest),
        (" !people", SearchProduct::People),
        (" !photos", SearchProduct::Photos),
        (" !videos", SearchProduct::Videos),
    ] {
        if lower.ends_with(suffix) {
            let query = tail[..tail.len() - suffix.len()].trim_end().to_string();
            return (query, product);
        }
    }
    (tail.to_string(), SearchProduct::Latest)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn home_default() {
        assert!(matches!(
            parse(":home").unwrap(),
            Command::SwitchSource(SourceKind::Home { following: false })
        ));
    }

    #[test]
    fn home_following() {
        assert!(matches!(
            parse(":home following").unwrap(),
            Command::SwitchSource(SourceKind::Home { following: true })
        ));
    }

    #[test]
    fn user_handle() {
        match parse(":user @jack").unwrap() {
            Command::SwitchSource(SourceKind::User { handle }) => assert_eq!(handle, "jack"),
            _ => panic!("wrong variant"),
        }
    }

    #[test]
    fn user_without_at() {
        match parse(":user jack").unwrap() {
            Command::SwitchSource(SourceKind::User { handle }) => assert_eq!(handle, "jack"),
            _ => panic!("wrong variant"),
        }
    }

    #[test]
    fn search_with_product_suffix() {
        match parse(":search from:rustlang !top").unwrap() {
            Command::SwitchSource(SourceKind::Search { query, product }) => {
                assert_eq!(query, "from:rustlang");
                assert_eq!(product, SearchProduct::Top);
            }
            _ => panic!("wrong variant"),
        }
    }

    #[test]
    fn search_default_is_latest() {
        match parse(":search rust").unwrap() {
            Command::SwitchSource(SourceKind::Search { query, product }) => {
                assert_eq!(query, "rust");
                assert_eq!(product, SearchProduct::Latest);
            }
            _ => panic!("wrong variant"),
        }
    }

    #[test]
    fn mentions_self() {
        match parse(":mentions").unwrap() {
            Command::SwitchSource(SourceKind::Mentions { target: None }) => {}
            _ => panic!("wrong variant"),
        }
    }

    #[test]
    fn mentions_other() {
        match parse(":mentions @jack").unwrap() {
            Command::SwitchSource(SourceKind::Mentions { target: Some(h) }) => {
                assert_eq!(h, "jack");
            }
            _ => panic!("wrong variant"),
        }
    }

    #[test]
    fn bookmarks_requires_query() {
        assert!(parse(":bookmarks").is_err());
        match parse(":bookmarks the").unwrap() {
            Command::SwitchSource(SourceKind::Bookmarks { query }) => assert_eq!(query, "the"),
            _ => panic!("wrong variant"),
        }
    }

    #[test]
    fn read_numeric_id() {
        match parse(":read 20").unwrap() {
            Command::OpenTweet(id) => assert_eq!(id, "20"),
            _ => panic!("wrong variant"),
        }
    }

    #[test]
    fn read_url() {
        match parse(":read https://x.com/jack/status/20").unwrap() {
            Command::OpenTweet(id) => assert_eq!(id, "20"),
            _ => panic!("wrong variant"),
        }
    }

    #[test]
    fn thread_alias() {
        match parse(":thread 20").unwrap() {
            Command::OpenTweet(id) => assert_eq!(id, "20"),
            _ => panic!("wrong variant"),
        }
    }

    #[test]
    fn quit() {
        assert!(matches!(parse(":q").unwrap(), Command::Quit));
        assert!(matches!(parse(":quit").unwrap(), Command::Quit));
    }

    #[test]
    fn unknown() {
        assert!(parse(":nope").is_err());
    }

    #[test]
    fn no_colon_prefix_ok() {
        assert!(parse("home").is_ok());
    }
}
