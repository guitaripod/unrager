use crate::routes::Route;
use dioxus::prelude::*;

#[derive(Clone, PartialEq)]
struct Command {
    label: &'static str,
    route: Route,
}

fn commands() -> Vec<Command> {
    vec![
        Command {
            label: "Home (For You)",
            route: Route::SourceHome {},
        },
        Command {
            label: "Mentions",
            route: Route::SourceMentions {},
        },
        Command {
            label: "Notifications",
            route: Route::SourceNotifs {},
        },
        Command {
            label: "Bookmarks",
            route: Route::SourceBookmarks { q: "".into() },
        },
        Command {
            label: "Compose",
            route: Route::Compose {},
        },
        Command {
            label: "Settings",
            route: Route::Settings {},
        },
    ]
}

#[component]
pub fn CommandPalette(on_close: EventHandler<()>) -> Element {
    let nav = use_navigator();
    let mut query = use_signal(String::new);
    let mut selected = use_signal(|| 0usize);

    let filtered = use_memo(move || {
        let q = query().to_lowercase();
        commands()
            .into_iter()
            .filter(|c| q.is_empty() || c.label.to_lowercase().contains(&q))
            .collect::<Vec<_>>()
    });

    rsx! {
        div {
            class: "palette",
            onclick: move |_| on_close.call(()),
            div {
                class: "box",
                onclick: move |e| e.stop_propagation(),
                input {
                    r#type: "text",
                    placeholder: "command...",
                    autofocus: true,
                    value: "{query}",
                    oninput: move |e| query.set(e.value()),
                    onkeydown: move |e| {
                        let items = filtered();
                        match e.key() {
                            Key::Escape => on_close.call(()),
                            Key::ArrowDown => {
                                let n = items.len().max(1);
                                selected.set((selected() + 1) % n);
                            }
                            Key::ArrowUp => {
                                let n = items.len().max(1);
                                selected.set((selected() + n - 1) % n);
                            }
                            Key::Enter => {
                                if let Some(c) = items.get(selected()) {
                                    nav.push(c.route.clone());
                                    on_close.call(());
                                }
                            }
                            _ => {}
                        }
                    },
                }
                for (i, c) in filtered().iter().enumerate() {
                    div {
                        class: if i == selected() { "opt active" } else { "opt" },
                        onclick: {
                            let r = c.route.clone();
                            move |_| {
                                nav.push(r.clone());
                                on_close.call(());
                            }
                        },
                        "{c.label}"
                    }
                }
            }
        }
    }
}
