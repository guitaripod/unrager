//! The reusable timeline component backing Home / Following / User / Search /
//! Mentions / Bookmarks. Fetches a page, renders tweet cards into a `ListBox`,
//! and loads more on scroll-to-bottom.

use crate::card::{CardCallbacks, build_tweet_card};
use crate::shared::{Ctx, Route, empty_state, error_state, loading_state};
use adw::prelude::*;
use relm4::prelude::*;
use std::rc::Rc;
use std::sync::Arc;
use unrager_gtk_core::model::{FeedStatusResponse, SearchProduct, TimelinePage, Tweet};
use unrager_gtk_core::{ApiClient, ApiError, format};

#[derive(Debug, Clone)]
pub enum FeedSource {
    HomeForYou,
    Following,
    Search {
        query: String,
        product: SearchProduct,
    },
    Mentions,
    Bookmarks(String),
}

pub struct FeedInit {
    pub ctx: Ctx,
    pub source: FeedSource,
}

pub struct Feed {
    ctx: Ctx,
    source: FeedSource,
    originals: bool,
    list: gtk::ListBox,
    tweets: Vec<Tweet>,
    cursor: Option<String>,
    loading: bool,
    exhausted: bool,
    /// "updated Nm ago" for store-backed Home feeds; empty hides the label.
    freshness: String,
}

#[derive(Debug)]
pub enum FeedInput {
    Reload,
    /// Rebuild the cards from the already-loaded tweets without refetching —
    /// used when a display preference (e.g. media size) changes, so the feed
    /// updates instantly and doesn't reorder.
    Rebuild,
    LoadMore,
    RowActivated(i32),
    ToggleOriginals(bool),
}

#[derive(Debug)]
pub enum FeedOutput {
    Open(Route),
}

#[derive(Debug)]
pub enum FeedCmd {
    Loaded {
        append: bool,
        page: Result<TimelinePage, ApiError>,
    },
    Status(Result<FeedStatusResponse, ApiError>),
}

#[relm4::component(pub)]
impl Component for Feed {
    type Init = FeedInit;
    type Input = FeedInput;
    type Output = FeedOutput;
    type CommandOutput = FeedCmd;

    view! {
        adw::ToolbarView {
            add_top_bar = &adw::HeaderBar {
                pack_start = &gtk::Button {
                    set_icon_name: "document-edit-symbolic",
                    set_tooltip_text: Some("Compose"),
                    connect_clicked[sender] => move |_| {
                        sender.output(FeedOutput::Open(Route::ComposeNew)).ok();
                    },
                },
                pack_end = &gtk::Button {
                    set_icon_name: "view-refresh-symbolic",
                    set_tooltip_text: Some("Refresh"),
                    connect_clicked => FeedInput::Reload,
                },
                #[name = "originals_toggle"]
                pack_end = &gtk::ToggleButton {
                    set_label: "Originals",
                    set_tooltip_text: Some("Hide replies, reposts and quotes"),
                    connect_toggled[sender] => move |toggle| {
                        sender.input(FeedInput::ToggleOriginals(toggle.is_active()));
                    },
                },
                pack_start = &gtk::Label {
                    add_css_class: "dim-label",
                    add_css_class: "caption",
                    set_margin_start: 4,
                    #[watch]
                    set_label: &model.freshness,
                    #[watch]
                    set_visible: !model.freshness.is_empty(),
                },
            },

            #[wrap(Some)]
            set_content = &gtk::ScrolledWindow {
                set_vexpand: true,
                set_hexpand: true,
                connect_edge_reached[sender] => move |_, pos| {
                    if pos == gtk::PositionType::Bottom {
                        sender.input(FeedInput::LoadMore);
                    }
                },

                adw::Clamp {
                    set_maximum_size: 640,
                    set_tightening_threshold: 560,

                    #[local_ref]
                    list_box -> gtk::ListBox {
                        connect_row_activated[sender] => move |_, row| {
                            sender.input(FeedInput::RowActivated(row.index()));
                        },
                    }
                }
            }
        }
    }

    fn init(
        init: Self::Init,
        root: Self::Root,
        sender: ComponentSender<Self>,
    ) -> ComponentParts<Self> {
        let list = gtk::ListBox::new();
        list.set_selection_mode(gtk::SelectionMode::None);
        list.add_css_class("feed-list");
        list.set_placeholder(Some(&loading_state()));

        let is_home = matches!(init.source, FeedSource::HomeForYou | FeedSource::Following);

        let model = Feed {
            ctx: init.ctx,
            source: init.source,
            originals: false,
            list: list.clone(),
            tweets: Vec::new(),
            cursor: None,
            loading: false,
            exhausted: false,
            freshness: String::new(),
        };

        let list_box = &list;
        let widgets = view_output!();
        widgets.originals_toggle.set_visible(is_home);
        sender.input(FeedInput::Reload);
        ComponentParts { model, widgets }
    }

    fn update(&mut self, message: Self::Input, sender: ComponentSender<Self>, _root: &Self::Root) {
        match message {
            FeedInput::Reload => {
                if self.loading {
                    return;
                }
                self.loading = true;
                self.list.set_placeholder(Some(&loading_state()));
                let api = self.ctx.api.clone();
                let source = self.source.clone();
                let originals = self.originals;
                sender.oneshot_command(async move {
                    FeedCmd::Loaded {
                        append: false,
                        page: fetch(api, source, originals, None).await,
                    }
                });
            }
            FeedInput::Rebuild => {
                clear(&self.list);
                let callbacks = self.callbacks(&sender);
                for tweet in &self.tweets {
                    self.list
                        .append(&build_tweet_card(tweet, &self.ctx, &callbacks));
                }
            }
            FeedInput::LoadMore => {
                if self.loading || self.exhausted {
                    return;
                }
                let Some(cursor) = self.cursor.clone() else {
                    return;
                };
                self.loading = true;
                let api = self.ctx.api.clone();
                let source = self.source.clone();
                let originals = self.originals;
                sender.oneshot_command(async move {
                    FeedCmd::Loaded {
                        append: true,
                        page: fetch(api, source, originals, Some(cursor)).await,
                    }
                });
            }
            FeedInput::RowActivated(index) => {
                if let Some(tweet) = self.tweets.get(index as usize) {
                    sender
                        .output(FeedOutput::Open(Route::Thread(tweet.rest_id.clone())))
                        .ok();
                }
            }
            FeedInput::ToggleOriginals(on) => {
                if self.originals != on {
                    self.originals = on;
                    sender.input(FeedInput::Reload);
                }
            }
        }
    }

    fn update_cmd(
        &mut self,
        message: Self::CommandOutput,
        sender: ComponentSender<Self>,
        _root: &Self::Root,
    ) {
        match message {
            FeedCmd::Loaded { append, page } => {
                self.loading = false;
                match page {
                    Ok(page) => {
                        if !append {
                            clear(&self.list);
                            self.tweets.clear();
                        }
                        let callbacks = self.callbacks(&sender);
                        for tweet in &page.tweets {
                            let card = build_tweet_card(tweet, &self.ctx, &callbacks);
                            self.list.append(&card);
                            self.tweets.push(tweet.clone());
                        }
                        self.cursor = page.cursor;
                        self.exhausted = self.cursor.is_none();
                        if self.tweets.is_empty() {
                            self.list.set_placeholder(Some(&empty_state(
                                "feed-symbolic",
                                "Nothing to show",
                            )));
                        }
                        // After a fresh load of a store-backed Home feed, fetch
                        // how stale the buffer is for the "updated Nm ago" label.
                        if !append && self.variant_key().is_some() {
                            let api = self.ctx.api.clone();
                            sender.oneshot_command(async move {
                                FeedCmd::Status(api.feed_status().await)
                            });
                        }
                    }
                    Err(error) => {
                        let message = error.user_message();
                        if self.tweets.is_empty() {
                            let retry = sender.clone();
                            self.list
                                .set_placeholder(Some(&error_state(&message, move || {
                                    retry.input(FeedInput::Reload)
                                })));
                        } else {
                            sender.output(FeedOutput::Open(Route::Toast(message))).ok();
                        }
                    }
                }
            }
            FeedCmd::Status(result) => {
                self.freshness = match (result, self.variant_key()) {
                    (Ok(status), Some(key)) => status
                        .feeds
                        .iter()
                        .find(|f| f.variant == key)
                        .and_then(|f| format::freshness_label(f.age_secs))
                        .unwrap_or_default(),
                    _ => String::new(),
                };
            }
        }
    }
}

impl Feed {
    /// The `feed.db` source key for this feed's freshness, or `None` for
    /// non-Home sources (which have no materialized buffer).
    fn variant_key(&self) -> Option<&'static str> {
        match self.source {
            FeedSource::HomeForYou => Some("home_foryou"),
            FeedSource::Following => Some("home_following"),
            _ => None,
        }
    }

    fn callbacks(&self, sender: &ComponentSender<Self>) -> CardCallbacks {
        let profile_sender = sender.clone();
        let media_sender = sender.clone();
        let toast_sender = sender.clone();
        CardCallbacks {
            open_profile: Rc::new(move |handle| {
                profile_sender
                    .output(FeedOutput::Open(Route::Profile(handle)))
                    .ok();
            }),
            open_media: Rc::new(move |tweet_id, items, start| {
                media_sender
                    .output(FeedOutput::Open(Route::Media {
                        tweet_id,
                        items,
                        start,
                    }))
                    .ok();
            }),
            toast: Rc::new(move |message| {
                toast_sender
                    .output(FeedOutput::Open(Route::Toast(message)))
                    .ok();
            }),
        }
    }
}

fn clear(list: &gtk::ListBox) {
    while let Some(child) = list.first_child() {
        list.remove(&child);
    }
}

async fn fetch(
    api: Arc<ApiClient>,
    source: FeedSource,
    originals: bool,
    cursor: Option<String>,
) -> Result<TimelinePage, ApiError> {
    let cursor = cursor.as_deref();
    match source {
        FeedSource::HomeForYou => api.home(false, originals, cursor, None).await,
        FeedSource::Following => api.home(true, originals, cursor, None).await,
        FeedSource::Search { query, product } => api.search(&query, product, cursor, None).await,
        FeedSource::Mentions => api.mentions(cursor, None).await,
        FeedSource::Bookmarks(query) => api.bookmarks(&query, cursor, None).await,
    }
}
