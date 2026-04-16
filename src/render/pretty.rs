use crate::model::{MediaKind, Tweet};
use crate::util::short_count;
use std::fmt::Write;

pub fn tweet(tweet: &Tweet) -> String {
    let mut out = String::new();
    render_into(&mut out, tweet, 0);
    out
}

pub fn tweet_list(tweets: &[Tweet]) -> String {
    let mut out = String::new();
    for (i, t) in tweets.iter().enumerate() {
        if i > 0 {
            let _ = writeln!(out, "────────────────────────────────────────");
        }
        render_into(&mut out, t, 0);
    }
    out
}

fn render_into(out: &mut String, t: &Tweet, indent_level: usize) {
    let indent = "  ".repeat(indent_level);
    let verified = if t.author.verified { " ✓" } else { "" };
    let name = if t.author.name.is_empty() {
        String::new()
    } else {
        format!(" ({})", t.author.name)
    };
    let _ = writeln!(
        out,
        "{indent}@{handle}{verified}{name}",
        handle = t.author.handle
    );
    let _ = writeln!(
        out,
        "{indent}{ts}  {url}",
        ts = t.created_at.format("%Y-%m-%d %H:%M UTC"),
        url = t.url
    );
    let _ = writeln!(out);
    for line in t.text.lines() {
        let _ = writeln!(out, "{indent}{line}");
    }
    let _ = writeln!(out);

    if !t.media.is_empty() {
        for m in &t.media {
            let kind = match m.kind {
                MediaKind::Photo => "photo",
                MediaKind::Video => "video",
                MediaKind::AnimatedGif => "gif",
            };
            let alt = m
                .alt_text
                .as_deref()
                .map(|a| format!(" — {a}"))
                .unwrap_or_default();
            let _ = writeln!(out, "{indent}[{kind}] {url}{alt}", url = m.url);
        }
        let _ = writeln!(out);
    }

    let _ = writeln!(
        out,
        "{indent}💬 {reply}   🔁 {rt}   ♥ {like}   💭 {quote}{views}",
        reply = short_count(t.reply_count),
        rt = short_count(t.retweet_count),
        like = short_count(t.like_count),
        quote = short_count(t.quote_count),
        views = t
            .view_count
            .map(|v| format!("   👁 {}", short_count(v)))
            .unwrap_or_default(),
    );

    if let Some(q) = &t.quoted_tweet {
        let _ = writeln!(out);
        let _ = writeln!(out, "{indent}── quoting ──");
        render_into(out, q, indent_level + 1);
    }
}
