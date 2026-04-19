use dioxus::prelude::*;

#[component]
pub fn NotFound(segments: Vec<String>) -> Element {
    let path = segments.join("/");
    rsx! {
        div { class: "loading",
            p { "not found" }
            p { code { "/{path}" } }
        }
    }
}
