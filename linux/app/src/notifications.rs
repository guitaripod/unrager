//! Notifications feed: actor avatar + "who did what" + snippet + thumbnail.
//! Tapping a row opens the target thread (or the actor's profile for follows).

use crate::shared::{Ctx, FetchGeneration, Route, empty_state, error_state, loading_state};
use adw::prelude::*;
use relm4::prelude::*;
use unrager_gtk_core::ApiError;
use unrager_gtk_core::model::{Notification, NotificationsPage};

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
    /// Bumped by every Refresh so a result from an earlier fetch (e.g. a
    /// LoadMore that was in flight when the user refreshed) is recognized as
    /// stale and dropped instead of interleaving pages.
    generation: FetchGeneration,
    /// A Refresh arrived while a fetch was in flight; fire one fresh fetch when
    /// that fetch completes, so at most one fetch is ever in flight.
    refresh_queued: bool,
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
    Loaded {
        generation: u64,
        result: Result<NotificationsPage, ApiError>,
    },
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

                adw::Clamp {
                    set_maximum_size: 640,
                    set_tightening_threshold: 560,

                    #[local_ref]
                    list_box -> gtk::ListBox {
                        connect_row_activated[sender] => move |_, row| {
                            sender.input(NotificationsInput::RowActivated(row.index()));
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

        let model = Notifications {
            ctx: init.ctx,
            list: list.clone(),
            targets: Vec::new(),
            cursor: None,
            loading: true,
            exhausted: false,
            generation: FetchGeneration::default(),
            refresh_queued: false,
        };

        let list_box = &list;
        let widgets = view_output!();

        let api = model.ctx.api.clone();
        let generation = model.generation.current();
        sender.oneshot_command(async move {
            NotificationsCmd::Loaded {
                generation,
                result: api.notifications(None).await,
            }
        });

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
                self.generation.bump();
                self.list.set_placeholder(Some(&loading_state()));
                if self.loading {
                    self.refresh_queued = true;
                    return;
                }
                self.spawn_refresh(&sender);
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
                let generation = self.generation.current();
                sender.oneshot_command(async move {
                    NotificationsCmd::Loaded {
                        generation,
                        result: api.notifications(Some(&cursor)).await,
                    }
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
        let NotificationsCmd::Loaded { generation, result } = message;
        self.loading = false;
        if self.refresh_queued {
            self.refresh_queued = false;
            self.spawn_refresh(&sender);
            return;
        }
        if !self.generation.is_current(generation) {
            return;
        }
        match result {
            Ok(page) => {
                for notif in &page.notifications {
                    let index = self.targets.len() as i32;
                    self.list.append(&build_notification_row(notif, &self.ctx));
                    if let Some(row) = self.list.row_at_index(index) {
                        row.set_activatable(true);
                    }
                    self.targets.push(target_of(notif));
                }
                self.cursor = page.cursor;
                self.exhausted = self.cursor.is_none();
                if self.targets.is_empty() {
                    self.list
                        .set_placeholder(Some(&empty_state("bell-symbolic", "No notifications")));
                }
            }
            Err(error) => {
                let message = error.user_message();
                if self.targets.is_empty() {
                    let retry = sender.clone();
                    self.list
                        .set_placeholder(Some(&error_state(&message, move || {
                            retry.input(NotificationsInput::Refresh)
                        })));
                } else {
                    sender
                        .output(NotificationsOutput::Open(Route::Toast(message)))
                        .ok();
                }
            }
        }
    }
}

impl Notifications {
    /// Spawns the single in-flight first-page fetch for a queued or immediate
    /// Refresh, stamped with the current generation.
    fn spawn_refresh(&mut self, sender: &ComponentSender<Self>) {
        self.loading = true;
        let api = self.ctx.api.clone();
        let generation = self.generation.current();
        sender.oneshot_command(async move {
            NotificationsCmd::Loaded {
                generation,
                result: api.notifications(None).await,
            }
        });
    }
}

fn build_notification_row(notif: &Notification, ctx: &Ctx) -> gtk::Widget {
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 12);
    row.add_css_class("tweet-card");

    let actor_name = notif.actors.first().map(|a| a.name.as_str());
    let avatar = adw::Avatar::new(40, actor_name, true);
    avatar.set_valign(gtk::Align::Start);
    ctx.load_avatar(
        &avatar,
        notif.actors.first().and_then(|a| a.avatar_url.as_deref()),
    );
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

    let time = gtk::Label::new(Some(&unrager_gtk_core::format::relative_time(
        notif.timestamp,
        chrono::Utc::now(),
    )));
    time.set_xalign(0.0);
    time.add_css_class("dim-label");
    time.add_css_class("caption");
    column.append(&time);

    row.append(&column);

    if ctx.images_enabled()
        && let (Some(tweet_id), true) = (
            notif.target_tweet_id.as_deref(),
            !notif.target_media.is_empty(),
        )
    {
        let thumb = gtk::Image::new();
        thumb.set_pixel_size(52);
        thumb.set_valign(gtk::Align::Start);
        thumb.set_overflow(gtk::Overflow::Hidden);
        thumb.add_css_class("notif-thumb");
        ctx.load_thumbnail(&thumb, ctx.api.media_url(tweet_id, 0));
        row.append(&thumb);
    }

    row.upcast()
}

pub(crate) fn summary_title(notif: &Notification) -> String {
    let who = actor_names(notif);
    let verb = match notif.kind.to_ascii_lowercase().as_str() {
        "like" | "favorite" => "liked your tweet",
        "retweet" | "repost" => "reposted your tweet",
        "reply" => "replied to you",
        "quote" => "quoted your tweet",
        "follow" => "followed you",
        "mention" => "mentioned you",
        _ => "interacted with you",
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
