//! The reusable timeline component backing Home / Following / User / Search /
//! Mentions / Bookmarks. Fetches a page, renders tweet cards into a `ListBox`,
//! and loads more on scroll-to-bottom.

use crate::card::{CardCallbacks, build_tweet_card};
use crate::shared::{Ctx, Route, empty_placeholder};
use adw::prelude::*;
use relm4::prelude::*;
use std::rc::Rc;
use std::sync::Arc;
use unrager_gtk_core::model::{SearchProduct, TimelinePage};
use unrager_gtk_core::{ApiClient, ApiError};

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
    ids: Vec<String>,
    cursor: Option<String>,
    loading: bool,
    exhausted: bool,
}

#[derive(Debug)]
pub enum FeedInput {
    Reload,
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

                #[local_ref]
                list_box -> gtk::ListBox {
                    connect_row_activated[sender] => move |_, row| {
                        sender.input(FeedInput::RowActivated(row.index()));
                    },
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
        list.set_placeholder(Some(&empty_placeholder("Nothing to show yet.")));

        let is_home = matches!(init.source, FeedSource::HomeForYou | FeedSource::Following);

        let model = Feed {
            ctx: init.ctx,
            source: init.source,
            originals: false,
            list: list.clone(),
            ids: Vec::new(),
            cursor: None,
            loading: false,
            exhausted: false,
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
                if let Some(id) = self.ids.get(index as usize) {
                    sender
                        .output(FeedOutput::Open(Route::Thread(id.clone())))
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
        let FeedCmd::Loaded { append, page } = message;
        self.loading = false;
        match page {
            Ok(page) => {
                if !append {
                    clear(&self.list);
                    self.ids.clear();
                }
                let callbacks = self.callbacks(&sender);
                for tweet in &page.tweets {
                    let card = build_tweet_card(tweet, &self.ctx, &callbacks);
                    self.list.append(&card);
                    self.ids.push(tweet.rest_id.clone());
                }
                self.cursor = page.cursor;
                self.exhausted = self.cursor.is_none();
            }
            Err(error) => {
                sender
                    .output(FeedOutput::Open(Route::Toast(error.user_message())))
                    .ok();
            }
        }
    }
}

impl Feed {
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
            open_media: Rc::new(move |tweet_id, indices, start| {
                media_sender
                    .output(FeedOutput::Open(Route::Media {
                        tweet_id,
                        indices,
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
