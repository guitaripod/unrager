//! Thread view: ancestors → focal (emphasized) → replies, fetched from
//! `GET /api/thread/{id}`.

use crate::card::{CardCallbacks, build_tweet_card};
use crate::shared::{Ctx, Route, error_state, loading_state};
use adw::prelude::*;
use gtk::glib;
use relm4::prelude::*;
use std::rc::Rc;
use unrager_gtk_core::ApiError;
use unrager_gtk_core::model::{AskPreset, ThreadView};

pub struct ThreadInit {
    pub ctx: Ctx,
    pub id: String,
}

pub struct Thread {
    ctx: Ctx,
    id: String,
    container: gtk::Box,
}

#[derive(Debug)]
pub enum ThreadInput {
    Reload,
    Reply,
    Translate,
    Ask(AskPreset),
}

#[derive(Debug)]
pub enum ThreadOutput {
    Open(Route),
}

#[derive(Debug)]
pub enum ThreadCmd {
    Loaded(Result<ThreadView, ApiError>),
}

#[relm4::component(pub)]
impl Component for Thread {
    type Init = ThreadInit;
    type Input = ThreadInput;
    type Output = ThreadOutput;
    type CommandOutput = ThreadCmd;

    view! {
        adw::ToolbarView {
            add_top_bar = &adw::HeaderBar {
                #[wrap(Some)]
                set_title_widget = &adw::WindowTitle {
                    set_title: "Tweet",
                },
                pack_start = &gtk::Button {
                    set_icon_name: "mail-reply-sender-symbolic",
                    set_tooltip_text: Some("Reply"),
                    connect_clicked => ThreadInput::Reply,
                },
                pack_end = &gtk::MenuButton {
                    set_icon_name: "dialog-question-symbolic",
                    set_tooltip_text: Some("Ask the local LLM"),

                    #[wrap(Some)]
                    set_popover = &gtk::Popover {
                        gtk::Box {
                            set_orientation: gtk::Orientation::Vertical,
                            set_spacing: 2,
                            gtk::Button {
                                set_label: "Explain",
                                add_css_class: "flat",
                                connect_clicked => ThreadInput::Ask(AskPreset::Explain),
                            },
                            gtk::Button {
                                set_label: "Summary",
                                add_css_class: "flat",
                                connect_clicked => ThreadInput::Ask(AskPreset::Summary),
                            },
                            gtk::Button {
                                set_label: "Counterpoint",
                                add_css_class: "flat",
                                connect_clicked => ThreadInput::Ask(AskPreset::Counter),
                            },
                            gtk::Button {
                                set_label: "ELI5",
                                add_css_class: "flat",
                                connect_clicked => ThreadInput::Ask(AskPreset::Eli5),
                            },
                            gtk::Button {
                                set_label: "Entities",
                                add_css_class: "flat",
                                connect_clicked => ThreadInput::Ask(AskPreset::Entities),
                            },
                        }
                    }
                },
                pack_end = &gtk::Button {
                    set_label: "Translate",
                    connect_clicked => ThreadInput::Translate,
                },
            },

            #[wrap(Some)]
            set_content = &gtk::ScrolledWindow {
                set_vexpand: true,
                set_hexpand: true,

                adw::Clamp {
                    set_maximum_size: 640,
                    set_tightening_threshold: 560,

                    #[local_ref]
                    container -> gtk::Box {
                        set_orientation: gtk::Orientation::Vertical,
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
        let container = gtk::Box::new(gtk::Orientation::Vertical, 0);
        container.add_css_class("thread-list");

        let model = Thread {
            ctx: init.ctx,
            id: init.id,
            container: container.clone(),
        };

        let container = &model.container;
        let widgets = view_output!();
        sender.input(ThreadInput::Reload);
        ComponentParts { model, widgets }
    }

    fn update(&mut self, message: Self::Input, sender: ComponentSender<Self>, _root: &Self::Root) {
        match message {
            ThreadInput::Reload => {
                clear(&self.container);
                self.container.append(&loading_state());
                let api = self.ctx.api.clone();
                let id = self.id.clone();
                sender
                    .oneshot_command(async move { ThreadCmd::Loaded(api.thread(&id, None).await) });
            }
            ThreadInput::Reply => {
                sender
                    .output(ThreadOutput::Open(Route::Reply(self.id.clone())))
                    .ok();
            }
            ThreadInput::Translate => {
                sender
                    .output(ThreadOutput::Open(Route::Translate(self.id.clone())))
                    .ok();
            }
            ThreadInput::Ask(preset) => {
                sender
                    .output(ThreadOutput::Open(Route::Ask {
                        tweet_id: self.id.clone(),
                        preset,
                    }))
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
        let ThreadCmd::Loaded(result) = message;
        clear(&self.container);
        match result {
            Ok(view) => {
                let callbacks = self.callbacks(&sender);
                for ancestor in &view.ancestors {
                    self.container
                        .append(&build_tweet_card(ancestor, &self.ctx, &callbacks));
                }
                let focal = build_tweet_card(&view.focal, &self.ctx, &callbacks);
                focal.add_css_class("focal");
                self.container.append(&focal);
                for reply in &view.replies {
                    self.container
                        .append(&build_tweet_card(reply, &self.ctx, &callbacks));
                }
                if !view.ancestors.is_empty() {
                    self.scroll_to_focal(&focal);
                }
            }
            Err(error) => {
                let retry = sender.clone();
                clear(&self.container);
                self.container
                    .append(&error_state(&error.user_message(), move || {
                        retry.input(ThreadInput::Reload)
                    }));
            }
        }
    }
}

impl Thread {
    /// Anchors the view on the focal post once layout settles, so a thread with
    /// ancestors doesn't open scrolled to the top showing a parent tweet. Runs
    /// on idle because the cards aren't allocated yet at the end of `update_cmd`.
    fn scroll_to_focal(&self, focal: &gtk::Widget) {
        let focal = focal.clone();
        let container = self.container.clone();
        glib::idle_add_local_once(move || {
            let Some(scroller) = container
                .ancestor(gtk::ScrolledWindow::static_type())
                .and_downcast::<gtk::ScrolledWindow>()
            else {
                return;
            };
            if let Some(bounds) = focal.compute_bounds(&container) {
                scroller.vadjustment().set_value(bounds.y() as f64);
            }
        });
    }

    fn callbacks(&self, sender: &ComponentSender<Self>) -> CardCallbacks {
        let profile_sender = sender.clone();
        let media_sender = sender.clone();
        let toast_sender = sender.clone();
        CardCallbacks {
            open_profile: Rc::new(move |handle| {
                profile_sender
                    .output(ThreadOutput::Open(Route::Profile(handle)))
                    .ok();
            }),
            open_media: Rc::new(move |tweet_id, items, start| {
                media_sender
                    .output(ThreadOutput::Open(Route::Media {
                        tweet_id,
                        items,
                        start,
                    }))
                    .ok();
            }),
            toast: Rc::new(move |message| {
                toast_sender
                    .output(ThreadOutput::Open(Route::Toast(message)))
                    .ok();
            }),
        }
    }
}

fn clear(container: &gtk::Box) {
    while let Some(child) = container.first_child() {
        container.remove(&child);
    }
}
