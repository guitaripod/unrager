//! Streaming LLM sheet for Ask / Brief / Translate. Opens an `AdwDialog`, drives
//! the matching SSE stream from the core client, and appends tokens into a
//! `TextView` as they arrive. Closing the dialog drops the command, which aborts
//! the underlying HTTP request.

use crate::shared::Ctx;
use adw::prelude::*;
use futures::StreamExt;
use relm4::prelude::*;
use std::sync::Arc;
use unrager_gtk_core::model::{AskPreset, TokenEvent};
use unrager_gtk_core::{ApiClient, ApiError};

#[derive(Debug, Clone)]
pub enum StreamRequest {
    Ask { tweet_id: String, preset: AskPreset },
    Brief { handle: String },
    Translate { tweet_id: String },
}

impl StreamRequest {
    fn title(&self) -> String {
        match self {
            StreamRequest::Ask { preset, .. } => format!("Ask · {}", preset_title(*preset)),
            StreamRequest::Brief { handle } => format!("Brief · @{handle}"),
            StreamRequest::Translate { .. } => "Translation".to_string(),
        }
    }
}

pub struct StreamInit {
    pub ctx: Ctx,
    pub request: StreamRequest,
}

pub struct StreamSheet {
    buffer: gtk::TextBuffer,
    spinner: gtk::Spinner,
    banner: adw::Banner,
}

#[derive(Debug)]
pub enum StreamCmd {
    Token(String),
    Done,
    Error(String),
}

#[relm4::component(pub)]
impl Component for StreamSheet {
    type Init = StreamInit;
    type Input = ();
    type Output = ();
    type CommandOutput = StreamCmd;

    view! {
        adw::Dialog {
            set_content_width: 540,
            set_content_height: 620,

            #[wrap(Some)]
            set_child = &adw::ToolbarView {
                add_top_bar = &adw::HeaderBar {},

                #[wrap(Some)]
                set_content = &gtk::ScrolledWindow {
                    set_vexpand: true,

                    gtk::Box {
                        set_orientation: gtk::Orientation::Vertical,

                        #[local_ref]
                        banner -> adw::Banner {
                            set_revealed: false,
                        },

                        #[local_ref]
                        spinner -> gtk::Spinner {
                            set_halign: gtk::Align::Center,
                            set_margin_top: 24,
                            set_size_request: (32, 32),
                        },

                        gtk::TextView {
                            set_buffer: Some(&model.buffer),
                            set_editable: false,
                            set_cursor_visible: false,
                            set_wrap_mode: gtk::WrapMode::WordChar,
                            set_left_margin: 16,
                            set_right_margin: 16,
                            set_top_margin: 12,
                            set_bottom_margin: 16,
                            add_css_class: "stream-text",
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
        root.set_title(&init.request.title());

        let buffer = gtk::TextBuffer::new(None);
        let spinner = gtk::Spinner::new();
        spinner.start();
        let banner = adw::Banner::new("");

        let model = StreamSheet {
            buffer,
            spinner: spinner.clone(),
            banner: banner.clone(),
        };
        let spinner = &model.spinner;
        let banner = &model.banner;
        let widgets = view_output!();

        let api = init.ctx.api.clone();
        let request = init.request;
        sender.command(move |out, shutdown| {
            shutdown
                .register(async move {
                    drive(api, request, &out).await;
                })
                .drop_on_shutdown()
        });

        ComponentParts { model, widgets }
    }

    fn update_cmd(
        &mut self,
        message: Self::CommandOutput,
        _sender: ComponentSender<Self>,
        _root: &Self::Root,
    ) {
        match message {
            StreamCmd::Token(token) => {
                self.spinner.set_visible(false);
                let mut end = self.buffer.end_iter();
                self.buffer.insert(&mut end, &token);
            }
            StreamCmd::Done => {
                self.spinner.set_visible(false);
                if self.buffer.char_count() == 0 {
                    self.buffer.set_text("No response.");
                }
            }
            StreamCmd::Error(message) => {
                self.spinner.set_visible(false);
                self.banner.set_title(&message);
                self.banner.set_revealed(true);
            }
        }
    }
}

async fn drive(api: Arc<ApiClient>, request: StreamRequest, out: &relm4::Sender<StreamCmd>) {
    match request {
        StreamRequest::Ask { tweet_id, preset } => {
            pump(api.ask_stream(&tweet_id, preset), out).await
        }
        StreamRequest::Brief { handle } => pump(api.brief_stream(&handle), out).await,
        StreamRequest::Translate { tweet_id } => pump(api.translate_stream(&tweet_id), out).await,
    }
}

async fn pump<S>(stream: S, out: &relm4::Sender<StreamCmd>)
where
    S: futures::Stream<Item = Result<TokenEvent, ApiError>>,
{
    let mut stream = std::pin::pin!(stream);
    while let Some(item) = stream.next().await {
        match item {
            Ok(event) => {
                if !event.token.is_empty() {
                    let _ = out.send(StreamCmd::Token(event.token));
                }
                if event.done {
                    break;
                }
            }
            Err(error) => {
                let _ = out.send(StreamCmd::Error(error.user_message()));
                return;
            }
        }
    }
    let _ = out.send(StreamCmd::Done);
}

fn preset_title(preset: AskPreset) -> &'static str {
    match preset {
        AskPreset::Explain => "Explain",
        AskPreset::Summary => "Summary",
        AskPreset::Counter => "Counterpoint",
        AskPreset::Eli5 => "ELI5",
        AskPreset::Entities => "Entities",
    }
}
