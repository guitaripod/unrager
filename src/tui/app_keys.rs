use super::app::{
    ActivePane, App, DisplayNameStyle, InlineThread, InputMode, MetricsStyle, TimestampStyle,
};
use crate::tui::command::{self, Command};
use crate::tui::engage::EngageAction;
use crate::tui::event::Event;
use crate::tui::focus::FocusEntry;
use crate::tui::source::SourceKind;
use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

enum AskAction {
    Preset(usize),
}

impl App {
    pub(super) fn handle_key(&mut self, key: KeyEvent) {
        if matches!(self.mode, InputMode::Command) {
            self.handle_key_command(key);
            return;
        }
        if self.active == ActivePane::Detail
            && matches!(self.focus_stack.last(), Some(FocusEntry::Ask(_)))
        {
            self.handle_key_ask(key);
            return;
        }
        if self.active == ActivePane::Detail
            && matches!(self.focus_stack.last(), Some(FocusEntry::Brief(_)))
        {
            self.handle_key_brief(key);
            return;
        }
        if self.active == ActivePane::Detail
            && matches!(
                self.focus_stack.last(),
                Some(FocusEntry::Tweet(d)) if d.reply_bar.is_some()
            )
        {
            self.handle_key_reply(key);
            return;
        }
        if matches!(self.mode, InputMode::Help | InputMode::Changelog) {
            let scroll = if self.mode == InputMode::Help {
                &mut self.help_scroll
            } else {
                &mut self.changelog_scroll
            };
            match key.code {
                KeyCode::Char('j') | KeyCode::Down => *scroll = scroll.saturating_add(1),
                KeyCode::Char('k') | KeyCode::Up => *scroll = scroll.saturating_sub(1),
                KeyCode::Char('d') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                    *scroll = scroll.saturating_add(10);
                }
                KeyCode::Char('u') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                    *scroll = scroll.saturating_sub(10);
                }
                KeyCode::Char('g') => *scroll = 0,
                KeyCode::Char('G') => *scroll = u16::MAX,
                _ => {
                    self.mode = InputMode::Normal;
                    self.help_scroll = 0;
                    self.changelog_scroll = 0;
                }
            }
            return;
        }
        match (key.code, key.modifiers) {
            (KeyCode::Char('c'), KeyModifiers::CONTROL) => self.running = false,
            (KeyCode::Tab, _) if self.is_split() => {
                self.active = match self.active {
                    ActivePane::Source => ActivePane::Detail,
                    ActivePane::Detail => ActivePane::Source,
                };
            }
            (KeyCode::Char(':'), _) => {
                self.mode = InputMode::Command;
                self.command_buffer.clear();
                self.error = None;
            }
            (KeyCode::Char('?'), _) => {
                self.mode = InputMode::Help;
                self.help_scroll = 0;
            }
            (KeyCode::Char('W'), _) => {
                self.mode = InputMode::Changelog;
                self.changelog_scroll = 0;
                if self.changelog.is_none() && !self.changelog_loading {
                    self.changelog_loading = true;
                    let tx = self.tx.clone();
                    tokio::spawn(async move {
                        match crate::update::fetch_changelog().await {
                            Ok(releases) => {
                                let _ = tx.send(Event::ChangelogLoaded { releases });
                            }
                            Err(e) => {
                                tracing::warn!("changelog fetch failed: {e}");
                                let _ = tx.send(Event::ChangelogLoaded {
                                    releases: Vec::new(),
                                });
                            }
                        }
                    });
                }
            }
            (KeyCode::Char('t'), KeyModifiers::NONE) => {
                self.timestamps = match self.timestamps {
                    TimestampStyle::Relative => TimestampStyle::Absolute,
                    TimestampStyle::Absolute => TimestampStyle::Relative,
                };
            }
            (KeyCode::Char('Z'), _) => {
                self.is_dark = !self.is_dark;
                let msg = if self.is_dark {
                    "theme: dark"
                } else {
                    "theme: light"
                };
                self.set_status(msg);
            }
            (KeyCode::Char(','), KeyModifiers::NONE) if self.is_split() => {
                self.split_pct = self.split_pct.saturating_sub(5).max(20);
            }
            (KeyCode::Char('.'), KeyModifiers::NONE) if self.is_split() => {
                self.split_pct = (self.split_pct + 5).min(80);
            }
            (KeyCode::Char('V'), _) => self.toggle_feed_mode(),
            (KeyCode::Char('F'), _) => self.toggle_home_mode(),
            (KeyCode::Char('M'), _) => {
                self.metrics = match self.metrics {
                    MetricsStyle::Visible => MetricsStyle::Hidden,
                    MetricsStyle::Hidden => MetricsStyle::Visible,
                };
                let msg = match self.metrics {
                    MetricsStyle::Visible => "metrics on",
                    MetricsStyle::Hidden => "metrics off",
                };
                self.set_status(msg);
                self.save_session();
            }
            (KeyCode::Char('N'), _) => {
                self.display_names = match self.display_names {
                    DisplayNameStyle::Visible => DisplayNameStyle::Hidden,
                    DisplayNameStyle::Hidden => DisplayNameStyle::Visible,
                };
                let msg = match self.display_names {
                    DisplayNameStyle::Visible => "display names on",
                    DisplayNameStyle::Hidden => "display names off (handles only)",
                };
                self.set_status(msg);
                self.save_session();
            }
            (KeyCode::Char('x'), KeyModifiers::NONE) => self.toggle_expand_selected(),
            (KeyCode::Char('I'), _) => {
                self.media_auto_expand = !self.media_auto_expand;
                if self.media_auto_expand {
                    let tweets = self.source.tweets.clone();
                    self.queue_source_media(&tweets);
                    self.set_status("media auto-expand on");
                } else {
                    self.set_status("media auto-expand off");
                }
            }
            (KeyCode::Char('X'), _) => {
                if self.active == ActivePane::Source {
                    if let Some(tweet) = self.source.tweets.get(self.source.selected()).cloned() {
                        self.mark_current_seen();
                        self.push_tweet(tweet);
                    }
                    self.toggle_inline_thread();
                } else if self.active == ActivePane::Detail
                    && !matches!(self.focus_stack.last(), Some(FocusEntry::Notifications(_)))
                {
                    self.toggle_inline_thread();
                }
            }
            (KeyCode::Char('p'), KeyModifiers::NONE) => self.open_profile(),
            (KeyCode::Char('P'), _) => self.open_own_profile_in_browser(),
            (KeyCode::Char('T'), _) => self.translate_selected(),
            (KeyCode::Char('A'), _) => self.open_ask_for_selected(),
            (KeyCode::Char('B'), _) => self.open_brief_for_target(),
            (KeyCode::Char('f'), KeyModifiers::NONE) => self.engage(EngageAction::Like),
            (KeyCode::Char('c'), KeyModifiers::NONE) => self.toggle_filter(),
            (KeyCode::Char('y'), KeyModifiers::NONE) => self.yank_url(),
            (KeyCode::Char('Y'), _) => self.yank_json(),
            (KeyCode::Char('R'), _) => self.toggle_user_replies(),
            (KeyCode::Char('L'), _) => self.show_likers_for_selected(),
            (KeyCode::Char('n'), KeyModifiers::NONE) => {
                self.open_notifications();
            }
            (KeyCode::Char('o'), KeyModifiers::NONE) => self.open_tweet_in_browser(),
            (KeyCode::Char('O'), _) => self.open_author_in_browser(),
            (KeyCode::Char('m'), KeyModifiers::NONE) => self.open_media_external(),
            (KeyCode::Char('q'), KeyModifiers::NONE) => self.back_out(true),
            (KeyCode::Esc, _) => self.back_out(false),
            (KeyCode::Char(']'), _) => self.history_forward(),
            (KeyCode::Char('['), _) => self.history_back(),
            _ => match self.active {
                ActivePane::Source => self.handle_key_source(key),
                ActivePane::Detail => self.handle_key_detail(key),
            },
        }
    }

    fn handle_key_source(&mut self, key: KeyEvent) {
        match (key.code, key.modifiers) {
            (KeyCode::Char('j'), KeyModifiers::NONE) | (KeyCode::Down, _) => {
                self.source.select_next();
                self.mark_current_seen();
                self.maybe_load_more();
            }
            (KeyCode::Char('k'), KeyModifiers::NONE) | (KeyCode::Up, _) => {
                self.source.select_prev();
                self.mark_current_seen();
            }
            (KeyCode::Char('g'), KeyModifiers::NONE) => {
                self.source.jump_top();
                self.mark_current_seen();
            }
            (KeyCode::Char('G'), KeyModifiers::NONE | KeyModifiers::SHIFT) => {
                self.source.jump_bottom();
                self.mark_current_seen();
                self.maybe_load_more();
            }
            (KeyCode::Char('r'), KeyModifiers::NONE) => {
                self.start_reply();
            }
            (KeyCode::Char('r'), KeyModifiers::CONTROL) => self.reload_source(),
            (KeyCode::Char('u'), KeyModifiers::NONE) => self.jump_next_unread(),
            (KeyCode::Char('U'), KeyModifiers::NONE | KeyModifiers::SHIFT) => {
                self.mark_all_seen_in_source();
            }
            (KeyCode::Enter, _) | (KeyCode::Char('l'), KeyModifiers::NONE) => {
                if let Some(tweet) = self.source.tweets.get(self.source.selected()).cloned() {
                    self.mark_current_seen();
                    self.push_tweet(tweet);
                }
            }
            (KeyCode::Char('d'), KeyModifiers::CONTROL) => {
                self.source.advance(10);
                self.mark_current_seen();
                self.maybe_load_more();
            }
            (KeyCode::Char('u'), KeyModifiers::CONTROL) => {
                self.source.advance(-10);
                self.mark_current_seen();
            }
            (KeyCode::Char('h'), KeyModifiers::NONE) | (KeyCode::Left, _) => {
                self.switch_source(SourceKind::Home { following: false });
            }
            _ => {}
        }
    }

    fn handle_key_detail(&mut self, key: KeyEvent) {
        match (key.code, key.modifiers) {
            (KeyCode::Char('j'), KeyModifiers::NONE) | (KeyCode::Down, _) => {
                let stepped = self.step_actor_cursor(1);
                if stepped {
                    return;
                }
                match self.focus_stack.last_mut() {
                    Some(FocusEntry::Tweet(d)) => d.select_next(),
                    Some(FocusEntry::Likers(l)) => {
                        l.select_next();
                        self.maybe_load_more_likers();
                    }
                    Some(FocusEntry::Notifications(n)) => {
                        n.actor_cursor = None;
                        n.select_next();
                        self.mark_current_notif_seen();
                        self.maybe_load_more_notifications();
                    }
                    Some(FocusEntry::Ask(_)) | Some(FocusEntry::Brief(_)) | None => {}
                }
            }
            (KeyCode::Char('k'), KeyModifiers::NONE) | (KeyCode::Up, _) => {
                let stepped = self.step_actor_cursor(-1);
                if stepped {
                    return;
                }
                match self.focus_stack.last_mut() {
                    Some(FocusEntry::Tweet(d)) => d.select_prev(),
                    Some(FocusEntry::Likers(l)) => l.select_prev(),
                    Some(FocusEntry::Notifications(n)) => {
                        n.actor_cursor = None;
                        n.select_prev();
                        self.mark_current_notif_seen();
                    }
                    Some(FocusEntry::Ask(_)) | Some(FocusEntry::Brief(_)) | None => {}
                }
            }
            (KeyCode::Char('g'), KeyModifiers::NONE) => match self.focus_stack.last_mut() {
                Some(FocusEntry::Tweet(d)) => d.jump_top(),
                Some(FocusEntry::Likers(l)) => l.jump_top(),
                Some(FocusEntry::Notifications(n)) => n.jump_top(),
                Some(FocusEntry::Ask(_)) | Some(FocusEntry::Brief(_)) | None => {}
            },
            (KeyCode::Char('G'), KeyModifiers::NONE | KeyModifiers::SHIFT) => {
                match self.focus_stack.last_mut() {
                    Some(FocusEntry::Tweet(d)) => d.jump_bottom(),
                    Some(FocusEntry::Likers(l)) => {
                        l.jump_bottom();
                        self.maybe_load_more_likers();
                    }
                    Some(FocusEntry::Notifications(n)) => {
                        n.jump_bottom();
                        self.maybe_load_more_notifications();
                    }
                    Some(FocusEntry::Ask(_)) | Some(FocusEntry::Brief(_)) | None => {}
                }
            }
            (KeyCode::Char('d'), KeyModifiers::CONTROL) => match self.focus_stack.last_mut() {
                Some(FocusEntry::Tweet(d)) => d.advance(10),
                Some(FocusEntry::Likers(l)) => {
                    l.advance(10);
                    self.maybe_load_more_likers();
                }
                Some(FocusEntry::Notifications(n)) => {
                    n.advance(10);
                    self.maybe_load_more_notifications();
                }
                Some(FocusEntry::Ask(_)) | Some(FocusEntry::Brief(_)) | None => {}
            },
            (KeyCode::Char('u'), KeyModifiers::CONTROL) => match self.focus_stack.last_mut() {
                Some(FocusEntry::Tweet(d)) => d.advance(-10),
                Some(FocusEntry::Likers(l)) => l.advance(-10),
                Some(FocusEntry::Notifications(n)) => n.advance(-10),
                Some(FocusEntry::Ask(_)) | Some(FocusEntry::Brief(_)) | None => {}
            },
            (KeyCode::Char('h'), KeyModifiers::NONE) | (KeyCode::Left, _) => {
                self.active = ActivePane::Source;
            }
            (KeyCode::Char('r'), KeyModifiers::CONTROL) => match self.focus_stack.last() {
                Some(FocusEntry::Tweet(_)) => self.refresh_current_thread(),
                Some(FocusEntry::Notifications(_)) => self.reload_source(),
                _ => {}
            },
            (KeyCode::Char('s'), KeyModifiers::NONE) => self.cycle_reply_sort(),
            (KeyCode::Enter, _) | (KeyCode::Char('l'), KeyModifiers::NONE) => {
                match self.focus_stack.last() {
                    Some(FocusEntry::Tweet(_)) => {
                        if let Some(reply) =
                            self.top_detail().and_then(|d| d.selected_reply()).cloned()
                        {
                            self.push_tweet(reply);
                        }
                    }
                    Some(FocusEntry::Likers(l)) => {
                        if let Some(user) = l.selected_user().cloned() {
                            self.open_user_in_detail(user.handle, Some(user.rest_id));
                        }
                    }
                    Some(FocusEntry::Notifications(_)) => self.open_selected_notification(),
                    Some(FocusEntry::Ask(_)) | Some(FocusEntry::Brief(_)) | None => {}
                }
            }
            (KeyCode::Char('r'), KeyModifiers::NONE)
                if matches!(self.focus_stack.last(), Some(FocusEntry::Tweet(_))) =>
            {
                self.start_reply();
            }
            _ => {}
        }
    }

    fn handle_key_reply(&mut self, key: KeyEvent) {
        use crate::tui::editor::EditorResult;

        if key.code == KeyCode::Char('c') && key.modifiers.contains(KeyModifiers::CONTROL) {
            self.running = false;
            return;
        }
        if key.code == KeyCode::Tab && self.is_split() {
            self.active = match self.active {
                ActivePane::Source => ActivePane::Detail,
                ActivePane::Detail => ActivePane::Source,
            };
            return;
        }

        let result = {
            let Some(FocusEntry::Tweet(detail)) = self.focus_stack.last_mut() else {
                return;
            };
            let Some(bar) = &mut detail.reply_bar else {
                return;
            };
            if bar.sending {
                return;
            }
            bar.editor.handle_key(key)
        };
        match result {
            EditorResult::Submit => self.submit_reply(),
            EditorResult::ExitNormal => {
                if let Some(FocusEntry::Tweet(detail)) = self.focus_stack.last_mut() {
                    detail.reply_bar = None;
                }
            }
            EditorResult::Consumed => {}
        }
    }

    fn handle_key_command(&mut self, key: KeyEvent) {
        match (key.code, key.modifiers) {
            (KeyCode::Esc, _) => {
                self.mode = InputMode::Normal;
                self.command_buffer.clear();
            }
            (KeyCode::Enter, _) => self.run_command_buffer(),
            (KeyCode::Backspace, _) => {
                self.command_buffer.pop();
            }
            (KeyCode::Char(c), _) => {
                self.command_buffer.push(c);
            }
            _ => {}
        }
    }

    fn run_command_buffer(&mut self) {
        let input = std::mem::take(&mut self.command_buffer);
        self.mode = InputMode::Normal;
        match command::parse(&input) {
            Ok(Command::SwitchSource(kind)) => self.switch_source(kind),
            Ok(Command::OpenTweet(id)) => self.open_tweet_by_id(id),
            Ok(Command::OpenNotifications) => self.open_notifications(),
            Ok(Command::Quit) => self.running = false,
            Ok(Command::Help) => {
                self.status =
                    "help: j/k nav, Enter open, h back, q pop, : command, ] forward, [ back".into();
            }
            Err(e) => {
                self.error = Some(e.0);
            }
        }
    }

    fn handle_key_ask(&mut self, key: KeyEvent) {
        use crate::tui::editor::{EditorResult, VimMode};

        if key.code == KeyCode::Char('c') && key.modifiers.contains(KeyModifiers::CONTROL) {
            self.running = false;
            return;
        }
        if key.code == KeyCode::Tab && self.is_split() {
            self.active = match self.active {
                ActivePane::Source => ActivePane::Detail,
                ActivePane::Detail => ActivePane::Source,
            };
            return;
        }

        let result = {
            let Some(FocusEntry::Ask(view)) = self.focus_stack.last_mut() else {
                return;
            };

            if view.editor.mode == VimMode::Normal {
                match (key.code, key.modifiers) {
                    (KeyCode::Char('j'), KeyModifiers::NONE) => {
                        view.auto_follow = false;
                        view.state.scroll = view.state.scroll.saturating_add(1);
                        return;
                    }
                    (KeyCode::Char('k'), KeyModifiers::NONE) => {
                        view.auto_follow = false;
                        view.state.scroll = view.state.scroll.saturating_sub(1);
                        return;
                    }
                    (KeyCode::Char('d'), KeyModifiers::CONTROL) => {
                        view.auto_follow = false;
                        view.state.scroll = view.state.scroll.saturating_add(10);
                        return;
                    }
                    (KeyCode::Char('u'), KeyModifiers::CONTROL) => {
                        view.auto_follow = false;
                        view.state.scroll = view.state.scroll.saturating_sub(10);
                        return;
                    }
                    (KeyCode::Char('G'), _) => {
                        view.state.scroll = u16::MAX;
                        view.auto_follow = true;
                        return;
                    }
                    (KeyCode::Char('g'), KeyModifiers::NONE) => {
                        view.auto_follow = false;
                        view.state.scroll = 0;
                        return;
                    }
                    (KeyCode::Char(c @ '1'..='9'), KeyModifiers::NONE)
                        if !view.streaming && view.editor.input.is_empty() =>
                    {
                        c.to_digit(10).map(|idx| AskAction::Preset(idx as usize))
                    }
                    _ => None,
                }
            } else {
                None
            }
        };

        if let Some(action) = result {
            match action {
                AskAction::Preset(idx) => self.ask_fire_preset(idx),
            }
            return;
        }

        let Some(FocusEntry::Ask(view)) = self.focus_stack.last_mut() else {
            return;
        };

        match (key.code, key.modifiers) {
            (KeyCode::Up, _) | (KeyCode::PageUp, _) => {
                let delta = if key.code == KeyCode::PageUp { 10 } else { 1 };
                view.auto_follow = false;
                view.state.scroll = view.state.scroll.saturating_sub(delta);
            }
            (KeyCode::Down, _) | (KeyCode::PageDown, _) => {
                let delta = if key.code == KeyCode::PageDown { 10 } else { 1 };
                view.state.scroll = view.state.scroll.saturating_add(delta);
            }
            _ => {
                let is_mode_switch = matches!(key.code, KeyCode::Esc)
                    || (key.code == KeyCode::Char('q')
                        && view.editor.mode == VimMode::Normal
                        && key.modifiers == KeyModifiers::NONE);
                if view.streaming && !is_mode_switch {
                    return;
                }
                let result = view.editor.handle_key(key);
                let _ = view;
                match result {
                    EditorResult::Submit => self.ask_submit_input(),
                    EditorResult::ExitNormal => self.back_out(false),
                    EditorResult::Consumed => {}
                }
            }
        }
    }

    fn handle_key_brief(&mut self, key: KeyEvent) {
        enum BriefAction {
            Scroll(i32),
            Jump(u16),
        }

        let action = match (key.code, key.modifiers) {
            (KeyCode::Char('c'), KeyModifiers::CONTROL) => {
                self.running = false;
                return;
            }
            (KeyCode::Esc, _) | (KeyCode::Char('q'), KeyModifiers::NONE) => {
                self.back_out(false);
                return;
            }
            (KeyCode::Tab, _) if self.is_split() => {
                self.active = match self.active {
                    ActivePane::Source => ActivePane::Detail,
                    ActivePane::Detail => ActivePane::Source,
                };
                return;
            }
            (KeyCode::Char('R'), _) => {
                self.refresh_brief();
                return;
            }
            (KeyCode::Char('j'), KeyModifiers::NONE) | (KeyCode::Down, _) => BriefAction::Scroll(1),
            (KeyCode::Char('k'), KeyModifiers::NONE) | (KeyCode::Up, _) => BriefAction::Scroll(-1),
            (KeyCode::Char('d'), KeyModifiers::CONTROL) => BriefAction::Scroll(10),
            (KeyCode::Char('u'), KeyModifiers::CONTROL) => BriefAction::Scroll(-10),
            (KeyCode::Char('f'), KeyModifiers::CONTROL)
            | (KeyCode::PageDown, _)
            | (KeyCode::Char(' '), KeyModifiers::NONE) => BriefAction::Scroll(20),
            (KeyCode::Char('b'), KeyModifiers::CONTROL) | (KeyCode::PageUp, _) => {
                BriefAction::Scroll(-20)
            }
            (KeyCode::Char('g'), KeyModifiers::NONE) | (KeyCode::Home, _) => BriefAction::Jump(0),
            (KeyCode::Char('G'), KeyModifiers::NONE | KeyModifiers::SHIFT) | (KeyCode::End, _) => {
                BriefAction::Jump(u16::MAX)
            }
            _ => return,
        };

        if let Some(FocusEntry::Brief(view)) = self.focus_stack.last_mut() {
            match action {
                BriefAction::Scroll(delta) => {
                    view.scroll = if delta >= 0 {
                        view.scroll.saturating_add(delta as u16)
                    } else {
                        view.scroll.saturating_sub((-delta) as u16)
                    };
                }
                BriefAction::Jump(target) => view.scroll = target,
            }
        }
    }

    fn actor_count_for_current_notif(&self) -> Option<usize> {
        let FocusEntry::Notifications(view) = self.focus_stack.last()? else {
            return None;
        };
        let notif = view.notifications.get(view.selected())?;
        if notif.notification_type != "Follow"
            || notif.actors.len() < 2
            || !self.expanded_bodies.contains(&notif.id)
        {
            return None;
        }
        Some(notif.actors.len())
    }

    fn step_actor_cursor(&mut self, delta: isize) -> bool {
        let Some(count) = self.actor_count_for_current_notif() else {
            return false;
        };
        let Some(FocusEntry::Notifications(view)) = self.focus_stack.last_mut() else {
            return false;
        };
        let current = view.actor_cursor.unwrap_or(0) as isize;
        let next = current + delta;
        if next < 0 || next >= count as isize {
            return false;
        }
        view.actor_cursor = Some(next as usize);
        true
    }

    fn toggle_expand_selected(&mut self) {
        if self.active == ActivePane::Detail
            && matches!(self.focus_stack.last(), Some(FocusEntry::Notifications(_)))
        {
            let Some(FocusEntry::Notifications(view)) = self.focus_stack.last_mut() else {
                return;
            };
            let Some(notif) = view.notifications.get(view.selected()) else {
                return;
            };
            let id = notif.id.clone();
            let is_multi_follow = notif.notification_type == "Follow" && notif.actors.len() > 1;
            if !self.expanded_bodies.remove(&id) {
                self.expanded_bodies.insert(id);
                if let Some(FocusEntry::Notifications(v)) = self.focus_stack.last_mut()
                    && is_multi_follow
                {
                    v.actor_cursor = Some(0);
                }
                self.set_status("expanded");
            } else {
                if let Some(FocusEntry::Notifications(v)) = self.focus_stack.last_mut() {
                    v.actor_cursor = None;
                }
                self.set_status("collapsed");
            }
            return;
        }
        let Some(tweet) = self.selected_tweet().cloned() else {
            return;
        };
        if !self.expanded_bodies.remove(&tweet.rest_id) {
            self.expanded_bodies.insert(tweet.rest_id.clone());
            self.ensure_tweet_resources(&tweet);
            self.set_status("expanded");
        } else {
            self.set_status("collapsed");
        }
    }

    fn toggle_inline_thread(&mut self) {
        let Some(id) = self.selected_tweet().map(|t| t.rest_id.clone()) else {
            return;
        };
        if self.inline_threads.remove(&id).is_some() {
            self.set_status("thread collapsed");
            return;
        }
        self.expanded_bodies.insert(id.clone());
        if let Some(tweet) = self.selected_tweet().cloned() {
            self.ensure_tweet_resources(&tweet);
        }
        self.inline_threads.insert(
            id.clone(),
            InlineThread {
                loading: true,
                replies: Vec::new(),
                error: None,
            },
        );
        self.set_status("loading thread…");
        let client = self.client.clone();
        let tx = self.tx.clone();
        let focal_id = id;
        tokio::spawn(async move {
            let result = crate::tui::focus::fetch_thread_recursive(&client, &focal_id).await;
            let _ = tx.send(Event::InlineThreadLoaded { focal_id, result });
        });
    }
}
