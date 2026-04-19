use crate::api::{StreamEvent, stream_sse, use_client};
use crate::components::icons::{IconBrain, IconPin, IconVerified};
use crate::components::{ErrorBanner, StreamingPane, TweetCard};
use crate::routes::Route;
use crate::state::AppState;
use dioxus::prelude::*;
use futures::StreamExt;
use unrager_model::{BriefChunk, ProfileView, User};

#[component]
pub fn Profile(handle: String) -> Element {
    let client = use_client();
    let state = use_context::<Signal<AppState>>();
    let mut view = use_signal(|| Option::<ProfileView>::None);
    let mut error = use_signal(|| Option::<String>::None);
    let mut brief_text = use_signal(String::new);
    let mut brief_streaming = use_signal(|| false);
    let mut include_replies = use_signal(|| false);
    let mut loading = use_signal(|| true);

    let handle_for_load = handle.clone();
    let client_for_load = client.clone();
    use_effect(move || {
        let with_replies = include_replies();
        let client = client_for_load.clone();
        let h = handle_for_load.clone();
        loading.set(true);
        spawn(async move {
            match client.profile(&h, with_replies).await {
                Ok(p) => {
                    view.set(Some(p));
                    error.set(None);
                }
                Err(e) => error.set(Some(e.to_string())),
            }
            loading.set(false);
        });
    });

    let handle_for_brief = handle.clone();
    let base_for_brief = state.read().server_url.clone();
    let run_brief = move |_| {
        let url = format!(
            "{}/api/sse/brief?handle={}",
            base_for_brief.trim_end_matches('/'),
            urlencoding::encode(&handle_for_brief)
        );
        brief_text.set(String::new());
        brief_streaming.set(true);
        spawn(async move {
            let mut stream = Box::pin(stream_sse(&url));
            while let Some(ev) = stream.next().await {
                if let Ok(StreamEvent { data, .. }) = ev {
                    if data == "[DONE]" {
                        break;
                    }
                    if let Ok(c) = serde_json::from_str::<BriefChunk>(&data) {
                        if c.done {
                            break;
                        }
                        brief_text.write().push_str(&c.token);
                    }
                }
            }
            brief_streaming.set(false);
        });
    };

    let on_like = {
        let client = client.clone();
        EventHandler::new(move |id: String| {
            let client = client.clone();
            spawn(async move {
                let _ = client.like(&id).await;
            });
        })
    };

    rsx! {
        if let Some(e) = error() {
            ErrorBanner { message: e }
        }
        if let Some(v) = view() {
            UserHeader {
                user: v.user.clone(),
                brief_streaming: brief_streaming(),
                on_brief: run_brief,
            }
            if !brief_text().is_empty() || brief_streaming() {
                StreamingPane {
                    text: brief_text(),
                    streaming: brief_streaming(),
                    title: Some(format!("brief of @{}", v.user.handle)),
                }
            }
            if let Some(p) = &v.pinned {
                div { class: "section-head",
                    IconPin {}
                    span { "pinned" }
                }
                TweetCard { tweet: p.clone(), on_like }
            }
            div { class: "profile-tabs",
                button {
                    class: if !include_replies() { "active" } else { "" },
                    onclick: move |_| include_replies.set(false),
                    "Tweets"
                }
                button {
                    class: if include_replies() { "active" } else { "" },
                    onclick: move |_| include_replies.set(true),
                    "Tweets & Replies"
                }
                if loading() {
                    span { class: "profile-tabs-status", "loading…" }
                }
            }
            for t in v.recent.iter() {
                TweetCard { key: "{t.rest_id}", tweet: t.clone(), on_like }
            }
        } else if loading() {
            div { class: "loading", "loading profile..." }
        }
    }
}

#[component]
fn UserHeader(user: User, brief_streaming: bool, on_brief: EventHandler<MouseEvent>) -> Element {
    let ratio = if user.following > 0 {
        Some(user.followers as f64 / user.following as f64)
    } else {
        None
    };

    rsx! {
        div { class: "user-header",
            div { class: "user-head-row",
                h2 { class: "user-name",
                    span { "{user.name}" }
                    if user.verified {
                        IconVerified {}
                    }
                }
                button {
                    class: "brief-btn",
                    onclick: move |e| on_brief.call(e),
                    disabled: brief_streaming,
                    IconBrain {}
                    span { if brief_streaming { "briefing..." } else { "brief" } }
                }
            }
            div { class: "user-handle", "@{user.handle}" }
            div { class: "user-stats",
                span { title: "followers",
                    strong { {format_count(user.followers)} }
                    " followers"
                }
                span { title: "following",
                    strong { {format_count(user.following)} }
                    " following"
                }
                if let Some(r) = ratio {
                    span { class: "ratio-stat",
                        title: "follower/following ratio",
                        "ratio "
                        strong { {format!("{:.1}", r)} }
                    }
                }
            }
            div { class: "user-sub",
                Link {
                    to: Route::SourceUser { handle: user.handle.clone() },
                    class: "subtle-link",
                    "more tweets →"
                }
                span { class: "user-id", title: "user id: {user.rest_id}",
                    "id {user.rest_id}"
                }
            }
        }
    }
}

fn format_count(n: u64) -> String {
    if n < 1_000 {
        n.to_string()
    } else if n < 1_000_000 {
        format!("{:.1}K", n as f64 / 1_000.0)
    } else if n < 1_000_000_000 {
        format!("{:.1}M", n as f64 / 1_000_000.0)
    } else {
        format!("{:.2}B", n as f64 / 1_000_000_000.0)
    }
}
