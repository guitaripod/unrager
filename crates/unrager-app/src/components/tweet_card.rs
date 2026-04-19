use crate::components::MediaBlock;
use crate::components::avatar::Avatar;
use crate::components::icons::{
    IconExternal, IconHeart, IconMore, IconReply, IconShare, IconVerified, IconViews,
};
use crate::components::more_menu::MoreMenu;
use crate::components::rich_text::RichText;
use crate::routes::Route;
use crate::state::{AppState, ToastKind};
use chrono::{DateTime, Utc};
use dioxus::prelude::*;
use unrager_model::{Tweet, Verdict};

const TEXT_CLAMP_CHARS: usize = 280;

#[derive(Props, PartialEq, Clone)]
pub struct TweetCardProps {
    pub tweet: Tweet,
    #[props(default)]
    pub selected: bool,
    #[props(default)]
    pub verdict: Option<Verdict>,
    #[props(default)]
    pub translated: Option<String>,
    #[props(default = true)]
    pub clickable: bool,
    #[props(default = true)]
    pub show_metrics: bool,
    #[props(default)]
    pub expanded_by_default: bool,
    pub on_like: Option<EventHandler<String>>,
}

#[component]
pub fn TweetCard(props: TweetCardProps) -> Element {
    let nav = use_navigator();
    let mut state = use_context::<Signal<AppState>>();
    let absolute_time = state.read().absolute_time;
    let t = &props.tweet;
    let id = t.rest_id.clone();
    let author_handle = t.author.handle.clone();
    let author_name = t.author.name.clone();
    let id_for_click = id.clone();
    let verdict_class = props.verdict.map(|v| match v {
        Verdict::Hide => "hide",
        Verdict::Keep => "keep",
    });

    let display_text = props.translated.as_deref().unwrap_or(&t.text).to_string();
    let text_long = display_text.chars().count() > TEXT_CLAMP_CHARS;
    let mut expanded = use_signal(|| props.expanded_by_default || !text_long);
    let mut show_more_menu = use_signal(|| false);

    let time_primary = if absolute_time {
        t.created_at.format("%b %-d · %H:%M").to_string()
    } else {
        relative_time(&t.created_at)
    };
    let time_title = t.created_at.format("%Y-%m-%d %H:%M UTC").to_string();
    let lang_badge = t
        .lang
        .as_deref()
        .filter(|l| !matches!(*l, "en" | "und" | "qme" | "qam" | "zxx" | ""));

    rsx! {
        article {
            class: if props.selected { "tweet selected" } else { "tweet" },
            onclick: move |e| {
                if props.clickable && !show_more_menu() {
                    e.stop_propagation();
                    nav.push(Route::TweetDetail { id: id_for_click.clone() });
                }
            },

            if let Some(parent) = t.in_reply_to_tweet_id.as_ref() {
                Link {
                    to: Route::TweetDetail { id: parent.clone() },
                    class: "reply-to-link",
                    onclick: move |e: Event<MouseData>| e.stop_propagation(),
                    div { class: "reply-to", "replying to conversation" }
                }
            }

            div { class: "tweet-body",
                div { class: "tweet-avatar",
                    Link {
                        to: Route::Profile { handle: author_handle.clone() },
                        onclick: move |e: Event<MouseData>| e.stop_propagation(),
                        Avatar {
                            name: author_name.clone(),
                            handle: author_handle.clone(),
                        }
                    }
                }

                div { class: "tweet-main",
                    div { class: "tweet-head",
                        Link {
                            to: Route::Profile { handle: author_handle.clone() },
                            class: "tweet-author",
                            onclick: move |e: Event<MouseData>| e.stop_propagation(),
                            span { class: "name", "{t.author.name}" }
                            if t.author.verified {
                                IconVerified {}
                            }
                            span { class: "handle", "@{t.author.handle}" }
                            span { class: "dot", "·" }
                            span { class: "time", title: "{time_title}", "{time_primary}" }
                        }
                        div { class: "tweet-head-right",
                            if let Some(l) = lang_badge {
                                span { class: "lang-badge", title: "language: {l}", "{l}" }
                            }
                            if let Some(v) = verdict_class {
                                span { class: "verdict {v}", {v.to_uppercase()} }
                            }
                            button {
                                class: "icon-btn more-btn",
                                title: "more",
                                onclick: move |e: Event<MouseData>| {
                                    e.stop_propagation();
                                    let v = !show_more_menu();
                                    show_more_menu.set(v);
                                },
                                IconMore {}
                            }
                        }
                    }

                    div { class: "tweet-text-wrap",
                        div {
                            class: if text_long && !expanded() { "tweet-text clamped" } else { "tweet-text" },
                            RichText { text: display_text.clone() }
                        }
                        if text_long {
                            button {
                                class: "show-more",
                                onclick: move |e: Event<MouseData>| {
                                    e.stop_propagation();
                                    let v = !expanded();
                                    expanded.set(v);
                                },
                                if expanded() { "Show less" } else { "Show more" }
                            }
                        }
                    }

                    if let Some(qt) = t.quoted_tweet.as_deref() {
                        QuotedTweet { tweet: qt.clone() }
                    }

                    if !t.media.is_empty() {
                        MediaBlock { media: t.media.clone(), tweet_id: id.clone() }
                    }

                    if props.show_metrics && t.view_count.is_some() {
                        if let Some(v) = t.view_count {
                            div { class: "views-row",
                                IconViews {}
                                span { class: "views-count", "{short_count(v)}" }
                                span { class: "views-label", "views" }
                                if t.like_count > 0 && v > 0 {
                                    span { class: "views-sep", "·" }
                                    span { class: "views-ratio",
                                        {format!("{:.2}% engagement", (t.like_count as f64 / v.max(1) as f64) * 100.0)}
                                    }
                                }
                            }
                        }
                    }

                    div { class: "action-row",
                        ActionButton {
                            icon: rsx! { IconReply {} },
                            count: t.reply_count,
                            label: "reply",
                            on_click: {
                                let reply_id = t.rest_id.clone();
                                EventHandler::new(move |_| {
                                    use_navigator().push(Route::Reply { tweet_id: reply_id.clone() });
                                })
                            },
                            variant: "reply",
                            active: false,
                        }
                        ActionButton {
                            icon: rsx! { IconHeart { filled: t.favorited } },
                            count: t.like_count,
                            label: "like",
                            on_click: {
                                let handler = props.on_like;
                                let id = id.clone();
                                EventHandler::new(move |_| {
                                    if let Some(h) = handler.as_ref() {
                                        h.call(id.clone());
                                    }
                                })
                            },
                            variant: "like",
                            active: t.favorited,
                        }
                        a {
                            class: "action-btn share-btn",
                            href: "{t.url}",
                            target: "_blank",
                            rel: "noopener",
                            title: "open on x.com",
                            onclick: move |e: Event<MouseData>| e.stop_propagation(),
                            IconExternal {}
                        }
                        ActionButton {
                            icon: rsx! { IconShare {} },
                            count: 0,
                            label: "copy link",
                            on_click: {
                                let url = t.url.clone();
                                EventHandler::new(move |_| {
                                    copy_to_clipboard(&url);
                                    state.write().show_toast("link copied", ToastKind::Success);
                                })
                            },
                            variant: "share",
                            active: false,
                        }
                    }
                }
            }

            if show_more_menu() {
                MoreMenu {
                    tweet: t.clone(),
                    on_close: move |_| show_more_menu.set(false),
                }
            }
        }
    }
}

#[component]
fn ActionButton(
    icon: Element,
    count: u64,
    label: &'static str,
    on_click: EventHandler<()>,
    variant: &'static str,
    active: bool,
) -> Element {
    let class = if active {
        format!("action-btn {variant} active")
    } else {
        format!("action-btn {variant}")
    };
    rsx! {
        button {
            class: "{class}",
            title: "{label}",
            onclick: move |e: Event<MouseData>| {
                e.stop_propagation();
                on_click.call(());
            },
            {icon}
            if count > 0 {
                span { class: "action-count", "{short_count(count)}" }
            }
        }
    }
}

#[component]
fn QuotedTweet(tweet: Tweet) -> Element {
    let state = use_context::<Signal<AppState>>();
    let absolute_time = state.read().absolute_time;
    let time_text = if absolute_time {
        tweet.created_at.format("%b %-d").to_string()
    } else {
        relative_time(&tweet.created_at)
    };
    let time_title = tweet.created_at.format("%Y-%m-%d %H:%M UTC").to_string();
    let tweet_id = tweet.rest_id.clone();
    let text = tweet.text.clone();
    let media = tweet.media.clone();

    rsx! {
        Link {
            to: Route::TweetDetail { id: tweet_id.clone() },
            class: "quoted-link",
            onclick: move |e: Event<MouseData>| e.stop_propagation(),
            div { class: "quoted",
                div { class: "quoted-head",
                    span { class: "name", "{tweet.author.name}" }
                    if tweet.author.verified {
                        IconVerified {}
                    }
                    span { class: "handle", "@{tweet.author.handle}" }
                    span { class: "dot", "·" }
                    span { class: "time", title: "{time_title}", "{time_text}" }
                }
                div { class: "quoted-text",
                    RichText { text }
                }
                if !media.is_empty() {
                    div { class: "quoted-media",
                        MediaBlock { media, tweet_id: tweet_id.clone() }
                    }
                }
            }
        }
    }
}

fn copy_to_clipboard(text: &str) {
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

fn short_count(n: u64) -> String {
    if n < 1_000 {
        return n.to_string();
    }
    if n < 1_000_000 {
        let k = n as f64 / 1_000.0;
        return if n < 10_000 {
            format!("{k:.1}K")
        } else {
            format!("{}K", k.round() as u64)
        };
    }
    if n < 1_000_000_000 {
        let m = n as f64 / 1_000_000.0;
        return if n < 10_000_000 {
            format!("{m:.1}M")
        } else {
            format!("{}M", m.round() as u64)
        };
    }
    let b = n as f64 / 1_000_000_000.0;
    format!("{b:.1}B")
}

fn relative_time(ts: &DateTime<Utc>) -> String {
    let now = Utc::now();
    let diff = now.signed_duration_since(*ts);
    if diff.num_seconds() < 60 {
        return format!("{}s", diff.num_seconds().max(0));
    }
    if diff.num_minutes() < 60 {
        return format!("{}m", diff.num_minutes());
    }
    if diff.num_hours() < 24 {
        return format!("{}h", diff.num_hours());
    }
    if diff.num_days() < 7 {
        return format!("{}d", diff.num_days());
    }
    if diff.num_days() < 365 {
        return ts.format("%b %-d").to_string();
    }
    ts.format("%b %-d '%y").to_string()
}
