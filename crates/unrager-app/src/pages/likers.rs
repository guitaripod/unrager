use crate::api::use_client;
use crate::components::icons::{IconBack, IconUsers, IconVerified};
use crate::routes::Route;
use dioxus::prelude::*;

#[component]
pub fn Likers(tweet_id: String) -> Element {
    let client = use_client();
    let mut users = use_signal(Vec::<unrager_model::User>::new);
    let mut cursor = use_signal(|| Option::<String>::None);
    let mut error = use_signal(|| Option::<String>::None);
    let mut loading = use_signal(|| false);

    let tid_for_load = tweet_id.clone();
    let client_for_load = client.clone();
    use_effect(move || {
        let client = client_for_load.clone();
        let tid = tid_for_load.clone();
        spawn(async move {
            loading.set(true);
            match client.likers(&tid, None).await {
                Ok(page) => {
                    users.set(page.users);
                    cursor.set(page.cursor);
                }
                Err(e) => error.set(Some(e.to_string())),
            }
            loading.set(false);
        });
    });

    let tid_for_more = tweet_id.clone();
    let client_for_more = client.clone();
    let load_more = move |_| {
        if loading() {
            return;
        }
        let client = client_for_more.clone();
        let tid = tid_for_more.clone();
        let cur = cursor();
        spawn(async move {
            loading.set(true);
            match client.likers(&tid, cur.as_deref()).await {
                Ok(page) => {
                    users.write().extend(page.users);
                    cursor.set(page.cursor);
                }
                Err(e) => error.set(Some(e.to_string())),
            }
            loading.set(false);
        });
    };

    let tid_for_back = tweet_id.clone();

    rsx! {
        div { class: "topbar",
            h2 { "liked by" }
            Link { to: Route::TweetDetail { id: tid_for_back.clone() },
                button { class: "back-btn",
                    IconBack {}
                    span { "tweet" }
                }
            }
        }
        if let Some(e) = error() {
            div { class: "banner", style: "color: var(--danger)", "{e}" }
        }
        div { class: "user-list",
            for u in users.read().iter() {
                UserRow { key: "{u.rest_id}", user: u.clone() }
            }
        }
        div { style: "text-align:center; padding: 14px;",
            if cursor().is_some() {
                button { onclick: load_more, disabled: loading(),
                    if loading() { "loading..." } else { "load more" }
                }
            } else if !users.read().is_empty() {
                span { style: "color: var(--fg-mute)", "end of list" }
            }
        }
    }
}

#[component]
fn UserRow(user: unrager_model::User) -> Element {
    let ratio = if user.following > 0 {
        Some(user.followers as f64 / user.following as f64)
    } else {
        None
    };
    rsx! {
        Link { to: Route::Profile { handle: user.handle.clone() },
            div { class: "user-row",
                div { class: "user-row-head",
                    span { class: "name", "{user.name}" }
                    if user.verified {
                        IconVerified {}
                    }
                    span { class: "handle", "@{user.handle}" }
                }
                div { class: "metrics",
                    span { title: "followers",
                        IconUsers {}
                        span { "{short(user.followers)}" }
                    }
                    span { title: "following", "following {short(user.following)}" }
                    if let Some(r) = ratio {
                        span { title: "follower/following ratio", "ratio {r:.1}" }
                    }
                }
            }
        }
    }
}

fn short(n: u64) -> String {
    if n < 1_000 {
        n.to_string()
    } else if n < 1_000_000 {
        format!("{:.1}K", n as f64 / 1_000.0)
    } else {
        format!("{:.1}M", n as f64 / 1_000_000.0)
    }
}
