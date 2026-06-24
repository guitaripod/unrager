//! The application shell: a libadwaita `NavigationSplitView` (sidebar + content
//! `NavigationView`), serve auto-spawn, and route handling that pushes
//! thread/profile pages and shows error toasts.

use crate::compose::{Compose, ComposeInit, ComposeMode};
use crate::feed::{Feed, FeedInit, FeedInput, FeedOutput, FeedSource};
use crate::image::ImagePipeline;
use crate::media_viewer::{MediaViewer, MediaViewerInit};
use crate::notifications::{Notifications, NotificationsInit, NotificationsOutput, summary_title};
use crate::profile::{Profile, ProfileInit, ProfileOutput};
use crate::settings_page::{Settings, SettingsInit, SettingsOutput};
use crate::shared::{Ctx, Route};
use crate::stream_sheet::{StreamInit, StreamRequest, StreamSheet};
use crate::thread::{Thread, ThreadInit, ThreadOutput};
use adw::prelude::*;
use relm4::prelude::*;
use std::sync::Arc;
use unrager_gtk_core::model::SearchProduct;
use unrager_gtk_core::{
    ApiClient, AppSettings, AppearanceMode, FontScale, ServeError, ServeManager,
};

const BASE_CSS: &str = include_str!("style.css");

const SOURCES: &[(&str, &str)] = &[
    ("For You", "starred-symbolic"),
    ("Following", "system-users-symbolic"),
    ("Notifications", "bell-symbolic"),
    ("Search", "system-search-symbolic"),
    ("Mentions", "mail-unread-symbolic"),
    ("Bookmarks", "user-bookmarks-symbolic"),
    ("Settings", "emblem-system-symbolic"),
];

pub struct App {
    settings: AppSettings,
    ctx: Ctx,
    _serve: Option<ServeManager>,
    nav: adw::NavigationView,
    toasts: adw::ToastOverlay,
    sidebar: gtk::ListBox,
    status: adw::StatusPage,
    feed: Option<Controller<Feed>>,
    threads: Vec<Controller<Thread>>,
    profiles: Vec<Controller<Profile>>,
    notifications: Option<Controller<Notifications>>,
    settings_ctl: Option<Controller<Settings>>,
    stream: Option<Controller<StreamSheet>>,
    composer: Option<Controller<Compose>>,
    media: Option<Controller<MediaViewer>>,
}

#[derive(Debug)]
pub enum AppInput {
    Sidebar(i32),
    Route(Route),
    OpenSearch(String),
    RefreshCurrent,
    SettingsChanged(AppSettings),
}

#[derive(Debug)]
pub enum AppCmd {
    Serve(Box<Result<ServeManager, ServeError>>),
    NewNotifications(Vec<String>),
}

#[relm4::component(pub)]
impl Component for App {
    type Init = AppSettings;
    type Input = AppInput;
    type Output = ();
    type CommandOutput = AppCmd;

    view! {
        adw::ApplicationWindow {
            set_title: Some("Unrager"),
            set_default_size: (560, 880),

            #[local_ref]
            toasts -> adw::ToastOverlay {
                adw::NavigationSplitView {
                    set_max_sidebar_width: 260.0,

                    #[wrap(Some)]
                    set_sidebar = &adw::NavigationPage {
                        set_title: "Unrager",
                        #[wrap(Some)]
                        set_child = &adw::ToolbarView {
                            add_top_bar = &adw::HeaderBar {
                                #[wrap(Some)]
                                set_title_widget = &adw::WindowTitle {
                                    set_title: "Unrager",
                                },
                            },
                            #[wrap(Some)]
                            set_content = &gtk::ScrolledWindow {
                                #[local_ref]
                                sidebar -> gtk::ListBox {
                                    set_selection_mode: gtk::SelectionMode::Single,
                                    add_css_class: "navigation-sidebar",
                                    connect_row_activated[sender] => move |_, row| {
                                        sender.input(AppInput::Sidebar(row.index()));
                                    },
                                }
                            }
                        }
                    },

                    #[wrap(Some)]
                    set_content = &adw::NavigationPage {
                        set_title: "Feed",
                        set_child: Some(nav),
                    }
                }
            }
        }
    }

    fn init(
        settings: Self::Init,
        root: Self::Root,
        sender: ComponentSender<Self>,
    ) -> ComponentParts<Self> {
        apply_css(settings.font_scale);
        apply_appearance(settings.appearance);

        let api = Arc::new(ApiClient::new(settings.server_url()));
        let ctx = Ctx {
            api,
            images: ImagePipeline::new(),
        };

        let nav = adw::NavigationView::new();
        let toasts = adw::ToastOverlay::new();
        let sidebar = gtk::ListBox::new();
        let status = build_status("Connecting…", "Starting unrager serve.", true);
        nav.push(&status_page("Unrager", &status));

        let model = App {
            settings,
            ctx,
            _serve: None,
            nav: nav.clone(),
            toasts: toasts.clone(),
            sidebar: sidebar.clone(),
            status: status.clone(),
            feed: None,
            threads: Vec::new(),
            profiles: Vec::new(),
            notifications: None,
            settings_ctl: None,
            stream: None,
            composer: None,
            media: None,
        };

        let toasts = &model.toasts;
        let nav = &model.nav;
        let sidebar = &model.sidebar;
        let widgets = view_output!();

        for (label, icon) in SOURCES {
            model.sidebar.append(&sidebar_row(label, icon));
        }

        install_shortcuts(&sender);
        maybe_schedule_screenshot(root.clone());

        let configured = Some(model.settings.server_url());
        sender.oneshot_command(async move {
            AppCmd::Serve(Box::new(ServeManager::start(configured).await))
        });

        ComponentParts { model, widgets }
    }

    fn update(&mut self, message: Self::Input, sender: ComponentSender<Self>, root: &Self::Root) {
        match message {
            AppInput::Sidebar(index) => self.sidebar_action(index, &sender, root),
            AppInput::Route(route) => self.handle_route(route, &sender, root),
            AppInput::OpenSearch(query) => {
                let title = format!("Search: {query}");
                self.show_source(
                    FeedSource::Search {
                        query,
                        product: SearchProduct::Top,
                    },
                    &title,
                    &sender,
                );
            }
            AppInput::RefreshCurrent => {
                if let Some(feed) = &self.feed {
                    let _ = feed.sender().send(FeedInput::Reload);
                }
            }
            AppInput::SettingsChanged(settings) => {
                apply_appearance(settings.appearance);
                apply_css(settings.font_scale);
                self.settings = settings;
                if let Err(error) = self.settings.save() {
                    tracing::warn!(target: "ui", "failed to save settings: {error}");
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
            AppCmd::Serve(result) => match *result {
                Ok(manager) => {
                    self.ctx.api.set_base_url(manager.base_url());
                    tracing::info!(target: "ui", "connected: {}", manager.base_url());
                    self._serve = Some(manager);
                    if let Some(row) = self.sidebar.row_at_index(0) {
                        self.sidebar.select_row(Some(&row));
                    }
                    self.show_source(FeedSource::HomeForYou, "For You", &sender);
                    start_poller(self.ctx.api.clone(), &sender);
                }
                Err(error) => {
                    self.status.set_title("Couldn't reach a server");
                    self.status.set_description(Some(&error.to_string()));
                    self.status.set_icon_name(Some("network-error-symbolic"));
                    if let Some(child) = self.status.child() {
                        child.set_visible(false);
                    }
                }
            },
            AppCmd::NewNotifications(items) => {
                for body in &items {
                    desktop_notify(body);
                }
                let count = items.len();
                let plural = if count == 1 { "" } else { "s" };
                self.toasts.add_toast(adw::Toast::new(&format!(
                    "{count} new notification{plural}"
                )));
            }
        }
    }
}

impl App {
    fn sidebar_action(
        &mut self,
        index: i32,
        sender: &ComponentSender<Self>,
        root: &adw::ApplicationWindow,
    ) {
        if let Some(row) = self.sidebar.row_at_index(index) {
            self.sidebar.select_row(Some(&row));
        }
        match index {
            0 => self.show_source(FeedSource::HomeForYou, "For You", sender),
            1 => self.show_source(FeedSource::Following, "Following", sender),
            2 => self.show_notifications(sender),
            3 => open_search(sender, root),
            4 => self.show_source(FeedSource::Mentions, "Mentions", sender),
            5 => self.show_source(FeedSource::Bookmarks("*".to_string()), "Bookmarks", sender),
            6 => self.open_settings(sender, root),
            _ => {}
        }
    }

    fn show_notifications(&mut self, sender: &ComponentSender<Self>) {
        let controller = Notifications::builder()
            .launch(NotificationsInit {
                ctx: self.ctx.clone(),
            })
            .forward(sender.input_sender(), |out| match out {
                NotificationsOutput::Open(route) => AppInput::Route(route),
            });
        self.nav
            .replace(&[wrap_page("Notifications", controller.widget())]);
        self.notifications = Some(controller);
    }

    fn open_settings(&mut self, sender: &ComponentSender<Self>, root: &adw::ApplicationWindow) {
        let controller = Settings::builder()
            .launch(SettingsInit {
                ctx: self.ctx.clone(),
                settings: self.settings.clone(),
            })
            .forward(sender.input_sender(), |out| match out {
                SettingsOutput::Changed(settings) => AppInput::SettingsChanged(settings),
            });
        controller.widget().present(Some(root));
        self.settings_ctl = Some(controller);
    }

    fn show_source(&mut self, source: FeedSource, title: &str, sender: &ComponentSender<Self>) {
        let feed = Feed::builder()
            .launch(FeedInit {
                ctx: self.ctx.clone(),
                source,
            })
            .forward(sender.input_sender(), |out| match out {
                FeedOutput::Open(route) => AppInput::Route(route),
            });
        let page = wrap_page(title, feed.widget());
        self.nav.replace(&[page]);
        self.feed = Some(feed);
    }

    fn handle_route(
        &mut self,
        route: Route,
        sender: &ComponentSender<Self>,
        root: &adw::ApplicationWindow,
    ) {
        match route {
            Route::Thread(id) => {
                let thread = Thread::builder()
                    .launch(ThreadInit {
                        ctx: self.ctx.clone(),
                        id,
                    })
                    .forward(sender.input_sender(), |out| match out {
                        ThreadOutput::Open(route) => AppInput::Route(route),
                    });
                self.nav.push(&wrap_page("Thread", thread.widget()));
                self.threads.push(thread);
            }
            Route::Profile(handle) => {
                let title = format!("@{handle}");
                let profile = Profile::builder()
                    .launch(ProfileInit {
                        ctx: self.ctx.clone(),
                        handle,
                    })
                    .forward(sender.input_sender(), |out| match out {
                        ProfileOutput::Open(route) => AppInput::Route(route),
                    });
                self.nav.push(&wrap_page(&title, profile.widget()));
                self.profiles.push(profile);
            }
            Route::Toast(message) => {
                self.toasts.add_toast(adw::Toast::new(&message));
            }
            Route::ComposeNew => self.open_compose(ComposeMode::New, root),
            Route::Reply(tweet_id) => self.open_compose(ComposeMode::Reply { tweet_id }, root),
            Route::Ask { tweet_id, preset } => {
                self.open_stream(StreamRequest::Ask { tweet_id, preset }, root)
            }
            Route::Brief(handle) => self.open_stream(StreamRequest::Brief { handle }, root),
            Route::Translate(tweet_id) => {
                self.open_stream(StreamRequest::Translate { tweet_id }, root)
            }
            Route::Media {
                tweet_id,
                indices,
                start,
            } => self.open_media(tweet_id, indices, start),
        }
    }

    fn open_media(&mut self, tweet_id: String, indices: Vec<usize>, start: usize) {
        let controller = MediaViewer::builder()
            .launch(MediaViewerInit {
                ctx: self.ctx.clone(),
                tweet_id,
                indices,
                start,
            })
            .detach();
        controller.widget().present();
        self.media = Some(controller);
    }

    fn open_compose(&mut self, mode: ComposeMode, root: &adw::ApplicationWindow) {
        let controller = Compose::builder()
            .launch(ComposeInit {
                ctx: self.ctx.clone(),
                mode,
            })
            .detach();
        controller.widget().present(Some(root));
        self.composer = Some(controller);
    }

    fn open_stream(&mut self, request: StreamRequest, root: &adw::ApplicationWindow) {
        let controller = StreamSheet::builder()
            .launch(StreamInit {
                ctx: self.ctx.clone(),
                request,
            })
            .detach();
        controller.widget().present(Some(root));
        self.stream = Some(controller);
    }
}

fn open_search(sender: &ComponentSender<App>, root: &adw::ApplicationWindow) {
    let entry = gtk::Entry::new();
    entry.set_placeholder_text(Some("Search X"));
    entry.set_activates_default(true);

    let dialog = adw::AlertDialog::new(Some("Search"), None);
    dialog.set_extra_child(Some(&entry));
    dialog.add_response("cancel", "Cancel");
    dialog.add_response("search", "Search");
    dialog.set_response_appearance("search", adw::ResponseAppearance::Suggested);
    dialog.set_default_response(Some("search"));
    dialog.set_close_response("cancel");

    let input = sender.input_sender().clone();
    dialog.connect_response(None, move |_, response| {
        if response == "search" {
            let query = entry.text().trim().to_string();
            if !query.is_empty() {
                input.emit(AppInput::OpenSearch(query));
            }
        }
    });

    dialog.present(Some(root));
}

/// Polls notifications every 30s and raises a desktop notification for items
/// that appear after the first (baseline) poll. Stops when the app shuts down.
fn start_poller(api: Arc<ApiClient>, sender: &ComponentSender<App>) {
    sender.command(move |out, shutdown| {
        shutdown
            .register(async move {
                let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
                let mut first = true;
                loop {
                    if let Ok(page) = api.notifications(None).await {
                        let mut fresh = Vec::new();
                        for notif in &page.notifications {
                            let is_new = seen.insert(notif.id.clone());
                            if is_new && !first {
                                fresh.push(summary_title(notif));
                            }
                        }
                        if !fresh.is_empty() {
                            let _ = out.send(AppCmd::NewNotifications(fresh));
                        }
                        first = false;
                    }
                    tokio::time::sleep(std::time::Duration::from_secs(30)).await;
                }
            })
            .drop_on_shutdown()
    });
}

#[cfg(target_os = "linux")]
fn desktop_notify(body: &str) {
    let _ = notify_rust::Notification::new()
        .summary("Unrager")
        .body(body)
        .show();
}

#[cfg(not(target_os = "linux"))]
fn desktop_notify(_body: &str) {}

/// Debug/QA: if `UNRAGER_SHOT` is set, render the window to that PNG path after
/// `UNRAGER_SHOT_DELAY` seconds (default 6) using the app's own GSK renderer —
/// no OS screen-recording permission required.
fn maybe_schedule_screenshot(window: adw::ApplicationWindow) {
    let Ok(path) = std::env::var("UNRAGER_SHOT") else {
        return;
    };
    let delay = std::env::var("UNRAGER_SHOT_DELAY")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(6);
    gtk::glib::timeout_add_seconds_local(delay, move || {
        capture_window(&window, &path);
        gtk::glib::ControlFlow::Break
    });
}

fn capture_window(window: &adw::ApplicationWindow, path: &str) {
    let width = window.width().max(1) as f64;
    let height = window.height().max(1) as f64;
    let paintable = gtk::WidgetPaintable::new(Some(window));
    let snapshot = gtk::Snapshot::new();
    paintable.snapshot(&snapshot, width, height);

    let Some(node) = snapshot.to_node() else {
        tracing::warn!(target: "ui", "screenshot: empty snapshot");
        return;
    };
    let Some(renderer) = window.native().and_then(|n| n.renderer()) else {
        tracing::warn!(target: "ui", "screenshot: no renderer");
        return;
    };
    let texture = renderer.render_texture(&node, None);
    let bytes = texture.save_to_png_bytes();
    match std::fs::write(path, bytes.as_ref()) {
        Ok(()) => tracing::info!(target: "ui", "screenshot saved to {path}"),
        Err(error) => tracing::warn!(target: "ui", "screenshot failed: {error}"),
    }
}

fn install_shortcuts(sender: &ComponentSender<App>) {
    let app = relm4::main_application();
    let bind = |name: &str, accels: &[&str], make: fn() -> AppInput| {
        let action = gtk::gio::SimpleAction::new(name, None);
        let sender = sender.clone();
        action.connect_activate(move |_, _| sender.input(make()));
        app.add_action(&action);
        app.set_accels_for_action(&format!("app.{name}"), accels);
    };

    bind("foryou", &["<primary>1"], || AppInput::Sidebar(0));
    bind("following", &["<primary>2"], || AppInput::Sidebar(1));
    bind("notifications", &["<primary>3"], || AppInput::Sidebar(2));
    bind("search", &["<primary>f"], || AppInput::Sidebar(3));
    bind("mentions", &["<primary>5"], || AppInput::Sidebar(4));
    bind("bookmarks", &["<primary>6"], || AppInput::Sidebar(5));
    bind("settings", &["<primary>comma"], || AppInput::Sidebar(6));
    bind("compose", &["<primary>n"], || {
        AppInput::Route(Route::ComposeNew)
    });
    bind("refresh", &["<primary>r"], || AppInput::RefreshCurrent);
}

fn sidebar_row(label: &str, icon: &str) -> gtk::ListBoxRow {
    let row = gtk::ListBoxRow::new();
    let content = gtk::Box::new(gtk::Orientation::Horizontal, 12);
    content.set_margin_top(10);
    content.set_margin_bottom(10);
    content.set_margin_start(12);
    content.set_margin_end(12);
    content.append(&gtk::Image::from_icon_name(icon));
    content.append(&gtk::Label::new(Some(label)));
    row.set_child(Some(&content));
    row
}

fn build_status(title: &str, description: &str, spinner: bool) -> adw::StatusPage {
    let status = adw::StatusPage::new();
    status.set_title(title);
    status.set_description(Some(description));
    status.set_icon_name(Some("network-transmit-receive-symbolic"));
    if spinner {
        let spin = gtk::Spinner::new();
        spin.start();
        spin.set_size_request(32, 32);
        status.set_child(Some(&spin));
    }
    status
}

/// Wraps a screen that already provides its own `ToolbarView`/`HeaderBar`.
fn wrap_page(title: &str, content: &impl IsA<gtk::Widget>) -> adw::NavigationPage {
    adw::NavigationPage::new(content, title)
}

/// Wraps the header-less loading/error `StatusPage` in a toolbar so it still
/// has a title bar.
fn status_page(title: &str, status: &adw::StatusPage) -> adw::NavigationPage {
    let header = adw::HeaderBar::new();
    let toolbar = adw::ToolbarView::new();
    toolbar.add_top_bar(&header);
    toolbar.set_content(Some(status));
    adw::NavigationPage::new(&toolbar, title)
}

fn apply_appearance(mode: AppearanceMode) {
    let scheme = match mode {
        AppearanceMode::System => adw::ColorScheme::Default,
        AppearanceMode::Light => adw::ColorScheme::ForceLight,
        AppearanceMode::Dark => adw::ColorScheme::ForceDark,
    };
    adw::StyleManager::default().set_color_scheme(scheme);
}

fn apply_css(scale: FontScale) {
    let percent = (scale.multiplier() * 100.0).round() as i32;
    relm4::set_global_css(&format!("* {{ font-size: {percent}%; }}\n{BASE_CSS}"));
}
