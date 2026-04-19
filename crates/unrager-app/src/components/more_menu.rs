use crate::state::{AppState, ToastKind};
use dioxus::prelude::*;
use unrager_model::Tweet;

#[derive(Props, PartialEq, Clone)]
pub struct MoreMenuProps {
    pub tweet: Tweet,
    pub on_close: EventHandler<()>,
}

#[component]
pub fn MoreMenu(props: MoreMenuProps) -> Element {
    let mut state = use_context::<Signal<AppState>>();
    let t = props.tweet.clone();

    let copy_link = {
        let url = t.url.clone();
        move |_| {
            copy_text(&url);
            state.write().show_toast("link copied", ToastKind::Success);
            props.on_close.call(());
        }
    };
    let copy_id = {
        let id = t.rest_id.clone();
        move |_| {
            copy_text(&id);
            state
                .write()
                .show_toast("tweet id copied", ToastKind::Success);
            props.on_close.call(());
        }
    };
    let copy_json = {
        let tweet = t.clone();
        move |_| {
            let json = serde_json::to_string_pretty(&tweet).unwrap_or_default();
            copy_text(&json);
            state.write().show_toast("json copied", ToastKind::Success);
            props.on_close.call(());
        }
    };
    let open_fixupx = {
        let url = t.url.clone();
        move |_| {
            let fx = url.replace("x.com", "fixupx.com");
            copy_text(&fx);
            state
                .write()
                .show_toast("fixupx link copied", ToastKind::Success);
            props.on_close.call(());
        }
    };
    let open_external = {
        let url = t.url.clone();
        move |_| {
            open_url(&url);
            props.on_close.call(());
        }
    };

    rsx! {
        div {
            class: "more-backdrop",
            onclick: move |e: Event<MouseData>| {
                e.stop_propagation();
                props.on_close.call(());
            },
            div {
                class: "more-menu",
                onclick: move |e: Event<MouseData>| e.stop_propagation(),
                button { class: "more-item", onclick: copy_link, "Copy link" }
                button { class: "more-item", onclick: open_fixupx, "Copy fixupx link" }
                button { class: "more-item", onclick: copy_id, "Copy tweet ID" }
                button { class: "more-item", onclick: copy_json, "Copy JSON" }
                div { class: "more-sep" }
                button { class: "more-item", onclick: open_external, "Open on x.com" }
            }
        }
    }
}

fn copy_text(text: &str) {
    #[cfg(target_arch = "wasm32")]
    {
        if let Some(win) = web_sys::window() {
            let clip = win.navigator().clipboard();
            let _ = clip.write_text(text);
        }
    }
    #[cfg(not(target_arch = "wasm32"))]
    {
        let _ = text;
    }
}

fn open_url(url: &str) {
    #[cfg(target_arch = "wasm32")]
    {
        if let Some(win) = web_sys::window() {
            let _ = win.open_with_url_and_target(url, "_blank");
        }
    }
    #[cfg(not(target_arch = "wasm32"))]
    {
        let _ = url;
    }
}
