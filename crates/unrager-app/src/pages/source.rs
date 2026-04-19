use crate::api::{ApiError, StreamEvent, stream_sse, use_client};
use crate::components::icons::{IconHeart, IconRefresh, IconReply};
use crate::components::{ErrorBanner, TweetCard};
use crate::observer;
use crate::routes::Route;
use crate::state::{AppState, ToastKind};
use chrono::{DateTime, Utc};
use dioxus::prelude::*;
use futures::StreamExt;
use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::rc::Rc;
use unrager_model::{FeedMode, FilterVerdictEvent, Notification, TimelinePage, Tweet, Verdict};

const SENTINEL_ID: &str = "unrager-feed-sentinel";
const TWEET_SEEN_ATTR: &str = "data-seen-id";

#[derive(Clone, PartialEq)]
enum Fetcher {
    Home { following: bool },
    User { handle: String },
    Search { q: String, product: String },
    Mentions,
    Bookmarks { q: String },
}

async fn load_page(
    client: &crate::api::Client,
    f: &Fetcher,
    cursor: Option<String>,
) -> Result<TimelinePage, ApiError> {
    match f {
        Fetcher::Home { following } => client.home(*following, cursor.as_deref()).await,
        Fetcher::User { handle } => client.user_tweets(handle, cursor.as_deref()).await,
        Fetcher::Search { q, product } => client.search(q, product, cursor.as_deref()).await,
        Fetcher::Mentions => client.mentions(cursor.as_deref()).await,
        Fetcher::Bookmarks { q } => client.bookmarks(q, cursor.as_deref()).await,
    }
}

#[component]
fn FeedView(fetcher: Fetcher, title: String) -> Element {
    let client = use_client();
    let state = use_context::<Signal<AppState>>();
    let mut tweets = use_signal(Vec::<Tweet>::new);
    let mut cursor = use_signal(|| Option::<String>::None);
    let mut loading = use_signal(|| false);
    let mut error = use_signal(|| Option::<String>::None);
    let mut verdicts = use_signal(HashMap::<String, Verdict>::new);
    let mut selected_idx = use_signal(|| 0usize);

    let fetcher_sig = use_signal(|| fetcher.clone());

    // Reset when fetcher changes
    use_effect(move || {
        let _ = fetcher_sig();
        tweets.set(Vec::new());
        cursor.set(None);
        verdicts.set(HashMap::new());
        selected_idx.set(0);
    });

    // Initial load
    let client_for_load = client.clone();
    use_effect(move || {
        let client = client_for_load.clone();
        let f = fetcher_sig();
        if !tweets.read().is_empty() {
            return;
        }
        spawn(async move {
            loading.set(true);
            match load_page(&client, &f, None).await {
                Ok(page) => {
                    tweets.set(page.tweets);
                    cursor.set(page.cursor);
                }
                Err(e) => error.set(Some(e.to_string())),
            }
            loading.set(false);
        });
    });

    // Filter SSE when filter_enabled and we have tweets
    use_effect(move || {
        let enabled = state.read().filter_enabled;
        let t_list = tweets.read().clone();
        if !enabled || t_list.is_empty() {
            return;
        }
        let base = state.read().server_url.clone();
        let ids: Vec<String> = t_list
            .iter()
            .map(|t| t.rest_id.clone())
            .filter(|id| !verdicts.read().contains_key(id))
            .collect();
        if ids.is_empty() {
            return;
        }
        let url = format!(
            "{}/api/sse/filter?ids={}",
            base.trim_end_matches('/'),
            urlencoding::encode(&ids.join(","))
        );
        spawn(async move {
            let mut stream = Box::pin(stream_sse(&url));
            while let Some(ev) = stream.next().await {
                if let Ok(StreamEvent { data, .. }) = ev {
                    if data == "[DONE]" {
                        break;
                    }
                    if let Ok(v) = serde_json::from_str::<FilterVerdictEvent>(&data) {
                        verdicts.write().insert(v.id, v.verdict);
                    }
                }
            }
        });
    });

    let client_for_like = client.clone();
    let on_like = EventHandler::new(move |id: String| {
        let client = client_for_like.clone();
        let id_for_spawn = id.clone();
        spawn(async move {
            let _ = client.like(&id_for_spawn).await;
        });
        if let Some(t) = tweets.write().iter_mut().find(|t| t.rest_id == id) {
            t.favorited = !t.favorited;
            if t.favorited {
                t.like_count += 1;
            } else {
                t.like_count = t.like_count.saturating_sub(1);
            }
        }
    });

    let client_for_more = client.clone();
    let load_more = move |_| {
        if loading() {
            return;
        }
        let cur = cursor();
        if cur.is_none() {
            return;
        }
        let client = client_for_more.clone();
        let f = fetcher_sig();
        spawn(async move {
            loading.set(true);
            match load_page(&client, &f, cur).await {
                Ok(page) => {
                    tweets.write().extend(page.tweets);
                    cursor.set(page.cursor);
                }
                Err(e) => error.set(Some(e.to_string())),
            }
            loading.set(false);
        });
    };

    // Infinite scroll sentinel: when the bottom sentinel becomes visible, load more.
    let client_for_scroll = client.clone();
    let scroll_observer = use_hook(|| {
        let cb: observer::VisibleIdsCb = Rc::new(RefCell::new(move |ids: Vec<String>| {
            if ids.contains(&SENTINEL_ID.to_string()) {
                // trampoline through a signal-safe path
                let client = client_for_scroll.clone();
                let f_now = fetcher_sig();
                let cur = cursor();
                if loading() || cur.is_none() {
                    return;
                }
                spawn(async move {
                    loading.set(true);
                    match load_page(&client, &f_now, cur).await {
                        Ok(page) => {
                            tweets.write().extend(page.tweets);
                            cursor.set(page.cursor);
                        }
                        Err(e) => error.set(Some(e.to_string())),
                    }
                    loading.set(false);
                });
            }
        }));
        Rc::new(RefCell::new(observer::observe_visibility(
            "data-feed-sentinel",
            cb,
        )))
    });

    // Seen tracking: observe tweet elements; batch IDs and POST.
    let client_for_seen = client.clone();
    let seen_sent: Rc<RefCell<HashSet<String>>> =
        use_hook(|| Rc::new(RefCell::new(HashSet::new())));
    let seen_observer = use_hook(|| {
        let sent = seen_sent.clone();
        let client_for_cb = client_for_seen.clone();
        let cb: observer::VisibleIdsCb = Rc::new(RefCell::new(move |ids: Vec<String>| {
            let mut new_ids: Vec<String> = Vec::new();
            {
                let mut guard = sent.borrow_mut();
                for id in ids {
                    if guard.insert(id.clone()) {
                        new_ids.push(id);
                    }
                }
            }
            if new_ids.is_empty() {
                return;
            }
            let client = client_for_cb.clone();
            spawn(async move {
                let _ = client.mark_seen(&new_ids).await;
            });
        }));
        Rc::new(RefCell::new(observer::observe_visibility(
            TWEET_SEEN_ATTR,
            cb,
        )))
    });

    // Re-attach observers after the DOM updates with new tweets
    use_effect(move || {
        let _ = tweets.read();
        let _ = cursor.read();
        #[cfg(target_arch = "wasm32")]
        {
            if let Some(guard) = scroll_observer.borrow().as_ref() {
                observer::observe_element_by_id(&guard.observer, SENTINEL_ID);
            }
            if let Some(guard) = seen_observer.borrow().as_ref() {
                observer::observe_all_by_attr(&guard.observer, TWEET_SEEN_ATTR);
            }
        }
        #[cfg(not(target_arch = "wasm32"))]
        {
            let _ = scroll_observer.clone();
            let _ = seen_observer.clone();
        }
    });

    let tweets_read = tweets();
    let filter_enabled = state.read().filter_enabled;
    let metrics = state.read().metrics_visible;
    let verdict_map = verdicts();

    let client_for_refresh = client.clone();
    let refresh = move |_| {
        if loading() {
            return;
        }
        let client = client_for_refresh.clone();
        let f = fetcher_sig();
        spawn(async move {
            loading.set(true);
            match load_page(&client, &f, None).await {
                Ok(page) => {
                    let count = page.tweets.len();
                    tweets.set(page.tweets);
                    cursor.set(page.cursor);
                    verdicts.set(HashMap::new());
                    let mut s = state;
                    s.write()
                        .show_toast(format!("refreshed · {count} tweets"), ToastKind::Success);
                }
                Err(e) => {
                    let msg = e.to_string();
                    error.set(Some(msg.clone()));
                    let mut s = state;
                    s.write().show_toast(msg, ToastKind::Error);
                }
            }
            loading.set(false);
        });
    };

    let on_keydown = move |e: Event<KeyboardData>| {
        let key = e.key();
        let n = tweets.read().len();
        if n == 0 {
            return;
        }
        match &key {
            Key::Character(s) if s == "j" => {
                e.prevent_default();
                let next = (selected_idx() + 1).min(n.saturating_sub(1));
                selected_idx.set(next);
                scroll_selected_into_view(next, &tweets.read());
            }
            Key::Character(s) if s == "k" => {
                e.prevent_default();
                let prev = selected_idx().saturating_sub(1);
                selected_idx.set(prev);
                scroll_selected_into_view(prev, &tweets.read());
            }
            Key::Character(s) if s == "g" => {
                e.prevent_default();
                selected_idx.set(0);
                scroll_selected_into_view(0, &tweets.read());
            }
            Key::Character(s) if s == "G" => {
                e.prevent_default();
                let last = n.saturating_sub(1);
                selected_idx.set(last);
                scroll_selected_into_view(last, &tweets.read());
            }
            Key::Character(s) if s == "l" => {
                e.prevent_default();
                if let Some(t) = tweets.read().get(selected_idx()).cloned() {
                    on_like.call(t.rest_id);
                }
            }
            Key::Enter => {
                if let Some(t) = tweets.read().get(selected_idx()).cloned() {
                    e.prevent_default();
                    use_navigator().push(Route::TweetDetail { id: t.rest_id });
                }
            }
            _ => {}
        }
    };

    rsx! {
        div { class: "feed-root", tabindex: "0", onkeydown: on_keydown,
            div { class: "topbar",
                h2 { "{title}" }
                div { class: "topbar-actions",
                    if tweets_read.is_empty() && loading() {
                        span { class: "topbar-status", "loading..." }
                    }
                    button {
                        class: "icon-btn refresh-btn",
                        title: "refresh",
                        disabled: loading(),
                        onclick: refresh,
                        IconRefresh {}
                    }
                }
            }
        if let Some(e) = error() {
            ErrorBanner { message: e }
        }
        if filter_enabled {
            div { class: "banner",
                span { "filter on — {verdicts().len()} / {tweets_read.len()} classified" }
            }
        }
        div { class: "list",
            for (i, t) in tweets_read.iter().enumerate() {
                {
                    let v = verdict_map.get(&t.rest_id).copied();
                    let hidden = filter_enabled && matches!(v, Some(Verdict::Hide));
                    if hidden {
                        rsx! { Fragment {} }
                    } else {
                        rsx! {
                            div { key: "{t.rest_id}",
                                "data-seen-id": "{t.rest_id}",
                                TweetCard {
                                    tweet: t.clone(),
                                    selected: i == selected_idx(),
                                    verdict: v,
                                    show_metrics: metrics,
                                    on_like,
                                }
                            }
                        }
                    }
                }
            }
        }
        div {
            id: SENTINEL_ID,
            "data-feed-sentinel": SENTINEL_ID,
            class: "feed-sentinel",
            if loading() {
                span { class: "sentinel-label", "loading more…" }
            } else if cursor().is_some() {
                button { onclick: load_more, "load more" }
            } else if !tweets_read.is_empty() {
                span { class: "sentinel-end", "end of feed" }
            }
        }
        }
    }
}

#[cfg(target_arch = "wasm32")]
fn scroll_selected_into_view(idx: usize, tweets: &[Tweet]) {
    use wasm_bindgen::JsCast;
    let Some(t) = tweets.get(idx) else { return };
    if let Some(doc) = web_sys::window().and_then(|w| w.document())
        && let Ok(nodes) = doc.query_selector_all(&format!("[data-seen-id=\"{}\"]", t.rest_id))
        && let Some(node) = nodes.item(0)
        && let Ok(el) = node.dyn_into::<web_sys::Element>()
    {
        let opts = web_sys::ScrollIntoViewOptions::new();
        opts.set_behavior(web_sys::ScrollBehavior::Smooth);
        opts.set_block(web_sys::ScrollLogicalPosition::Nearest);
        el.scroll_into_view_with_scroll_into_view_options(&opts);
    }
}

#[cfg(not(target_arch = "wasm32"))]
fn scroll_selected_into_view(_idx: usize, _tweets: &[Tweet]) {}

#[component]
pub fn SourceHome() -> Element {
    let state = use_context::<Signal<AppState>>();
    let mut feed_mode = use_signal(|| state.read().feed_mode);
    let mut following = use_signal(|| false);

    use_effect(move || {
        let mut s = state;
        s.write().feed_mode = feed_mode();
    });

    let fetcher = Fetcher::Home {
        following: following(),
    };
    let title = if following() {
        "home: Following".to_string()
    } else {
        "home: For You".to_string()
    };

    rsx! {
        div { class: "tab-row",
            button {
                class: if !following() { "active" } else { "" },
                onclick: move |_| following.set(false),
                "For You"
            }
            button {
                class: if following() { "active" } else { "" },
                onclick: move |_| following.set(true),
                "Following"
            }
            button {
                class: if matches!(feed_mode(), FeedMode::Originals) { "active" } else { "" },
                onclick: move |_| feed_mode.set(match feed_mode() {
                    FeedMode::All => FeedMode::Originals,
                    FeedMode::Originals => FeedMode::All,
                }),
                if matches!(feed_mode(), FeedMode::Originals) { "originals" } else { "all" }
            }
        }
        FeedView { fetcher, title }
    }
}

#[component]
pub fn SourceUser(handle: String) -> Element {
    let title = format!("@{handle}");
    rsx! { FeedView { fetcher: Fetcher::User { handle }, title } }
}

#[component]
pub fn SourceSearch(product: String, q: String) -> Element {
    let title = format!("search: {q} [{product}]");
    rsx! { FeedView { fetcher: Fetcher::Search { q, product }, title } }
}

#[component]
pub fn SourceMentions() -> Element {
    rsx! { FeedView { fetcher: Fetcher::Mentions, title: "mentions".to_string() } }
}

#[component]
pub fn SourceBookmarks(q: String) -> Element {
    let title: String = if q.is_empty() {
        "bookmarks".to_string()
    } else {
        format!("bookmarks: {q}")
    };
    rsx! { FeedView { fetcher: Fetcher::Bookmarks { q }, title } }
}

#[component]
pub fn SourceNotifs() -> Element {
    let client = use_client();
    let mut items = use_signal(Vec::<Notification>::new);
    let mut cursor = use_signal(|| Option::<String>::None);
    let mut loading = use_signal(|| false);
    let mut error = use_signal(|| Option::<String>::None);

    let client_for_load = client.clone();
    use_effect(move || {
        let client = client_for_load.clone();
        spawn(async move {
            loading.set(true);
            match client.notifications(None).await {
                Ok(page) => {
                    items.set(page.notifications);
                    cursor.set(page.cursor);
                }
                Err(e) => error.set(Some(e.to_string())),
            }
            loading.set(false);
        });
    });

    let client_for_more = client.clone();
    let load_more = move |_| {
        if loading() {
            return;
        }
        let client = client_for_more.clone();
        let cur = cursor();
        spawn(async move {
            loading.set(true);
            match client.notifications(cur.as_deref()).await {
                Ok(page) => {
                    items.write().extend(page.notifications);
                    cursor.set(page.cursor);
                }
                Err(e) => error.set(Some(e.to_string())),
            }
            loading.set(false);
        });
    };

    rsx! {
        div { class: "topbar", h2 { "notifications" } }
        if let Some(e) = error() {
            div { class: "banner", style: "color: var(--danger)", "{e}" }
        }
        for n in items.read().iter() {
            NotificationRow { key: "{n.id}", notif: n.clone() }
        }
        div { style: "text-align:center; padding: 14px;",
            if cursor().is_some() {
                button { onclick: load_more, disabled: loading(),
                    if loading() { "loading..." } else { "load more" }
                }
            } else if !items.read().is_empty() {
                span { style: "color: var(--fg-mute)", "end of notifications" }
            }
        }
    }
}

#[component]
fn NotificationRow(notif: Notification) -> Element {
    let actors_str = if notif.actors.is_empty() {
        "(unknown)".to_string()
    } else if notif.actors.len() == 1 {
        let a = &notif.actors[0];
        format!("{} @{}", a.name, a.handle)
    } else {
        let first = &notif.actors[0];
        format!(
            "{} @{} + {} other{}",
            first.name,
            first.handle,
            notif.actors.len() - 1,
            if notif.actors.len() == 2 { "" } else { "s" }
        )
    };

    let first_actor = notif.actors.first().cloned();
    let kind_label = notif.kind.to_ascii_lowercase();
    let kind_class = kind_label.clone();
    let time = compact_time(&notif.timestamp);
    let iso = notif.timestamp.to_rfc3339();

    rsx! {
        article { class: "notif",
            span { class: "notif-icon {kind_class}",
                {notif_icon(&notif.kind)}
            }
            div { class: "notif-body",
                div { class: "notif-head",
                    if let Some(a) = first_actor.as_ref() {
                        Link { to: Route::Profile { handle: a.handle.clone() },
                            class: "notif-actors",
                            "{actors_str}"
                        }
                    } else {
                        span { class: "notif-actors", "{actors_str}" }
                    }
                    span { class: "kind-pill {kind_class}", "{kind_label}" }
                    span { class: "notif-time", title: "{iso}", "{time}" }
                }
                if let Some(snip) = notif.target_tweet_snippet.as_ref() {
                    if let Some(tid) = notif.target_tweet_id.as_ref() {
                        Link { to: Route::TweetDetail { id: tid.clone() },
                            class: "notif-snippet-link",
                            div { class: "notif-snippet", "{snip}" }
                        }
                    } else {
                        div { class: "notif-snippet", "{snip}" }
                    }
                }
                if let Some(lc) = notif.target_tweet_like_count {
                    div { class: "notif-meta",
                        IconHeart { filled: false }
                        span { "{lc} likes on target" }
                    }
                }
            }
        }
    }
}

fn notif_icon(kind: &str) -> Element {
    match kind.to_ascii_lowercase().as_str() {
        "like" => rsx! { IconHeart { filled: true } },
        "reply" | "mention" | "quote" | "retweet" | "follow" => rsx! { IconReply {} },
        _ => rsx! { span { "·" } },
    }
}

fn compact_time(ts: &DateTime<Utc>) -> String {
    let now = Utc::now();
    let d = now.signed_duration_since(*ts);
    if d.num_seconds() < 60 {
        format!("{}s", d.num_seconds().max(0))
    } else if d.num_minutes() < 60 {
        format!("{}m", d.num_minutes())
    } else if d.num_hours() < 24 {
        format!("{}h", d.num_hours())
    } else if d.num_days() < 7 {
        format!("{}d", d.num_days())
    } else {
        ts.format("%b %-d").to_string()
    }
}
