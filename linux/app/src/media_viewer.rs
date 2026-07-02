//! Fullscreen-ish media viewer in its own window (matching the macOS app's
//! borderless media window): a `gtk::Stack` that shows either a contained
//! `Picture` (photos) or an autoplaying `gtk::Video` (video/GIF, via the GTK4
//! GStreamer backend), with prev/next paging and Left/Right/Escape keys.

use crate::shared::{Ctx, MediaRef};
use adw::prelude::*;
use gtk::{gdk, gio, glib};
use relm4::prelude::*;

pub struct MediaViewerInit {
    pub ctx: Ctx,
    pub tweet_id: String,
    pub items: Vec<MediaRef>,
    pub start: usize,
}

pub struct MediaViewer {
    ctx: Ctx,
    tweet_id: String,
    items: Vec<MediaRef>,
    pos: usize,
    picture: gtk::Picture,
    video: gtk::Video,
    stack: gtk::Stack,
    counter: gtk::Label,
}

#[derive(Debug)]
pub enum MediaViewerInput {
    Next,
    Prev,
    OpenInBrowser,
}

#[relm4::component(pub)]
impl Component for MediaViewer {
    type Init = MediaViewerInit;
    type Input = MediaViewerInput;
    type Output = ();
    type CommandOutput = ();

    view! {
        adw::Window {
            set_title: Some("Media"),
            set_default_size: (940, 740),

            #[wrap(Some)]
            set_content = &adw::ToolbarView {
                add_top_bar = &adw::HeaderBar {
                    pack_start = &gtk::Button {
                        set_icon_name: "go-previous-symbolic",
                        set_tooltip_text: Some("Previous"),
                        #[watch]
                        set_sensitive: model.pos > 0,
                        connect_clicked => MediaViewerInput::Prev,
                    },
                    pack_end = &gtk::Button {
                        set_icon_name: "go-next-symbolic",
                        set_tooltip_text: Some("Next"),
                        #[watch]
                        set_sensitive: model.pos + 1 < model.items.len(),
                        connect_clicked => MediaViewerInput::Next,
                    },
                    pack_end = &gtk::Button {
                        set_icon_name: "web-browser-symbolic",
                        set_tooltip_text: Some("Open on X"),
                        connect_clicked => MediaViewerInput::OpenInBrowser,
                    },
                    set_title_widget: Some(counter),
                },

                set_content: Some(stack),
            }
        }
    }

    fn init(
        init: Self::Init,
        root: Self::Root,
        sender: ComponentSender<Self>,
    ) -> ComponentParts<Self> {
        let picture = gtk::Picture::new();
        picture.set_vexpand(true);
        picture.set_hexpand(true);
        picture.set_content_fit(gtk::ContentFit::Contain);

        let video = gtk::Video::new();
        video.set_vexpand(true);
        video.set_hexpand(true);
        video.set_autoplay(true);

        let stack = gtk::Stack::new();
        stack.set_margin_top(8);
        stack.set_margin_bottom(8);
        stack.set_margin_start(8);
        stack.set_margin_end(8);
        stack.add_named(&picture, Some("photo"));
        stack.add_named(&video, Some("video"));

        let counter = gtk::Label::new(None);

        let items = if init.items.is_empty() {
            vec![MediaRef {
                index: 0,
                video: false,
            }]
        } else {
            init.items
        };
        let pos = init.start.min(items.len() - 1);
        let model = MediaViewer {
            ctx: init.ctx,
            tweet_id: init.tweet_id,
            items,
            pos,
            picture,
            video,
            stack: stack.clone(),
            counter: counter.clone(),
        };

        let stack = &model.stack;
        let counter = &model.counter;
        let widgets = view_output!();

        install_keys(&root, &sender);
        model.show();
        ComponentParts { model, widgets }
    }

    fn update(&mut self, message: Self::Input, _sender: ComponentSender<Self>, root: &Self::Root) {
        match message {
            MediaViewerInput::Next => {
                if self.pos + 1 < self.items.len() {
                    self.pos += 1;
                    self.show();
                }
            }
            MediaViewerInput::Prev => {
                if self.pos > 0 {
                    self.pos -= 1;
                    self.show();
                }
            }
            MediaViewerInput::OpenInBrowser => {
                let url = format!("https://x.com/i/status/{}", self.tweet_id);
                gtk::UriLauncher::new(&url).launch(Some(root), gio::Cancellable::NONE, |_| {});
            }
        }
    }
}

impl MediaViewer {
    fn show(&self) {
        let item = self.items[self.pos];
        let url = self.ctx.api.media_url(&self.tweet_id, item.index);
        if item.video {
            self.picture.set_paintable(gdk::Paintable::NONE);
            self.video.set_file(Some(&gio::File::for_uri(url.as_str())));
            self.stack.set_visible_child_name("video");
        } else {
            self.video.set_file(gio::File::NONE);
            self.picture.set_paintable(gdk::Paintable::NONE);
            self.ctx.load_media_view(&self.picture, url);
            self.stack.set_visible_child_name("photo");
        }
        self.counter
            .set_label(&format!("{} / {}", self.pos + 1, self.items.len()));
    }
}

/// Left/Right page, Escape closes — a media viewer should answer the keyboard,
/// not only its two header buttons.
fn install_keys(window: &adw::Window, sender: &ComponentSender<MediaViewer>) {
    let controller = gtk::EventControllerKey::new();
    let sender = sender.clone();
    let win = window.clone();
    controller.connect_key_pressed(move |_, keyval, _, _| {
        match keyval {
            gdk::Key::Left => sender.input(MediaViewerInput::Prev),
            gdk::Key::Right => sender.input(MediaViewerInput::Next),
            gdk::Key::Escape => win.close(),
            _ => return glib::Propagation::Proceed,
        }
        glib::Propagation::Stop
    });
    window.add_controller(controller);
}
