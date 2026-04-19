use dioxus::prelude::*;

mod api;
mod components;
mod observer;
mod pages;
mod routes;
mod state;
mod style;

use routes::Route;

fn main() {
    dioxus::launch(App);
}

#[component]
fn App() -> Element {
    use_context_provider(|| Signal::new(state::AppState::load()));

    #[cfg(target_arch = "wasm32")]
    register_service_worker();

    rsx! {
        document::Meta { name: "viewport", content: "width=device-width, initial-scale=1, viewport-fit=cover" }
        document::Meta { name: "theme-color", content: "#0e0e10" }
        document::Meta { name: "description", content: "A calm Twitter/X client with a local-LLM rage filter." }
        document::Meta { name: "apple-mobile-web-app-capable", content: "yes" }
        document::Meta { name: "apple-mobile-web-app-status-bar-style", content: "black-translucent" }
        document::Meta { name: "apple-mobile-web-app-title", content: "unrager" }
        document::Link { rel: "manifest", href: "/manifest.webmanifest" }
        document::Link { rel: "icon", r#type: "image/svg+xml", href: "/icon.svg" }
        document::Link { rel: "apple-touch-icon", href: "/icon.svg" }
        document::Style { {style::GLOBAL_CSS} }
        Router::<Route> {}
    }
}

#[cfg(target_arch = "wasm32")]
fn register_service_worker() {
    use wasm_bindgen::JsCast;
    use wasm_bindgen::prelude::*;
    let Some(win) = web_sys::window() else { return };
    let navigator = win.navigator();
    if js_sys::Reflect::has(&navigator, &JsValue::from_str("serviceWorker")).unwrap_or(false) {
        let onload = Closure::wrap(Box::new(move || {
            if let Some(w) = web_sys::window() {
                let sw = w.navigator().service_worker();
                let _ = sw.register("/sw.js");
            }
        }) as Box<dyn FnMut()>);
        let _ = win.add_event_listener_with_callback("load", onload.as_ref().unchecked_ref());
        onload.forget();
    }
}
