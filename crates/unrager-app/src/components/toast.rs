use crate::state::{AppState, ToastKind};
use dioxus::prelude::*;

#[component]
pub fn ToastContainer() -> Element {
    let state = use_context::<Signal<AppState>>();
    let toasts = state.read().toasts.clone();

    rsx! {
        if !toasts.is_empty() {
            div { class: "toast-wrap",
                for t in toasts.iter() {
                    ToastItem { key: "{t.id}", id: t.id, message: t.message.clone(), kind: t.kind }
                }
            }
        }
    }
}

#[component]
fn ToastItem(id: u64, message: String, kind: ToastKind) -> Element {
    let mut state = use_context::<Signal<AppState>>();

    use_effect(move || {
        spawn(async move {
            sleep_ms(2800).await;
            state.write().remove_toast(id);
        });
    });

    let class = match kind {
        ToastKind::Info => "toast info",
        ToastKind::Success => "toast success",
        ToastKind::Error => "toast error",
    };

    rsx! {
        div {
            class: "{class}",
            onclick: move |_| state.write().remove_toast(id),
            "{message}"
        }
    }
}

#[cfg(target_arch = "wasm32")]
async fn sleep_ms(ms: u32) {
    gloo_timers::future::TimeoutFuture::new(ms).await;
}

#[cfg(not(target_arch = "wasm32"))]
async fn sleep_ms(ms: u32) {
    tokio::time::sleep(std::time::Duration::from_millis(ms as u64)).await;
}
