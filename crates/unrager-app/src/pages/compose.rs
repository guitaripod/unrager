use crate::components::ComposeSheet;
use dioxus::prelude::*;

#[component]
pub fn Compose() -> Element {
    rsx! {
        div { class: "topbar", h2 { "compose" } }
        ComposeSheet { reply_to: None }
    }
}

#[component]
pub fn Reply(tweet_id: String) -> Element {
    rsx! {
        div { class: "topbar", h2 { "reply" } }
        ComposeSheet { reply_to: Some(tweet_id) }
    }
}
