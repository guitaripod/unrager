//! Fullscreen-ish media viewer in its own window (matching the macOS app's
//! borderless media window): a contained `Picture` with prev/next paging across
//! a tweet's images.

use crate::shared::Ctx;
use adw::prelude::*;
use relm4::prelude::*;

pub struct MediaViewerInit {
    pub ctx: Ctx,
    pub tweet_id: String,
    pub indices: Vec<usize>,
    pub start: usize,
}

pub struct MediaViewer {
    ctx: Ctx,
    tweet_id: String,
    indices: Vec<usize>,
    pos: usize,
    picture: gtk::Picture,
    counter: gtk::Label,
}

#[derive(Debug)]
pub enum MediaViewerInput {
    Next,
    Prev,
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
                        set_sensitive: model.pos + 1 < model.indices.len(),
                        connect_clicked => MediaViewerInput::Next,
                    },
                    set_title_widget: Some(counter),
                },

                #[wrap(Some)]
                set_content = &gtk::Box {
                    set_orientation: gtk::Orientation::Vertical,

                    #[local_ref]
                    picture -> gtk::Picture {
                        set_vexpand: true,
                        set_hexpand: true,
                        set_content_fit: gtk::ContentFit::Contain,
                        set_margin_top: 8,
                        set_margin_bottom: 8,
                        set_margin_start: 8,
                        set_margin_end: 8,
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
        let picture = gtk::Picture::new();
        let counter = gtk::Label::new(None);

        let indices = if init.indices.is_empty() {
            vec![0]
        } else {
            init.indices
        };
        let pos = init.start.min(indices.len() - 1);
        let model = MediaViewer {
            ctx: init.ctx,
            tweet_id: init.tweet_id,
            indices,
            pos,
            picture: picture.clone(),
            counter: counter.clone(),
        };

        let picture = &model.picture;
        let counter = &model.counter;
        let widgets = view_output!();
        model.show();
        ComponentParts { model, widgets }
    }

    fn update(&mut self, message: Self::Input, _sender: ComponentSender<Self>, _root: &Self::Root) {
        match message {
            MediaViewerInput::Next => {
                if self.pos + 1 < self.indices.len() {
                    self.pos += 1;
                    self.show();
                }
            }
            MediaViewerInput::Prev => {
                self.pos = self.pos.saturating_sub(1);
                self.show();
            }
        }
    }
}

impl MediaViewer {
    fn show(&self) {
        let index = self.indices[self.pos];
        let url = self.ctx.api.media_url(&self.tweet_id, index);
        self.ctx
            .images
            .load(&self.picture, self.ctx.api.clone(), url);
        self.counter
            .set_label(&format!("{} / {}", self.pos + 1, self.indices.len()));
    }
}
