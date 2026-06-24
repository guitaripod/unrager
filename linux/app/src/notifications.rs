//! Notifications feed: actor avatar + "who did what" + snippet + thumbnail.
//! Tapping a row opens the target thread (or the actor's profile for follows).

use crate::shared::{Ctx, Route, empty_placeholder};
use adw::prelude::*;
use relm4::prelude::*;
use unrager_gtk_core::ApiError;
use unrager_gtk_core::model::{Notification, NotificationsPage};
use url::Url;

pub struct NotificationsInit {
    pub ctx: Ctx,
}

pub struct Notifications {
    ctx: Ctx,
    list: gtk::ListBox,
    targets: Vec<Route>,
    cursor: Option<String>,
    loading: bool,
    exhausted: bool,
}

#[derive(Debug)]
pub enum NotificationsInput {
    Refresh,
    LoadMore,
    RowActivated(i32),
}

#[derive(Debug)]
pub enum NotificationsOutput {
    Open(Route),
}

#[derive(Debug)]
pub enum NotificationsCmd {
    Loaded(Result<NotificationsPage, ApiError>),
}

#[relm4::component(pub)]
impl Component for Notifications {
    type Init = NotificationsInit;
    type Input = NotificationsInput;
    type Output = NotificationsOutput;
    type CommandOutput = NotificationsCmd;

    view! {
        adw::ToolbarView {
            add_top_bar = &adw::HeaderBar {
                pack_end = &gtk::Button {
                    set_icon_name: "view-refresh-symbolic",
                    set_tooltip_text: Some("Refresh"),
                    connect_clicked => NotificationsInput::Refresh,
                },
            },

            #[wrap(Some)]
            set_content = &gtk::ScrolledWindow {
                set_vexpand: true,
                set_hexpand: true,
                connect_edge_reached[sender] => move |_, pos| {
                    if pos == gtk::PositionType::Bottom {
                        sender.input(NotificationsInput::LoadMore);
                    }
                },

                #[local_ref]
                list_box -> gtk::ListBox {
                    connect_row_activated[sender] => move |_, row| {
                        sender.input(NotificationsInput::RowActivated(row.index()));
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
        list.set_placeholder(Some(&empty_placeholder("No notifications.")));

        let model = Notifications {
            ctx: init.ctx,
            list: list.clone(),
            targets: Vec::new(),
            cursor: None,
            loading: true,
            exhausted: false,
        };

        let list_box = &list;
        let widgets = view_output!();

        let api = model.ctx.api.clone();
        sender.oneshot_command(
            async move { NotificationsCmd::Loaded(api.notifications(None).await) },
        );

        ComponentParts { model, widgets }
    }

    fn update(&mut self, message: Self::Input, sender: ComponentSender<Self>, _root: &Self::Root) {
        match message {
            NotificationsInput::Refresh => {
                while let Some(child) = self.list.first_child() {
                    self.list.remove(&child);
                }
                self.targets.clear();
                self.cursor = None;
                self.exhausted = false;
                self.loading = true;
                let api = self.ctx.api.clone();
                sender.oneshot_command(async move {
                    NotificationsCmd::Loaded(api.notifications(None).await)
                });
            }
            NotificationsInput::LoadMore => {
                if self.loading || self.exhausted {
                    return;
                }
                let Some(cursor) = self.cursor.clone() else {
                    return;
                };
                self.loading = true;
                let api = self.ctx.api.clone();
                sender.oneshot_command(async move {
                    NotificationsCmd::Loaded(api.notifications(Some(&cursor)).await)
                });
            }
            NotificationsInput::RowActivated(index) => {
                if let Some(route) = self.targets.get(index as usize) {
                    sender.output(NotificationsOutput::Open(route.clone())).ok();
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
        let NotificationsCmd::Loaded(result) = message;
        self.loading = false;
        match result {
            Ok(page) => {
                for notif in &page.notifications {
                    self.list.append(&build_notification_row(notif, &self.ctx));
                    self.targets.push(target_of(notif));
                }
                self.cursor = page.cursor;
                self.exhausted = self.cursor.is_none();
            }
            Err(error) => {
                sender
                    .output(NotificationsOutput::Open(Route::Toast(
                        error.user_message(),
                    )))
                    .ok();
            }
        }
    }
}

fn build_notification_row(notif: &Notification, ctx: &Ctx) -> gtk::Widget {
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 12);
    row.add_css_class("tweet-card");

    let avatar = gtk::Picture::new();
    avatar.set_size_request(40, 40);
    avatar.set_content_fit(gtk::ContentFit::Cover);
    avatar.set_valign(gtk::Align::Start);
    avatar.add_css_class("avatar");
    if let Some(url) = notif
        .actors
        .first()
        .and_then(|a| a.avatar_url.as_deref())
        .and_then(|u| Url::parse(u).ok())
    {
        ctx.images.load(&avatar, ctx.api.clone(), url);
    }
    row.append(&avatar);

    let column = gtk::Box::new(gtk::Orientation::Vertical, 2);
    column.set_hexpand(true);

    let title = gtk::Label::new(Some(&summary_title(notif)));
    title.set_xalign(0.0);
    title.set_wrap(true);
    title.add_css_class("tweet-name");
    column.append(&title);

    if let Some(snippet) = notif.target_tweet_snippet.as_deref()
        && !snippet.is_empty()
    {
        let body = gtk::Label::new(Some(snippet));
        body.set_xalign(0.0);
        body.set_wrap(true);
        body.set_lines(2);
        body.set_ellipsize(gtk::pango::EllipsizeMode::End);
        body.add_css_class("tweet-meta");
        column.append(&body);
    }
    row.append(&column);

    if let (Some(tweet_id), true) = (
        notif.target_tweet_id.as_deref(),
        !notif.target_media.is_empty(),
    ) {
        let thumb = gtk::Picture::new();
        thumb.set_size_request(52, 52);
        thumb.set_content_fit(gtk::ContentFit::Cover);
        thumb.set_valign(gtk::Align::Start);
        thumb.add_css_class("tweet-media");
        ctx.images
            .load(&thumb, ctx.api.clone(), ctx.api.media_url(tweet_id, 0));
        row.append(&thumb);
    }

    row.upcast()
}

pub(crate) fn summary_title(notif: &Notification) -> String {
    let who = actor_names(notif);
    let verb = match notif.kind.as_str() {
        "like" | "favorite" => "liked your post",
        "retweet" | "repost" => "reposted your post",
        "reply" => "replied to you",
        "quote" => "quoted your post",
        "follow" => "followed you",
        "mention" => "mentioned you",
        other => other,
    };
    format!("{who} {verb}")
}

fn actor_names(notif: &Notification) -> String {
    match notif.actors.split_first() {
        Some((first, [])) => first.name.clone(),
        Some((first, rest)) => format!("{} and {} others", first.name, rest.len()),
        None => "Someone".to_string(),
    }
}

fn target_of(notif: &Notification) -> Route {
    if let Some(id) = notif.target_tweet_id.as_deref() {
        Route::Thread(id.to_string())
    } else if let Some(actor) = notif.actors.first() {
        Route::Profile(actor.handle.clone())
    } else {
        Route::Toast("No target for this notification".to_string())
    }
}
