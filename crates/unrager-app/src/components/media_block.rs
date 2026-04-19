use crate::components::icons::{IconExternal, IconLink};
use crate::state::AppState;
use chrono::{DateTime, Utc};
use dioxus::prelude::*;
use unrager_model::{Media, MediaKind, PollOption};

#[component]
pub fn MediaBlock(media: Vec<Media>, tweet_id: String) -> Element {
    let state = use_context::<Signal<AppState>>();
    let base = state.read().server_url.clone();
    let single = media.len() == 1;
    rsx! {
        div { class: if single { "media single" } else { "media grid" },
            for (idx, m) in media.iter().enumerate() {
                MediaItem {
                    key: "{tweet_id}-{idx}",
                    media: m.clone(),
                    proxy_url: format!("{}/api/media/{}/{}", base.trim_end_matches('/'), tweet_id, idx),
                }
            }
        }
    }
}

#[component]
fn MediaItem(media: Media, proxy_url: String) -> Element {
    match &media.kind {
        MediaKind::Photo => rsx! {
            figure { class: "media-item photo",
                img {
                    src: "{proxy_url}",
                    alt: media.alt_text.clone().unwrap_or_default(),
                    loading: "lazy",
                }
                if let Some(alt) = media.alt_text.as_ref() {
                    if !alt.is_empty() {
                        figcaption { class: "alt-text", title: "alt text",
                            span { class: "alt-tag", "ALT" }
                            span { "{alt}" }
                        }
                    }
                }
            }
        },
        MediaKind::Video => rsx! {
            figure { class: "media-item video",
                video {
                    src: "{proxy_url}",
                    controls: true,
                    playsinline: true,
                    preload: "none",
                }
                if let Some(alt) = media.alt_text.as_ref() {
                    if !alt.is_empty() {
                        figcaption { class: "alt-text",
                            span { class: "alt-tag", "ALT" }
                            span { "{alt}" }
                        }
                    }
                }
            }
        },
        MediaKind::AnimatedGif => rsx! {
            figure { class: "media-item gif",
                video {
                    src: "{proxy_url}",
                    autoplay: true,
                    muted: true,
                    r#loop: true,
                    playsinline: true,
                }
                figcaption { class: "gif-badge", "GIF" }
            }
        },
        MediaKind::YouTube { video_id } => rsx! {
            div { class: "media-item youtube",
                iframe {
                    width: "100%",
                    height: "315",
                    src: "https://www.youtube.com/embed/{video_id}",
                    title: "YouTube video",
                    allow: "accelerometer; clipboard-write; encrypted-media; picture-in-picture",
                    allowfullscreen: true,
                }
                div { class: "yt-id", title: "youtube id: {video_id}", "YouTube · {video_id}" }
            }
        },
        MediaKind::LinkCard {
            title,
            description,
            domain,
            target_url,
        } => rsx! {
            a {
                class: "media-item linkcard-link",
                href: "{target_url}",
                target: "_blank",
                rel: "noopener",
                onclick: move |e: Event<MouseData>| e.stop_propagation(),
                div { class: "linkcard",
                    div { class: "title", "{title}" }
                    if !description.is_empty() {
                        p { class: "description", "{description}" }
                    }
                    div { class: "domain-row",
                        span { class: "domain",
                            IconLink {}
                            span { "{domain}" }
                        }
                        span { class: "external-hint",
                            IconExternal {}
                        }
                    }
                }
            }
        },
        MediaKind::Article {
            title,
            preview_text,
            article_id,
        } => rsx! {
            div { class: "media-item linkcard article",
                div { class: "article-badge", "ARTICLE" }
                div { class: "title", "{title}" }
                p { class: "description", "{preview_text}" }
                small { class: "article-id", title: "article id: {article_id}", "id: {article_id}" }
            }
        },
        MediaKind::Poll {
            options,
            counts_final,
            ends_at,
        } => rsx! {
            PollView {
                options: options.clone(),
                counts_final: *counts_final,
                ends_at: *ends_at,
            }
        },
    }
}

#[component]
fn PollView(
    options: Vec<PollOption>,
    counts_final: bool,
    ends_at: Option<DateTime<Utc>>,
) -> Element {
    let total: u64 = options.iter().map(|o| o.count).sum();
    let winner_idx = if counts_final && total > 0 {
        options
            .iter()
            .enumerate()
            .max_by_key(|(_, o)| o.count)
            .map(|(i, _)| i)
    } else {
        None
    };

    let status_line = if counts_final {
        "poll closed".to_string()
    } else if let Some(ends) = ends_at {
        let rem = ends.signed_duration_since(Utc::now());
        if rem.num_seconds() <= 0 {
            "ending...".into()
        } else if rem.num_minutes() < 60 {
            format!("ends in {}m", rem.num_minutes())
        } else if rem.num_hours() < 24 {
            format!("ends in {}h", rem.num_hours())
        } else {
            format!("ends in {}d", rem.num_days())
        }
    } else {
        "voting open".into()
    };

    rsx! {
        div { class: "media-item poll",
            for (i, opt) in options.iter().enumerate() {
                {
                    let pct = if total > 0 { (opt.count * 100) / total.max(1) } else { 0 };
                    let is_winner = winner_idx == Some(i);
                    rsx! {
                        div {
                            class: if is_winner { "opt winner" } else { "opt" },
                            div { class: "opt-bar", style: "width: {pct}%" }
                            div { class: "opt-row",
                                span { class: "opt-label", "{opt.label}" }
                                span { class: "opt-count",
                                    {format!("{}% · {}", pct, short(opt.count))}
                                }
                            }
                        }
                    }
                }
            }
            div { class: "poll-footer",
                span { "{short(total)} votes" }
                span { "·" }
                span { "{status_line}" }
                if let Some(ends) = ends_at {
                    span { "·" }
                    span { title: "{ends.to_rfc3339()}", {ends.format("%b %-d %H:%M").to_string()} }
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
