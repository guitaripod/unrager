use dioxus::prelude::*;

#[component]
pub fn ErrorBanner(
    message: String,
    #[props(default)] on_retry: Option<EventHandler<()>>,
) -> Element {
    rsx! {
        div { class: "error-banner",
            span { class: "error-message", "{message}" }
            if let Some(retry) = on_retry {
                button { class: "error-retry", onclick: move |_| retry.call(()), "retry" }
            }
        }
    }
}
