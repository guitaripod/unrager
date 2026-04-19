use dioxus::prelude::*;
use pulldown_cmark::{Event, Options, Parser, Tag, TagEnd, html};

#[component]
pub fn Markdown(text: String) -> Element {
    let rendered = render(&text);
    rsx! {
        div {
            class: "md-body",
            dangerous_inner_html: "{rendered}",
        }
    }
}

fn render(text: &str) -> String {
    let mut opts = Options::empty();
    opts.insert(Options::ENABLE_STRIKETHROUGH);
    opts.insert(Options::ENABLE_TABLES);
    opts.insert(Options::ENABLE_SMART_PUNCTUATION);

    let parser = Parser::new_ext(text, opts);
    let filtered = parser.filter_map(|event| match &event {
        Event::Html(_) | Event::InlineHtml(_) => None,
        Event::Start(Tag::Link { dest_url, .. }) => {
            let url = dest_url.to_string();
            if is_safe_link(&url) {
                Some(event)
            } else {
                None
            }
        }
        Event::End(TagEnd::Link) => Some(event),
        _ => Some(event),
    });

    let mut out = String::new();
    html::push_html(&mut out, filtered);
    out
}

fn is_safe_link(url: &str) -> bool {
    let lower = url.to_ascii_lowercase();
    lower.starts_with("https://")
        || lower.starts_with("http://")
        || lower.starts_with("/")
        || lower.starts_with("#")
}
