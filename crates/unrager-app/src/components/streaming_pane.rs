use crate::components::markdown::Markdown;
use dioxus::prelude::*;

#[component]
pub fn StreamingPane(text: String, streaming: bool, title: Option<String>) -> Element {
    rsx! {
        div { class: "stream",
            if let Some(t) = title { h3 { class: "stream-title", "{t}" } }
            if text.is_empty() && streaming {
                div { class: "stream-placeholder",
                    span { class: "caret" }
                    span { class: "stream-loading-label", "thinking…" }
                }
            } else {
                Markdown { text: text.clone() }
                if streaming { span { class: "caret" } }
            }
        }
    }
}
