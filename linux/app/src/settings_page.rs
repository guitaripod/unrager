//! Settings, presented as an `AdwPreferencesDialog`. Mirrors the Apple apps'
//! Settings: server URL + test connection, appearance, text size, and the
//! feed/filter toggles. Edits stream out as `Changed(AppSettings)`; the shell
//! persists and applies them.

use crate::shared::Ctx;
use adw::prelude::*;
use relm4::prelude::*;
use unrager_gtk_core::{AppSettings, AppearanceMode, FontScale};

pub struct SettingsInit {
    pub ctx: Ctx,
    pub settings: AppSettings,
}

pub struct Settings {
    ctx: Ctx,
    settings: AppSettings,
    status_row: adw::ActionRow,
}

#[derive(Debug)]
pub enum SettingsInput {
    ServerUrl(String),
    TestConnection,
    Appearance(u32),
    FontScale(u32),
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

                    adw::EntryRow {
                        set_title: "Server URL",
                        set_text: &model.settings.server_url,
                        connect_changed[sender] => move |row| {
                            sender.input(SettingsInput::ServerUrl(row.text().to_string()));
                        },
                    },

                    #[local_ref]
                    status_row -> adw::ActionRow {
                        set_title: "Connection",
                        set_subtitle: "Not tested",
                        add_suffix = &gtk::Button {
                            set_label: "Test",
                            set_valign: gtk::Align::Center,
                            add_css_class: "flat",
                            connect_clicked[sender] => move |_| {
                                sender.input(SettingsInput::TestConnection);
                            },
                        },
                    },
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
                        set_title: "Track seen posts",
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
        let status_row = adw::ActionRow::new();
        let model = Settings {
            ctx: init.ctx,
            settings: init.settings,
            status_row: status_row.clone(),
        };
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
                self.status_row.set_subtitle("Testing…");
                let api = self.ctx.api.clone();
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
