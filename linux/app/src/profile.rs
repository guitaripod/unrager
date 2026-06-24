//! Profile: a header (avatar, name, handle, follower counts, Brief) above the
//! user's recent tweets. `GET /api/profile/{handle}` for the first page, then
//! `GET /api/sources/user/{handle}` for pagination.

use crate::card::{CardCallbacks, build_tweet_card, verified_mark};
use crate::shared::{Ctx, Route, empty_state, error_state, loading_state};
use adw::prelude::*;
use relm4::prelude::*;
use std::rc::Rc;
use unrager_gtk_core::ApiError;
use unrager_gtk_core::format;
use unrager_gtk_core::model::{ProfileView, TimelinePage, User};
use url::Url;

pub struct ProfileInit {
    pub ctx: Ctx,
    pub handle: String,
}

pub struct Profile {
    ctx: Ctx,
    handle: String,
    header: gtk::Box,
    list: gtk::ListBox,
    ids: Vec<String>,
    cursor: Option<String>,
    loading: bool,
    exhausted: bool,
}

#[derive(Debug)]
pub enum ProfileInput {
    Reload,
    LoadMore,
    RowActivated(i32),
    Brief,
}

#[derive(Debug)]
pub enum ProfileOutput {
    Open(Route),
}

#[derive(Debug)]
pub enum ProfileCmd {
    Loaded(Box<Result<ProfileView, ApiError>>),
    More(Result<TimelinePage, ApiError>),
}

#[relm4::component(pub)]
impl Component for Profile {
    type Init = ProfileInit;
    type Input = ProfileInput;
    type Output = ProfileOutput;
    type CommandOutput = ProfileCmd;

    view! {
        adw::ToolbarView {
            add_top_bar = &adw::HeaderBar {
                pack_end = &gtk::Button {
                    set_label: "Brief",
                    set_tooltip_text: Some("AI summary of recent tweets"),
                    connect_clicked => ProfileInput::Brief,
                },
            },

            #[wrap(Some)]
            set_content = &gtk::ScrolledWindow {
                set_vexpand: true,
                connect_edge_reached[sender] => move |_, pos| {
                    if pos == gtk::PositionType::Bottom {
                        sender.input(ProfileInput::LoadMore);
                    }
                },

                adw::Clamp {
                    set_maximum_size: 640,
                    set_tightening_threshold: 560,

                    gtk::Box {
                        set_orientation: gtk::Orientation::Vertical,

                        #[local_ref]
                        header -> gtk::Box {
                            set_orientation: gtk::Orientation::Horizontal,
                        },

                        #[local_ref]
                        list_box -> gtk::ListBox {
                            connect_row_activated[sender] => move |_, row| {
                                sender.input(ProfileInput::RowActivated(row.index()));
                            },
                        }
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
        let header = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        let list = gtk::ListBox::new();
        list.set_selection_mode(gtk::SelectionMode::None);
        list.add_css_class("feed-list");
        list.set_placeholder(Some(&loading_state()));

        let model = Profile {
            ctx: init.ctx,
            handle: init.handle,
            header: header.clone(),
            list: list.clone(),
            ids: Vec::new(),
            cursor: None,
            loading: true,
            exhausted: false,
        };

        let header = &model.header;
        let list_box = &list;
        let widgets = view_output!();

        let api = model.ctx.api.clone();
        let handle = model.handle.clone();
        sender.oneshot_command(async move {
            ProfileCmd::Loaded(Box::new(api.profile(&handle, false).await))
        });

        ComponentParts { model, widgets }
    }

    fn update(&mut self, message: Self::Input, sender: ComponentSender<Self>, _root: &Self::Root) {
        match message {
            ProfileInput::Reload => {
                if self.loading {
                    return;
                }
                self.loading = true;
                while let Some(child) = self.list.first_child() {
                    self.list.remove(&child);
                }
                self.ids.clear();
                self.cursor = None;
                self.exhausted = false;
                self.list.set_placeholder(Some(&loading_state()));
                let api = self.ctx.api.clone();
                let handle = self.handle.clone();
                sender.oneshot_command(async move {
                    ProfileCmd::Loaded(Box::new(api.profile(&handle, false).await))
                });
            }
            ProfileInput::LoadMore => {
                if self.loading || self.exhausted {
                    return;
                }
                let Some(cursor) = self.cursor.clone() else {
                    return;
                };
                self.loading = true;
                let api = self.ctx.api.clone();
                let handle = self.handle.clone();
                sender.oneshot_command(async move {
                    ProfileCmd::More(api.user_timeline(&handle, Some(&cursor), None).await)
                });
            }
            ProfileInput::RowActivated(index) => {
                if let Some(id) = self.ids.get(index as usize) {
                    sender
                        .output(ProfileOutput::Open(Route::Thread(id.clone())))
                        .ok();
                }
            }
            ProfileInput::Brief => {
                sender
                    .output(ProfileOutput::Open(Route::Brief(self.handle.clone())))
                    .ok();
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
            ProfileCmd::Loaded(result) => {
                self.loading = false;
                match *result {
                    Ok(view) => {
                        fill_header(&self.header, &view.user, &self.ctx);
                        let callbacks = self.callbacks(&sender);
                        if let Some(pinned) = &view.pinned {
                            self.append_card(pinned, &callbacks);
                        }
                        for tweet in &view.recent {
                            self.append_card(tweet, &callbacks);
                        }
                        self.cursor = view.cursor;
                        self.exhausted = self.cursor.is_none();
                        if self.ids.is_empty() {
                            self.list.set_placeholder(Some(&empty_state(
                                "user-info-symbolic",
                                "No tweets yet",
                            )));
                        }
                    }
                    Err(error) => {
                        let retry = sender.clone();
                        self.list.set_placeholder(Some(&error_state(
                            &error.user_message(),
                            move || retry.input(ProfileInput::Reload),
                        )));
                    }
                }
            }
            ProfileCmd::More(result) => {
                self.loading = false;
                match result {
                    Ok(page) => {
                        let callbacks = self.callbacks(&sender);
                        for tweet in &page.tweets {
                            self.append_card(tweet, &callbacks);
                        }
                        self.cursor = page.cursor;
                        self.exhausted = self.cursor.is_none();
                    }
                    Err(error) => {
                        sender
                            .output(ProfileOutput::Open(Route::Toast(error.user_message())))
                            .ok();
                    }
                }
            }
        }
    }
}

impl Profile {
    fn append_card(&mut self, tweet: &unrager_gtk_core::model::Tweet, callbacks: &CardCallbacks) {
        self.list
            .append(&build_tweet_card(tweet, &self.ctx, callbacks));
        self.ids.push(tweet.rest_id.clone());
    }

    fn callbacks(&self, sender: &ComponentSender<Self>) -> CardCallbacks {
        let profile_sender = sender.clone();
        let media_sender = sender.clone();
        let toast_sender = sender.clone();
        CardCallbacks {
            open_profile: Rc::new(move |handle| {
                profile_sender
                    .output(ProfileOutput::Open(Route::Profile(handle)))
                    .ok();
            }),
            open_media: Rc::new(move |tweet_id, items, start| {
                media_sender
                    .output(ProfileOutput::Open(Route::Media {
                        tweet_id,
                        items,
                        start,
                    }))
                    .ok();
            }),
            toast: Rc::new(move |message| {
                toast_sender
                    .output(ProfileOutput::Open(Route::Toast(message)))
                    .ok();
            }),
        }
    }
}

fn fill_header(header: &gtk::Box, user: &User, ctx: &Ctx) {
    while let Some(child) = header.first_child() {
        header.remove(&child);
    }
    header.set_spacing(14);
    header.add_css_class("profile-header");

    let avatar = adw::Avatar::new(72, Some(&user.name), true);
    avatar.set_valign(gtk::Align::Start);
    if let Some(url) = user.avatar_url.as_deref().and_then(|u| Url::parse(u).ok()) {
        ctx.images.load_avatar(&avatar, ctx.api.clone(), url);
    }
    header.append(&avatar);

    let column = gtk::Box::new(gtk::Orientation::Vertical, 2);
    column.set_valign(gtk::Align::Center);

    let name_line = gtk::Box::new(gtk::Orientation::Horizontal, 4);
    let name = gtk::Label::new(Some(&user.name));
    name.set_xalign(0.0);
    name.add_css_class("profile-name");
    name_line.append(&name);
    if user.verified {
        name_line.append(&verified_mark());
    }
    column.append(&name_line);

    let handle = gtk::Label::new(Some(&format!("@{}", user.handle)));
    handle.set_xalign(0.0);
    handle.add_css_class("tweet-meta");
    column.append(&handle);

    let counts = gtk::Label::new(Some(&format!(
        "{} Following · {} Followers",
        format::count(user.following as i64),
        format::count(user.followers as i64)
    )));
    counts.set_xalign(0.0);
    counts.add_css_class("tweet-meta");
    column.append(&counts);

    header.append(&column);
}
