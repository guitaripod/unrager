use crate::components::icons::{
    IconAt, IconBell, IconBookmark, IconCommand, IconGear, IconHelp, IconHome, IconPencil,
};
use crate::components::{CommandPalette, HelpOverlay, ToastContainer};
use crate::routes::Route;
use dioxus::prelude::*;

#[component]
pub fn Layout() -> Element {
    let mut show_help = use_signal(|| false);
    let mut show_palette = use_signal(|| false);

    rsx! {
        div {
            class: "layout",
            onkeydown: move |e| {
                let key = e.key();
                if (e.modifiers().meta() || e.modifiers().ctrl()) && matches!(&key, Key::Character(s) if s == "k") {
                    e.prevent_default();
                    *show_palette.write() = true;
                } else if matches!(&key, Key::Character(s) if s == "?") {
                    *show_help.write() = true;
                } else if matches!(key, Key::Escape) {
                    *show_help.write() = false;
                    *show_palette.write() = false;
                }
            },
            aside { class: "sidebar",
                div { class: "brand",
                    h1 { "unrager" }
                }
                nav {
                    Link { to: Route::SourceHome {}, active_class: "active",
                        span { class: "nav-icon", IconHome {} }
                        span { class: "nav-label", "home" }
                    }
                    Link { to: Route::SourceMentions {}, active_class: "active",
                        span { class: "nav-icon", IconAt {} }
                        span { class: "nav-label", "mentions" }
                    }
                    Link { to: Route::SourceNotifs {}, active_class: "active",
                        span { class: "nav-icon", IconBell {} }
                        span { class: "nav-label", "notifications" }
                    }
                    Link { to: Route::SourceBookmarks { q: "".into() }, active_class: "active",
                        span { class: "nav-icon", IconBookmark {} }
                        span { class: "nav-label", "bookmarks" }
                    }
                    Link { to: Route::Compose {}, active_class: "active",
                        span { class: "nav-icon", IconPencil {} }
                        span { class: "nav-label", "compose" }
                    }
                    Link { to: Route::Settings {}, active_class: "active",
                        span { class: "nav-icon", IconGear {} }
                        span { class: "nav-label", "settings" }
                    }
                    a {
                        href: "#",
                        onclick: move |e| {
                            e.prevent_default();
                            *show_palette.write() = true;
                        },
                        span { class: "nav-icon", IconCommand {} }
                        span { class: "nav-label", "palette" }
                        span { class: "kbd", "⌘K" }
                    }
                    a {
                        href: "#",
                        onclick: move |e| {
                            e.prevent_default();
                            *show_help.write() = true;
                        },
                        span { class: "nav-icon", IconHelp {} }
                        span { class: "nav-label", "help" }
                    }
                }
            }
            main { class: "content",
                Outlet::<Route> {}
            }
        }
        if show_help() {
            HelpOverlay { on_close: move |_| { *show_help.write() = false; } }
        }
        if show_palette() {
            CommandPalette { on_close: move |_| { *show_palette.write() = false; } }
        }
        ToastContainer {}
    }
}
