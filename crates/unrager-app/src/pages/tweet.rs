use crate::api::{StreamEvent, stream_sse, use_client};
use crate::components::{StreamingPane, ThreadPanel};
use crate::state::AppState;
use dioxus::prelude::*;
use futures::StreamExt;
use unrager_model::{AskPreset, ThreadView, TokenEvent};

#[component]
pub fn TweetDetail(id: String) -> Element {
    let client = use_client();
    let state = use_context::<Signal<AppState>>();
    let mut view = use_signal(|| Option::<ThreadView>::None);
    let mut error = use_signal(|| Option::<String>::None);
    let mut translated = use_signal(String::new);
    let mut translating = use_signal(|| false);
    let mut ask_text = use_signal(String::new);
    let mut ask_streaming = use_signal(|| false);

    let id_for_load = id.clone();
    let client_for_load = client.clone();
    use_effect(move || {
        let client = client_for_load.clone();
        let tid = id_for_load.clone();
        spawn(async move {
            match client.thread(&tid).await {
                Ok(v) => view.set(Some(v)),
                Err(e) => error.set(Some(e.to_string())),
            }
        });
    });

    let on_like = {
        let client = client.clone();
        EventHandler::new(move |tid: String| {
            let client = client.clone();
            let tid_for_toggle = tid.clone();
            spawn(async move {
                let _ = client.like(&tid).await;
            });
            if let Some(v) = view.write().as_mut() {
                toggle_like(&mut v.focal, &tid_for_toggle);
                for t in v.replies.iter_mut() {
                    toggle_like(t, &tid_for_toggle);
                }
                for t in v.ancestors.iter_mut() {
                    toggle_like(t, &tid_for_toggle);
                }
            }
        })
    };

    let base = state.read().server_url.clone();

    let id_for_translate = id.clone();
    let base_for_translate = base.clone();
    let run_translate = move |_| {
        let url = format!(
            "{}/api/sse/translate?tweet_id={}",
            base_for_translate.trim_end_matches('/'),
            urlencoding::encode(&id_for_translate)
        );
        translated.set(String::new());
        translating.set(true);
        spawn(async move {
            let mut stream = Box::pin(stream_sse(&url));
            while let Some(ev) = stream.next().await {
                if let Ok(StreamEvent { data, .. }) = ev {
                    if data == "[DONE]" {
                        break;
                    }
                    if let Ok(t) = serde_json::from_str::<TokenEvent>(&data) {
                        if t.done {
                            break;
                        }
                        translated.write().push_str(&t.token);
                    }
                }
            }
            translating.set(false);
        });
    };

    let run_ask = use_callback(move |preset: AskPreset| {
        let url = format!(
            "{}/api/sse/ask?tweet_id={}&preset={}",
            base.trim_end_matches('/'),
            urlencoding::encode(&id),
            preset.as_str()
        );
        ask_text.set(String::new());
        ask_streaming.set(true);
        spawn(async move {
            let mut stream = Box::pin(stream_sse(&url));
            while let Some(ev) = stream.next().await {
                if let Ok(StreamEvent { data, .. }) = ev {
                    if data == "[DONE]" {
                        break;
                    }
                    if let Ok(t) = serde_json::from_str::<TokenEvent>(&data) {
                        if t.done {
                            break;
                        }
                        ask_text.write().push_str(&t.token);
                    }
                }
            }
            ask_streaming.set(false);
        });
    });

    rsx! {
        div { class: "topbar",
            h2 { "tweet" }
            div {
                button { onclick: run_translate, disabled: translating(),
                    if translating() { "translating..." } else { "translate" }
                }
            }
        }
        if let Some(e) = error() {
            div { class: "banner", style: "color: var(--danger)", "{e}" }
        }
        if let Some(v) = view() {
            ThreadPanel { view: v, on_like }
        } else {
            div { class: "loading", "loading thread..." }
        }
        if !translated().is_empty() || translating() {
            StreamingPane {
                text: translated(),
                streaming: translating(),
                title: Some("translation".into()),
            }
        }
        div { style: "margin-top: 16px;",
            h3 { "ask" }
            div { class: "tab-row",
                button { onclick: move |_| run_ask.call(AskPreset::Explain), "explain" }
                button { onclick: move |_| run_ask.call(AskPreset::Summary), "summary" }
                button { onclick: move |_| run_ask.call(AskPreset::Counter), "counter" }
                button { onclick: move |_| run_ask.call(AskPreset::Eli5), "ELI5" }
                button { onclick: move |_| run_ask.call(AskPreset::Entities), "entities" }
            }
            if !ask_text().is_empty() || ask_streaming() {
                StreamingPane {
                    text: ask_text(),
                    streaming: ask_streaming(),
                    title: None,
                }
            }
        }
    }
}

fn toggle_like(t: &mut unrager_model::Tweet, id: &str) {
    if t.rest_id == id {
        t.favorited = !t.favorited;
        if t.favorited {
            t.like_count += 1;
        } else {
            t.like_count = t.like_count.saturating_sub(1);
        }
    }
}
