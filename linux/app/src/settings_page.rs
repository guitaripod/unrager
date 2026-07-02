//! Settings, presented as an `AdwPreferencesDialog`. Mirrors the Apple apps'
//! Settings: server URL + test connection, appearance, text size, and the
//! feed/filter toggles. Edits stream out as `Changed(AppSettings)`; the shell
//! persists and applies them.

use crate::shared::Ctx;
use adw::prelude::*;
use relm4::prelude::*;
use unrager_gtk_core::settings::normalize_server_url;
use unrager_gtk_core::{ApiClient, AppSettings, AppearanceMode, FontScale, MediaSize};

pub struct SettingsInit {
    pub ctx: Ctx,
    pub settings: AppSettings,
}

pub struct Settings {
    ctx: Ctx,
    settings: AppSettings,
    /// The Server URL entry itself; reading `server_row.text()` at use time
    /// means the Test button always exercises the address the user is looking
    /// at, without mirroring every keystroke into the model.
    server_row: adw::EntryRow,
    status_row: adw::ActionRow,
    test_button: gtk::Button,
    test_spinner: gtk::Spinner,
}

#[derive(Debug)]
pub enum SettingsInput {
    ServerUrl(String),
    TestConnection,
    Appearance(u32),
    FontScale(u32),
    MediaSize(u32),
    Images(bool),
    TrackSeen(bool),
    Filter(bool),
}

#[derive(Debug)]
pub enum SettingsOutput {
    Changed(AppSettings),
}

#[derive(Debug)]
pub enum SettingsCmd {
    Tested(Result<String, String>),
}

#[relm4::component(pub)]
impl Component for Settings {
    type Init = SettingsInit;
    type Input = SettingsInput;
    type Output = SettingsOutput;
    type CommandOutput = SettingsCmd;

    view! {
        adw::PreferencesDialog {
            set_title: "Settings",

            add = &adw::PreferencesPage {
                add = &adw::PreferencesGroup {
                    set_title: "Server",

                    #[local_ref]
                    server_row -> adw::EntryRow {},

                    #[local_ref]
                    status_row -> adw::ActionRow {},
                },

                add = &adw::PreferencesGroup {
                    set_title: "Appearance",

                    adw::ComboRow {
                        set_title: "Theme",
                        set_model: Some(&gtk::StringList::new(&["System", "Light", "Dark"])),
                        set_selected: appearance_index(model.settings.appearance),
                        connect_selected_notify[sender] => move |row| {
                            sender.input(SettingsInput::Appearance(row.selected()));
                        },
                    },

                    adw::ComboRow {
                        set_title: "Text size",
                        set_model: Some(&gtk::StringList::new(&["S", "M", "L", "XL", "XXL"])),
                        set_selected: fontscale_index(model.settings.font_scale),
                        connect_selected_notify[sender] => move |row| {
                            sender.input(SettingsInput::FontScale(row.selected()));
                        },
                    },

                    adw::ComboRow {
                        set_title: "Media size",
                        set_subtitle: "How large inline images and video appear",
                        set_model: Some(&gtk::StringList::new(&["Compact", "Standard", "Large"])),
                        set_selected: mediasize_index(model.settings.media_size),
                        connect_selected_notify[sender] => move |row| {
                            sender.input(SettingsInput::MediaSize(row.selected()));
                        },
                    },
                },

                add = &adw::PreferencesGroup {
                    set_title: "Feed",

                    adw::SwitchRow {
                        set_title: "Load images",
                        set_active: model.settings.images_enabled,
                        connect_active_notify[sender] => move |row| {
                            sender.input(SettingsInput::Images(row.is_active()));
                        },
                    },

                    adw::SwitchRow {
                        set_title: "Track seen tweets",
                        set_active: model.settings.track_seen,
                        connect_active_notify[sender] => move |row| {
                            sender.input(SettingsInput::TrackSeen(row.is_active()));
                        },
                    },

                    adw::SwitchRow {
                        set_title: "Hide rage tweets",
                        set_subtitle: "Filters the feed with the server's local LLM",
                        set_active: model.settings.filter_enabled,
                        connect_active_notify[sender] => move |row| {
                            sender.input(SettingsInput::Filter(row.is_active()));
                        },
                    },
                },
            }
        }
    }

    fn init(
        init: Self::Init,
        root: Self::Root,
        sender: ComponentSender<Self>,
    ) -> ComponentParts<Self> {
        let server_row = adw::EntryRow::new();
        server_row.set_title("Server URL");
        server_row.set_text(&init.settings.server_url);
        server_row.set_show_apply_button(true);
        let apply_sender = sender.clone();
        server_row.connect_apply(move |row| {
            apply_sender.input(SettingsInput::ServerUrl(row.text().to_string()));
        });

        let status_row = adw::ActionRow::new();
        status_row.set_title("Connection");
        status_row.set_subtitle("Not tested");
        status_row.set_subtitle_lines(0);
        status_row.set_subtitle_selectable(true);

        let test_spinner = gtk::Spinner::new();
        test_spinner.start();
        test_spinner.set_valign(gtk::Align::Center);
        test_spinner.set_visible(false);

        let test_button = gtk::Button::with_label("Test");
        test_button.set_valign(gtk::Align::Center);
        test_button.add_css_class("flat");
        let test_sender = sender.clone();
        test_button.connect_clicked(move |_| test_sender.input(SettingsInput::TestConnection));

        status_row.add_suffix(&test_spinner);
        status_row.add_suffix(&test_button);

        let model = Settings {
            ctx: init.ctx,
            settings: init.settings,
            server_row: server_row.clone(),
            status_row: status_row.clone(),
            test_button: test_button.clone(),
            test_spinner: test_spinner.clone(),
        };
        let server_row = &model.server_row;
        let status_row = &model.status_row;
        let widgets = view_output!();
        ComponentParts { model, widgets }
    }

    fn update(&mut self, message: Self::Input, sender: ComponentSender<Self>, _root: &Self::Root) {
        match message {
            SettingsInput::ServerUrl(value) => {
                self.settings.server_url = value;
                self.emit(&sender);
            }
            SettingsInput::Appearance(index) => {
                self.settings.appearance = appearance_from(index);
                self.emit(&sender);
            }
            SettingsInput::FontScale(index) => {
                self.settings.font_scale = fontscale_from(index);
                self.emit(&sender);
            }
            SettingsInput::MediaSize(index) => {
                self.settings.media_size = mediasize_from(index);
                self.emit(&sender);
            }
            SettingsInput::Images(value) => {
                self.settings.images_enabled = value;
                self.emit(&sender);
            }
            SettingsInput::TrackSeen(value) => {
                self.settings.track_seen = value;
                self.emit(&sender);
            }
            SettingsInput::Filter(value) => {
                self.settings.filter_enabled = value;
                self.emit(&sender);
                let api = self.ctx.api.clone();
                relm4::spawn(async move {
                    let _ = api.set_filter_enabled(value).await;
                });
            }
            SettingsInput::TestConnection => {
                let Some(url) = normalize_server_url(&self.server_row.text()) else {
                    self.status_row.set_subtitle("Not a valid server URL");
                    return;
                };
                self.status_row.set_subtitle("Testing…");
                self.test_spinner.set_visible(true);
                self.test_button.set_sensitive(false);
                let api = ApiClient::new(url);
                sender.oneshot_command(async move {
                    SettingsCmd::Tested(
                        api.whoami()
                            .await
                            .map(|w| format!("Connected as @{}", w.handle))
                            .map_err(|e| e.user_message()),
                    )
                });
            }
        }
    }

    fn update_cmd(
        &mut self,
        message: Self::CommandOutput,
        _sender: ComponentSender<Self>,
        _root: &Self::Root,
    ) {
        let SettingsCmd::Tested(result) = message;
        self.test_spinner.set_visible(false);
        self.test_button.set_sensitive(true);
        match result {
            Ok(message) => self.status_row.set_subtitle(&message),
            Err(message) => self.status_row.set_subtitle(&message),
        }
    }
}

impl Settings {
    fn emit(&self, sender: &ComponentSender<Self>) {
        sender
            .output(SettingsOutput::Changed(self.settings.clone()))
            .ok();
    }
}

fn appearance_index(mode: AppearanceMode) -> u32 {
    match mode {
        AppearanceMode::System => 0,
        AppearanceMode::Light => 1,
        AppearanceMode::Dark => 2,
    }
}

fn appearance_from(index: u32) -> AppearanceMode {
    match index {
        1 => AppearanceMode::Light,
        2 => AppearanceMode::Dark,
        _ => AppearanceMode::System,
    }
}

fn fontscale_index(scale: FontScale) -> u32 {
    match scale {
        FontScale::Small => 0,
        FontScale::Standard => 1,
        FontScale::Large => 2,
        FontScale::XLarge => 3,
        FontScale::XxLarge => 4,
    }
}

fn fontscale_from(index: u32) -> FontScale {
    match index {
        0 => FontScale::Small,
        2 => FontScale::Large,
        3 => FontScale::XLarge,
        4 => FontScale::XxLarge,
        _ => FontScale::Standard,
    }
}

fn mediasize_index(size: MediaSize) -> u32 {
    match size {
        MediaSize::Compact => 0,
        MediaSize::Standard => 1,
        MediaSize::Large => 2,
    }
}

fn mediasize_from(index: u32) -> MediaSize {
    match index {
        0 => MediaSize::Compact,
        2 => MediaSize::Large,
        _ => MediaSize::Standard,
    }
}
