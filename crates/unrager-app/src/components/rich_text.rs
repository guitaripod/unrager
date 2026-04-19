use crate::routes::Route;
use dioxus::prelude::*;
use regex::Regex;
use std::sync::OnceLock;

static URL_RE: OnceLock<Regex> = OnceLock::new();
static MENTION_RE: OnceLock<Regex> = OnceLock::new();
static HASHTAG_RE: OnceLock<Regex> = OnceLock::new();

fn url_re() -> &'static Regex {
    URL_RE.get_or_init(|| {
        // URLs end at whitespace or common boundary punctuation
        Regex::new(r#"https?://[^\s<>()\[\]{}`"']+"#).expect("url regex")
    })
}
fn mention_re() -> &'static Regex {
    MENTION_RE
        .get_or_init(|| Regex::new(r"(?:^|\s|[^\w@])@([A-Za-z0-9_]{1,15})").expect("mention regex"))
}
fn hashtag_re() -> &'static Regex {
    HASHTAG_RE.get_or_init(|| Regex::new(r"(?:^|\s|[^\w#])#(\w{1,60})").expect("hashtag regex"))
}

#[derive(Debug, Clone, PartialEq)]
enum Segment {
    Text(String),
    Url(String),
    Mention(String),
    Hashtag(String),
}

#[derive(Debug, Clone)]
struct Match {
    start: usize,
    end: usize,
    kind: MatchKind,
}

#[derive(Debug, Clone)]
enum MatchKind {
    Url,
    Mention,
    Hashtag,
}

fn parse(text: &str) -> Vec<Segment> {
    let mut matches: Vec<Match> = Vec::new();

    for m in url_re().find_iter(text) {
        matches.push(Match {
            start: m.start(),
            end: m.end(),
            kind: MatchKind::Url,
        });
    }
    for caps in mention_re().captures_iter(text) {
        if let Some(m) = caps.get(1) {
            // m captures the handle without @
            let at_pos = text[..m.start()]
                .rfind('@')
                .unwrap_or(m.start().saturating_sub(1));
            matches.push(Match {
                start: at_pos,
                end: m.end(),
                kind: MatchKind::Mention,
            });
        }
    }
    for caps in hashtag_re().captures_iter(text) {
        if let Some(m) = caps.get(1) {
            let hash_pos = text[..m.start()]
                .rfind('#')
                .unwrap_or(m.start().saturating_sub(1));
            matches.push(Match {
                start: hash_pos,
                end: m.end(),
                kind: MatchKind::Hashtag,
            });
        }
    }

    matches.sort_by_key(|m| m.start);

    let mut cleaned: Vec<Match> = Vec::with_capacity(matches.len());
    let mut last_end = 0;
    for m in matches {
        if m.start < last_end {
            continue;
        }
        last_end = m.end;
        cleaned.push(m);
    }

    let mut out: Vec<Segment> = Vec::new();
    let mut cursor = 0;
    for m in cleaned {
        if m.start > cursor {
            out.push(Segment::Text(text[cursor..m.start].to_string()));
        }
        let slice = &text[m.start..m.end];
        match m.kind {
            MatchKind::Url => out.push(Segment::Url(slice.to_string())),
            MatchKind::Mention => {
                let handle = slice.trim_start_matches('@').to_string();
                out.push(Segment::Mention(handle));
            }
            MatchKind::Hashtag => {
                let tag = slice.trim_start_matches('#').to_string();
                out.push(Segment::Hashtag(tag));
            }
        }
        cursor = m.end;
    }
    if cursor < text.len() {
        out.push(Segment::Text(text[cursor..].to_string()));
    }
    out
}

#[component]
pub fn RichText(text: String) -> Element {
    let segments = parse(&text);
    rsx! {
        for (i, seg) in segments.iter().enumerate() {
            match seg {
                Segment::Text(s) => rsx! { span { key: "{i}", "{s}" } },
                Segment::Url(u) => rsx! {
                    a {
                        key: "{i}",
                        class: "rt-url",
                        href: "{u}",
                        target: "_blank",
                        rel: "noopener nofollow",
                        onclick: move |e: Event<MouseData>| e.stop_propagation(),
                        {display_url(u)}
                    }
                },
                Segment::Mention(h) => rsx! {
                    Link {
                        key: "{i}",
                        to: Route::Profile { handle: h.clone() },
                        class: "rt-mention",
                        onclick: move |e: Event<MouseData>| e.stop_propagation(),
                        "@{h}"
                    }
                },
                Segment::Hashtag(t) => rsx! {
                    Link {
                        key: "{i}",
                        to: Route::SourceSearch { product: "top".into(), q: format!("#{t}") },
                        class: "rt-hashtag",
                        onclick: move |e: Event<MouseData>| e.stop_propagation(),
                        "#{t}"
                    }
                },
            }
        }
    }
}

fn display_url(url: &str) -> String {
    let without_scheme = url
        .strip_prefix("https://")
        .or_else(|| url.strip_prefix("http://"))
        .unwrap_or(url);
    if without_scheme.len() > 40 {
        format!("{}…", &without_scheme[..40])
    } else {
        without_scheme.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_plain() {
        let segs = parse("hello world");
        assert_eq!(segs.len(), 1);
    }

    #[test]
    fn extracts_url() {
        let segs = parse("see https://example.com for info");
        assert_eq!(segs.len(), 3);
    }

    #[test]
    fn extracts_mention() {
        let segs = parse("hi @alice and @bob");
        let mentions: Vec<_> = segs
            .iter()
            .filter_map(|s| match s {
                Segment::Mention(h) => Some(h.clone()),
                _ => None,
            })
            .collect();
        assert_eq!(mentions, vec!["alice", "bob"]);
    }

    #[test]
    fn extracts_hashtag() {
        let segs = parse("love #rustlang and #wasm");
        let tags: Vec<_> = segs
            .iter()
            .filter_map(|s| match s {
                Segment::Hashtag(t) => Some(t.clone()),
                _ => None,
            })
            .collect();
        assert_eq!(tags, vec!["rustlang", "wasm"]);
    }

    #[test]
    fn email_not_mention() {
        let segs = parse("email me at alice@example.com");
        let mentions: Vec<_> = segs
            .iter()
            .filter(|s| matches!(s, Segment::Mention(_)))
            .collect();
        assert!(mentions.is_empty(), "email shouldn't parse as mention");
    }
}
