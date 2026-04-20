use crate::components::TweetCard;
use dioxus::prelude::*;
use unrager_model::{ThreadView, Tweet};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReplySort {
    Top,
    Recent,
    Oldest,
}

impl ReplySort {
    pub fn label(self) -> &'static str {
        match self {
            ReplySort::Top => "Top",
            ReplySort::Recent => "Recent",
            ReplySort::Oldest => "Oldest",
        }
    }
}

fn sorted_replies(replies: &[Tweet], sort: ReplySort) -> Vec<Tweet> {
    let mut v = replies.to_vec();
    match sort {
        ReplySort::Top => v.sort_by_key(|t| {
            std::cmp::Reverse(t.like_count + t.reply_count + t.retweet_count + t.quote_count)
        }),
        ReplySort::Recent => v.sort_by_key(|t| std::cmp::Reverse(t.created_at)),
        ReplySort::Oldest => v.sort_by_key(|t| t.created_at),
    }
    v
}

#[component]
pub fn ThreadPanel(view: ThreadView, on_like: EventHandler<String>) -> Element {
    let mut sort = use_signal(|| ReplySort::Top);
    let reply_count = view.replies.len();

    rsx! {
        div { class: "thread",
            for t in view.ancestors.iter() {
                TweetCard {
                    key: "{t.rest_id}",
                    tweet: t.clone(),
                    on_like,
                }
            }
            div { class: "thread-focal",
                TweetCard {
                    tweet: view.focal.clone(),
                    clickable: false,
                    expanded_by_default: true,
                    on_like,
                }
            }
            if reply_count > 0 {
                div { class: "reply-sort",
                    span { class: "reply-sort-label",
                        {format!("{reply_count} repl{}", if reply_count == 1 { "y" } else { "ies" })}
                    }
                    div { class: "reply-sort-buttons",
                        for choice in [ReplySort::Top, ReplySort::Recent, ReplySort::Oldest] {
                            button {
                                key: "{choice.label()}",
                                class: if sort() == choice { "active" } else { "" },
                                onclick: move |_| sort.set(choice),
                                "{choice.label()}"
                            }
                        }
                    }
                }
                for t in sorted_replies(&view.replies, sort()).iter() {
                    TweetCard {
                        key: "{t.rest_id}",
                        tweet: t.clone(),
                        on_like,
                    }
                }
            }
        }
    }
}
