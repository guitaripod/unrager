use dioxus::prelude::*;

#[component]
pub fn HelpOverlay(on_close: EventHandler<()>) -> Element {
    rsx! {
        div {
            class: "help-overlay",
            onclick: move |_| on_close.call(()),
            div {
                class: "box",
                onclick: move |e| e.stop_propagation(),
                h2 { "keyboard shortcuts" }
                table {
                    tbody {
                        HelpRow { key_name: "j / k", desc: "next / prev tweet" }
                        HelpRow { key_name: "Enter", desc: "open selected tweet" }
                        HelpRow { key_name: "o", desc: "open in browser" }
                        HelpRow { key_name: "l", desc: "like / unlike" }
                        HelpRow { key_name: "t", desc: "translate to English" }
                        HelpRow { key_name: "a", desc: "ask about this tweet" }
                        HelpRow { key_name: "b", desc: "brief (profile view only)" }
                        HelpRow { key_name: "f", desc: "toggle filter" }
                        HelpRow { key_name: "F", desc: "re-run filter" }
                        HelpRow { key_name: "V", desc: "toggle feed mode (home)" }
                        HelpRow { key_name: "p", desc: "open selected author's profile" }
                        HelpRow { key_name: "Ctrl/⌘ + K", desc: "command palette" }
                        HelpRow { key_name: "?", desc: "this overlay" }
                        HelpRow { key_name: "Esc", desc: "close overlay / go back" }
                    }
                }
                div { style: "text-align:right; margin-top: 12px;",
                    button { onclick: move |_| on_close.call(()), "close" }
                }
            }
        }
    }
}

#[component]
fn HelpRow(key_name: &'static str, desc: &'static str) -> Element {
    rsx! {
        tr {
            td { class: "key", "{key_name}" }
            td { "{desc}" }
        }
    }
}
