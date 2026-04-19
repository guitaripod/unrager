use crate::components::icons::IconSave;
use crate::state::AppState;
use dioxus::prelude::*;

#[component]
pub fn Settings() -> Element {
    let mut state = use_context::<Signal<AppState>>();

    let current = state.read().clone();

    rsx! {
        div { class: "topbar", h2 { "settings" } }

        div { class: "settings",

            section { class: "settings-section",
                h3 { "connection" }
                label { class: "field",
                    span { class: "field-label", "server URL" }
                    input {
                        r#type: "text",
                        value: "{current.server_url}",
                        oninput: move |e| {
                            let v = e.value();
                            state.write().server_url = v;
                        },
                    }
                    span { class: "field-hint",
                        "point at your unrager server (default: same origin or http://localhost:7777)"
                    }
                }
            }

            section { class: "settings-section",
                h3 { "display" }
                label { class: "toggle",
                    input {
                        r#type: "checkbox",
                        checked: current.filter_enabled,
                        oninput: move |e| {
                            let v = e.checked();
                            state.write().filter_enabled = v;
                        },
                    }
                    span { class: "toggle-label",
                        strong { "rage filter" }
                        span { class: "toggle-hint",
                            "classify tweets via local Ollama; HIDE verdicts are removed from the feed."
                        }
                    }
                }
                label { class: "toggle",
                    input {
                        r#type: "checkbox",
                        checked: current.metrics_visible,
                        oninput: move |e| {
                            let v = e.checked();
                            state.write().metrics_visible = v;
                        },
                    }
                    span { class: "toggle-label",
                        strong { "engagement stats" }
                        span { class: "toggle-hint",
                            "show the view count and engagement ratio under each tweet."
                        }
                    }
                }
                label { class: "toggle",
                    input {
                        r#type: "checkbox",
                        checked: current.absolute_time,
                        oninput: move |e| {
                            let v = e.checked();
                            state.write().absolute_time = v;
                        },
                    }
                    span { class: "toggle-label",
                        strong { "absolute timestamps" }
                        span { class: "toggle-hint",
                            "show \"Apr 19 · 14:20\" instead of \"2h\"."
                        }
                    }
                }
            }

            section { class: "settings-section",
                div { class: "button-row",
                    button {
                        class: "primary save-btn",
                        onclick: move |_| state.read().save(),
                        IconSave {}
                        span { "save to local storage" }
                    }
                }
                p { class: "settings-hint",
                    "settings persist in your browser only. the server keeps its own session file at "
                    code { "~/.config/unrager/server-session.json" }
                    "."
                }
            }
        }
    }
}
