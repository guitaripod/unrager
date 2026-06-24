//! Compose / reply dialog. Like the Apple apps it does not post directly: it
//! copies the draft to the clipboard, opens the X intent in the browser, and
//! (for replies) optimistically likes the parent — then dismisses.

use crate::shared::Ctx;
use adw::prelude::*;
use relm4::prelude::*;
use url::Url;

const LIMIT: i32 = 280;

#[derive(Debug, Clone)]
pub enum ComposeMode {
    New,
    Reply { tweet_id: String },
}

pub struct ComposeInit {
    pub ctx: Ctx,
    pub mode: ComposeMode,
}

pub struct Compose {
    ctx: Ctx,
    mode: ComposeMode,
    buffer: gtk::TextBuffer,
    counter: gtk::Label,
}

#[derive(Debug)]
pub enum ComposeInput {
    TextChanged,
    Post,
}

#[relm4::component(pub)]
impl Component for Compose {
    type Init = ComposeInit;
    type Input = ComposeInput;
    type Output = ();
    type CommandOutput = ();

    view! {
        adw::Dialog {
            set_title: title(&model.mode),
            set_content_width: 520,
            set_content_height: 420,

            #[wrap(Some)]
            set_child = &adw::ToolbarView {
                add_top_bar = &adw::HeaderBar {
                    pack_end = &gtk::Button {
                        set_label: "Post on X",
                        add_css_class: "suggested-action",
                        connect_clicked => ComposeInput::Post,
                    },
                },

                #[wrap(Some)]
                set_content = &gtk::Box {
                    set_orientation: gtk::Orientation::Vertical,

                    gtk::ScrolledWindow {
                        set_vexpand: true,

                        gtk::TextView {
                            set_buffer: Some(&model.buffer),
                            set_wrap_mode: gtk::WrapMode::WordChar,
                            set_left_margin: 16,
                            set_right_margin: 16,
                            set_top_margin: 16,
                            set_bottom_margin: 8,
                            add_css_class: "compose-text",
                        }
                    },

                    #[local_ref]
                    counter -> gtk::Label {
                        set_halign: gtk::Align::End,
                        set_margin_end: 16,
                        set_margin_bottom: 12,
                        add_css_class: "dim-label",
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
        let buffer = gtk::TextBuffer::new(None);
        let counter = gtk::Label::new(Some(&LIMIT.to_string()));

        let changed_sender = sender.clone();
        buffer.connect_changed(move |_| changed_sender.input(ComposeInput::TextChanged));

        let model = Compose {
            ctx: init.ctx,
            mode: init.mode,
            buffer,
            counter: counter.clone(),
        };
        let counter = &model.counter;
        let widgets = view_output!();
        ComponentParts { model, widgets }
    }

    fn update(&mut self, message: Self::Input, _sender: ComponentSender<Self>, root: &Self::Root) {
        match message {
            ComposeInput::TextChanged => {
                let remaining = LIMIT - self.buffer.char_count();
                self.counter.set_label(&remaining.to_string());
                if remaining < 0 {
                    self.counter.add_css_class("error");
                } else {
                    self.counter.remove_css_class("error");
                }
            }
            ComposeInput::Post => {
                let text = self
                    .buffer
                    .text(&self.buffer.start_iter(), &self.buffer.end_iter(), false)
                    .to_string();

                root.clipboard().set_text(&text);

                if let ComposeMode::Reply { tweet_id } = &self.mode {
                    let api = self.ctx.api.clone();
                    let id = tweet_id.clone();
                    relm4::spawn(async move {
                        let _ = api.like(&id).await;
                    });
                }

                if let Some(url) = intent_url(&self.mode, &text) {
                    let parent = root.root().and_downcast::<gtk::Window>();
                    gtk::UriLauncher::new(url.as_str()).launch(
                        parent.as_ref(),
                        gtk::gio::Cancellable::NONE,
                        |_| {},
                    );
                }

                root.close();
            }
        }
    }
}

fn title(mode: &ComposeMode) -> &'static str {
    match mode {
        ComposeMode::New => "Compose",
        ComposeMode::Reply { .. } => "Reply",
    }
}

fn intent_url(mode: &ComposeMode, text: &str) -> Option<Url> {
    match mode {
        ComposeMode::New => {
            Url::parse_with_params("https://x.com/intent/post", &[("text", text)]).ok()
        }
        ComposeMode::Reply { tweet_id } => Url::parse_with_params(
            "https://x.com/intent/post",
            &[("text", text), ("in_reply_to", tweet_id.as_str())],
        )
        .ok(),
    }
}
