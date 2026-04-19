use crate::model::Tweet;
use crate::parse::notification::RawNotification;
use crate::tui::app::{
    ActivePane, App, DisplayNameStyle, InlineThread, InputMode, MetricsStyle, ReplySortOrder,
    SPINNER_FRAMES, TimestampStyle,
};
use crate::tui::filter::FilterMode;
use crate::tui::focus::FocusEntry;
use crate::tui::media::{self, MediaEntry, MediaRegistry, media_badge_failed, media_badge_loading};
use crate::tui::seen::SeenStore;
use crate::tui::source::PaneState;
use crate::tui::source::{Source, SourceKind};
use crate::tui::theme::{self, Theme};
use crate::util::short_count;
use chrono::{DateTime, Utc};
use ratatui::Frame;
use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Clear, Paragraph, Wrap};
use std::borrow::Cow;
use std::collections::{HashMap, HashSet};

/// Shorthand for acquiring a read guard on the active theme. Render
/// code is single-threaded, so the only contention is a write from a key
/// handler that swaps the theme — which never races the render loop.
fn th() -> std::sync::RwLockReadGuard<'static, Theme> {
    theme::active()
}

pub struct PaneItem {
    pub lines: Vec<Line<'static>>,
}

impl PaneItem {
    pub fn new(lines: Vec<Line<'static>>) -> Self {
        Self { lines }
    }
}

fn highlight_bg(active: bool) -> Color {
    let t = th();
    if active {
        t.sel_bg_active
    } else {
        t.sel_bg_inactive
    }
}

fn apply_line_bg(line: &mut Line<'static>, bg: Color) {
    line.style = line.style.bg(bg);
    for span in line.spans.iter_mut() {
        if span.style.bg.is_none() {
            span.style = span.style.bg(bg);
        }
    }
}

fn pad_line_to_width(line: &mut Line<'static>, target_width: u16, bg: Color) {
    use unicode_width::UnicodeWidthStr;
    let current: usize = line
        .spans
        .iter()
        .map(|s| UnicodeWidthStr::width(s.content.as_ref()))
        .sum();
    let target = target_width as usize;
    if current < target {
        let pad = " ".repeat(target - current);
        line.spans.push(Span::styled(pad, Style::default().bg(bg)));
    }
}

fn prepend_selection_marker(line: &mut Line<'static>, active: bool, highlight_bg: Color) {
    let marker_fg = {
        let t = th();
        if active {
            t.sel_marker_active
        } else {
            t.sel_marker_inactive
        }
    };
    let marker = Span::styled("▌ ", Style::default().fg(marker_fg).bg(highlight_bg));

    if let Some(first) = line.spans.first_mut() {
        let content = first.content.as_ref();
        if content.starts_with("  ") {
            let rest: String = content.chars().skip(2).collect();
            first.content = Cow::Owned(rest);
        }
    }
    line.spans.insert(0, marker);
}

fn render_scrollable(
    frame: &mut Frame,
    area: Rect,
    title: &str,
    items: Vec<PaneItem>,
    state: &mut PaneState,
    selected: Option<usize>,
    active: bool,
) {
    let block = block_with_focus(title, active);
    let inner = block.inner(area);
    let inner_h = inner.height;

    const ITEM_GAP: u16 = 1;
    let n_items = items.len();
    let mut spans: Vec<(u16, u16)> = Vec::with_capacity(n_items);
    let mut cursor: u16 = 0;
    for (i, item) in items.iter().enumerate() {
        let h = item.lines.len() as u16;
        spans.push((cursor, h));
        cursor = cursor.saturating_add(h);
        if i + 1 < n_items {
            cursor = cursor.saturating_add(ITEM_GAP);
        }
    }
    let total_h = cursor;

    let sel = selected.unwrap_or(0).min(items.len().saturating_sub(1));
    let (sel_start, sel_h) = spans.get(sel).copied().unwrap_or((0, 0));
    let sel_end = sel_start.saturating_add(sel_h);

    const SCROLL_MARGIN: u16 = 8;
    let mut scroll = state.scroll;
    if inner_h > 0 {
        let margin = SCROLL_MARGIN.min(inner_h.saturating_sub(sel_h) / 2);
        let desired_top = sel_start.saturating_sub(margin);
        let desired_bottom = sel_end.saturating_add(margin);
        if desired_top < scroll {
            scroll = desired_top;
        }
        if desired_bottom > scroll.saturating_add(inner_h) {
            scroll = if sel_h >= inner_h {
                sel_start
            } else {
                desired_bottom.saturating_sub(inner_h)
            };
        }
    }
    let max_scroll = total_h.saturating_sub(inner_h);
    if scroll > max_scroll {
        scroll = max_scroll;
    }
    state.scroll = scroll;

    let hl_bg = highlight_bg(active);
    let row_width = inner.width;

    let mut flat: Vec<Line<'static>> = Vec::with_capacity(total_h as usize);
    for (i, item) in items.into_iter().enumerate() {
        let is_selected = selected == Some(i);
        let bg = if is_selected { Some(hl_bg) } else { None };
        let mut item_lines = item.lines;
        for line in item_lines.iter_mut() {
            if let Some(bg) = bg {
                apply_line_bg(line, bg);
                prepend_selection_marker(line, active, bg);
                pad_line_to_width(line, row_width, bg);
            }
        }
        flat.extend(item_lines);
        if i + 1 < n_items {
            flat.push(Line::from(Span::styled(
                "─".repeat(row_width as usize),
                Style::default().fg(th().divider),
            )));
        }
    }

    let para = Paragraph::new(flat).block(block).scroll((state.scroll, 0));
    frame.render_widget(para, area);
}

#[derive(Debug, Clone, Copy)]
pub struct RenderOpts {
    pub timestamps: TimestampStyle,
    pub metrics: MetricsStyle,
    pub display_names: DisplayNameStyle,
    pub media_enabled: bool,
    pub media_auto_expand: bool,
    pub media_max_rows: usize,
}

pub struct RenderContext<'a> {
    pub opts: RenderOpts,
    pub raw_display_names: DisplayNameStyle,
    pub seen: &'a SeenStore,
    pub expanded: &'a HashSet<String>,
    pub inline_threads: &'a HashMap<String, InlineThread>,
    pub media_reg: &'a MediaRegistry,
    pub youtube: &'a crate::tui::youtube::YoutubeRegistry,
    pub translations: &'a HashMap<String, String>,
    pub liked_tweet_ids: &'a HashSet<String>,
    pub write_rate_limit: Option<std::time::Duration>,
}

pub fn draw(frame: &mut Frame, app: &mut App) {
    let [top, main, bottom] = Layout::vertical([
        Constraint::Length(1),
        Constraint::Min(0),
        Constraint::Length(1),
    ])
    .areas(frame.area());

    let filter_mode = app.filter_mode;
    let filter_pending = app.filter_pending_count();
    let filter_enabled = app.filter_classifier.is_some();

    draw_header(frame, top, app);

    let source_active = app.active == ActivePane::Source;
    let detail_active = app.active == ActivePane::Detail;
    let own_profile = app.is_own_profile();
    let pane_h = frame.area().height.saturating_sub(2) as usize;
    let opts = RenderOpts {
        timestamps: app.timestamps,
        metrics: if own_profile {
            MetricsStyle::Visible
        } else {
            app.metrics
        },
        display_names: if own_profile {
            DisplayNameStyle::Visible
        } else {
            app.display_names
        },
        media_enabled: app.media.supported(),
        media_auto_expand: app.media_auto_expand,
        media_max_rows: (pane_h.saturating_sub(4) / 2).clamp(6, 24),
    };
    let filter_ctx = FilterRenderCtx {
        mode: filter_mode,
        pending: filter_pending,
        enabled: filter_enabled,
    };

    let ctx = RenderContext {
        opts,
        raw_display_names: app.display_names,
        seen: &app.seen,
        expanded: &app.expanded_bodies,
        inline_threads: &app.inline_threads,
        media_reg: &app.media,
        youtube: &app.youtube,
        translations: &app.translations,
        liked_tweet_ids: &app.liked_tweet_ids,
        write_rate_limit: app.client.write_rate_limit_remaining(),
    };

    if app.is_split() {
        let left_pct = app.split_pct;
        let right_pct = 100 - left_pct;
        let [left, right] = Layout::horizontal([
            Constraint::Percentage(left_pct),
            Constraint::Percentage(right_pct),
        ])
        .areas(main);
        draw_source_list(
            frame,
            left,
            &mut app.source,
            &ctx,
            app.error.as_deref(),
            source_active,
            filter_ctx,
        );
        let detail_ctx = RenderContext {
            opts: RenderOpts {
                metrics: MetricsStyle::Visible,
                ..opts
            },
            ..ctx
        };
        draw_detail(
            frame,
            right,
            app.focus_stack.last_mut(),
            &detail_ctx,
            detail_active,
            app.reply_sort,
            &app.notif_seen,
        );
    } else {
        draw_source_list(
            frame,
            main,
            &mut app.source,
            &ctx,
            app.error.as_deref(),
            true,
            filter_ctx,
        );
    }

    draw_footer(frame, bottom, app);

    crate::tui::clock::render(frame, main, &app.app_config.clock);

    if app.mode == InputMode::Help {
        draw_help_overlay(frame, frame.area(), app.help_scroll);
    }
    if app.mode == InputMode::Changelog {
        draw_changelog_overlay(frame, frame.area(), app);
    }
    if app.mode == InputMode::Leader {
        draw_leader_overlay(frame, frame.area(), app);
    }
}

#[derive(Debug, Clone, Copy)]
pub struct FilterRenderCtx {
    pub mode: FilterMode,
    pub pending: usize,
    pub enabled: bool,
}

pub(super) fn format_countdown(remaining: std::time::Duration) -> String {
    let secs = remaining.as_secs();
    if secs < 60 {
        format!("{secs}s")
    } else {
        format!("{}:{:02}", secs / 60, secs % 60)
    }
}

fn draw_header(frame: &mut Frame, area: Rect, app: &App) {
    let t = th();
    let mut spans = vec![
        Span::styled(
            " unrager ",
            Style::default()
                .bg(t.brand_bg)
                .fg(t.brand_fg)
                .add_modifier(Modifier::BOLD),
        ),
        Span::raw(" "),
        Span::styled(app.source.title(), Style::default().fg(t.text)),
    ];
    if app.source.loading {
        let frame = SPINNER_FRAMES[app.spinner_frame % SPINNER_FRAMES.len()];
        spans.push(Span::raw("  "));
        spans.push(Span::styled(
            format!("{frame} loading"),
            Style::default().fg(t.warning),
        ));
    }
    if app.source.exhausted && !app.source.is_empty() {
        spans.push(Span::raw("  "));
        spans.push(Span::styled(
            "[end of timeline]",
            Style::default().fg(t.text_muted),
        ));
    }
    let unread = {
        let ids: Vec<String> = app
            .source
            .tweets
            .iter()
            .map(|t| t.rest_id.clone())
            .collect();
        app.seen.count_unseen(&ids)
    };
    if unread > 0 {
        spans.push(Span::raw("  "));
        spans.push(Span::styled(
            format!("{unread}↑"),
            Style::default().fg(t.success),
        ));
    }
    if app.focus_stack.len() > 1 {
        spans.push(Span::raw("  "));
        spans.push(Span::styled(
            format!("{}◆", app.focus_stack.len()),
            Style::default().fg(t.new_unread),
        ));
    }
    let read_rl = app.client.read_rate_limit_remaining();
    let write_rl = app.client.write_rate_limit_remaining();
    if read_rl.is_some() || write_rl.is_some() {
        spans.push(Span::raw("  "));
        let text = match (read_rl, write_rl) {
            (Some(r), Some(w)) => format!(
                "⊘ X cooldown · reads {} · writes {}",
                format_countdown(r),
                format_countdown(w),
            ),
            (Some(r), None) => format!("⊘ X cooldown · reads {}", format_countdown(r)),
            (None, Some(w)) => format!("⊘ X cooldown · writes {}", format_countdown(w)),
            (None, None) => String::new(),
        };
        spans.push(Span::styled(
            text,
            Style::default().fg(t.error).add_modifier(Modifier::BOLD),
        ));
    }
    if app.filter_classifier.is_some()
        && app.filter_mode == FilterMode::On
        && app.filter_hidden_count > 0
    {
        spans.push(Span::raw("  "));
        spans.push(Span::styled(
            format!("−{}", app.filter_hidden_count),
            Style::default().fg(t.success),
        ));
    } else if app.filter_classifier.is_none() {
        spans.push(Span::raw("  "));
        spans.push(Span::styled("filter⌀", Style::default().fg(t.text_muted)));
    }
    if matches!(app.feed_mode, crate::tui::app::FeedMode::Originals)
        && matches!(app.source.kind, Some(SourceKind::Home { .. }))
    {
        spans.push(Span::raw("  "));
        spans.push(Span::styled("◇", Style::default().fg(t.accent)));
    }
    if !app.top_is_notifications() && app.notif_unread_badge > 0 {
        spans.push(Span::raw("  "));
        spans.push(Span::styled(
            format!("{}n", app.notif_unread_badge),
            Style::default()
                .fg(t.new_unread)
                .add_modifier(Modifier::BOLD),
        ));
    }
    if !app.whisper.text.is_empty() {
        spans.push(Span::raw("  "));
        let whisper_color = match app.whisper.phase {
            crate::tui::whisper::WhisperPhase::Quiet => t.whisper_quiet,
            crate::tui::whisper::WhisperPhase::Active => t.whisper_active,
            crate::tui::whisper::WhisperPhase::Surge => t.whisper_surge,
            crate::tui::whisper::WhisperPhase::Cooling => t.whisper_cooling,
        };
        spans.push(Span::styled(
            app.whisper.text.clone(),
            Style::default()
                .fg(whisper_color)
                .add_modifier(Modifier::ITALIC),
        ));
    }
    if let Some(version) = &app.update_available {
        spans.push(Span::raw("  "));
        spans.push(Span::styled(
            format!("↑{version}"),
            Style::default().fg(t.update),
        ));
    }
    let clock_cfg = &app.app_config.clock;
    let clock_w = if matches!(clock_cfg.position, crate::config::ClockPosition::Header) {
        crate::tui::clock::inline_width(clock_cfg).saturating_add(2)
    } else {
        0
    };
    let (left, right) = split_right(area, clock_w);
    frame.render_widget(Paragraph::new(Line::from(spans)), left);
    if clock_w > 0 {
        crate::tui::clock::render_inline(frame, right, clock_cfg);
    }
}

fn split_right(area: Rect, right_w: u16) -> (Rect, Rect) {
    let right_w = right_w.min(area.width);
    let left_w = area.width.saturating_sub(right_w);
    let left = Rect {
        x: area.x,
        y: area.y,
        width: left_w,
        height: area.height,
    };
    let right = Rect {
        x: area.x + left_w,
        y: area.y,
        width: right_w,
        height: area.height,
    };
    (left, right)
}

fn block_with_focus(title: &str, active: bool) -> Block<'_> {
    let t = th();
    let border_style = if active {
        Style::default().fg(t.border_active)
    } else {
        Style::default().fg(t.border)
    };
    Block::default()
        .borders(Borders::ALL)
        .border_style(border_style)
        .title(format!(" {title} "))
}

fn draw_source_list(
    frame: &mut Frame,
    area: Rect,
    source: &mut Source,
    ctx: &RenderContext,
    error: Option<&str>,
    active: bool,
    filter_ctx: FilterRenderCtx,
) {
    let base_title = source.title();
    let title = if matches!(filter_ctx.mode, FilterMode::On)
        && filter_ctx.enabled
        && filter_ctx.pending > 0
    {
        format!("{base_title}  ·  filtering {}", filter_ctx.pending)
    } else {
        base_title
    };

    if source.is_empty() {
        let msg = if source.loading {
            "loading timeline…"
        } else {
            error.unwrap_or("no tweets")
        };
        let body = Paragraph::new(msg).block(block_with_focus(&title, active));
        frame.render_widget(body, area);
        return;
    }

    let wrap_width = (area.width as usize).saturating_sub(4);
    let selected = source.selected();

    let items: Vec<PaneItem> = source
        .tweets
        .iter()
        .map(|t| {
            let is_seen = ctx.seen.is_seen(&t.rest_id);
            let is_expanded = ctx.expanded.contains(&t.rest_id);
            let lines = tweet_lines(t, ctx, is_seen, false, wrap_width, is_expanded);
            PaneItem::new(lines)
        })
        .collect();

    render_scrollable(
        frame,
        area,
        &title,
        items,
        &mut source.state,
        Some(selected),
        active,
    );
}

fn notification_lines(
    n: &RawNotification,
    seen: bool,
    wrap_width: usize,
    expanded: bool,
    actor_cursor: Option<usize>,
    liked: bool,
) -> Vec<Line<'static>> {
    let t = th();
    let mut lines = Vec::with_capacity(2);

    let dim = seen;
    let meta_color = if dim { t.text_faint } else { t.text_muted };

    let (icon, icon_color) = match n.notification_type.as_str() {
        "Like" => ("♥", t.like),
        "Retweet" => ("⟲", t.retweet),
        "Follow" => ("→", t.follow),
        "Reply" => ("↳", t.reply_notif),
        "Quote" => ("❝", t.quote),
        "Mention" => ("@", t.mention),
        "Milestone" => ("★", t.milestone),
        _ => ("·", meta_color),
    };

    let verb = match n.notification_type.as_str() {
        "Like" => "liked",
        "Retweet" => "retweeted",
        "Reply" => "replied",
        "Quote" => "quoted",
        "Mention" => "mentioned you",
        "Follow" => "followed you",
        _ => &n.notification_type.to_lowercase(),
    };

    let (bullet, bullet_style) = if dim {
        ("  ", Style::default())
    } else {
        ("● ", Style::default().fg(t.unread_dot))
    };

    let mut header: Vec<Span<'static>> = vec![
        Span::styled(bullet.to_string(), bullet_style),
        Span::styled(
            format!("{icon}  "),
            Style::default().fg(icon_color).add_modifier(Modifier::BOLD),
        ),
    ];

    if !n.actors.is_empty() {
        let first = &n.actors[0];
        let handle_style = Style::default()
            .fg(theme::handle_color(&first.handle))
            .add_modifier(Modifier::BOLD);
        header.push(Span::styled(format!("@{}", first.handle), handle_style));
        if first.verified {
            header.push(Span::styled(" ✓", Style::default().fg(t.verified)));
        }

        let others = n
            .others_count
            .unwrap_or((n.actors.len() as u64).saturating_sub(1));
        if others == 0 {
        } else if n.actors.len() >= 2 && others == 1 {
            header.push(Span::styled(", ", Style::default().fg(meta_color)));
            let second = &n.actors[1];
            let h2_style = Style::default()
                .fg(theme::handle_color(&second.handle))
                .add_modifier(Modifier::BOLD);
            header.push(Span::styled(format!("@{}", second.handle), h2_style));
            if second.verified {
                header.push(Span::styled(" ✓", Style::default().fg(t.verified)));
            }
        } else {
            header.push(Span::styled(
                format!(" +{others}"),
                Style::default().fg(meta_color),
            ));
        }

        let verb_color = if dim { t.text_faint } else { t.text_muted };
        header.push(Span::styled(
            format!(" {verb}"),
            Style::default().fg(verb_color),
        ));
    } else {
        let verb_color = if dim { t.text_faint } else { t.text_muted };
        header.push(Span::styled(
            verb.to_string(),
            Style::default().fg(verb_color),
        ));
    }

    if n.notification_type == "Follow" {
        if let Some(a) = n.actors.first() {
            if a.followers > 0 {
                header.push(Span::styled(
                    format!("  {}", short_count(a.followers)),
                    Style::default().fg(meta_color),
                ));
            }
        }
    }

    header.push(Span::styled(
        format!(" · {}", relative_time(n.timestamp)),
        Style::default().fg(meta_color),
    ));

    if liked {
        header.push(Span::raw("  "));
        header.push(Span::styled(
            GLYPH_LIKES.to_string(),
            engaged_style(t.liked),
        ));
    }

    lines.push(Line::from(header));

    if let Some(snippet) = &n.target_tweet_snippet {
        let snippet_style = if dim {
            Style::default().fg(t.text_dim)
        } else {
            Style::default().fg(t.text)
        };
        let indent = "    ";
        let inner_width = wrap_width.saturating_sub(indent.len() + 2);
        let wrapped = wrap_text(snippet, inner_width);
        let max_lines = if expanded { wrapped.len() } else { 2 };
        let truncated = wrapped.len() > max_lines;
        let display = &wrapped[..max_lines.min(wrapped.len())];
        for (i, line) in display.iter().enumerate() {
            let is_last = i == display.len() - 1;
            let text = if i == 0 && is_last && !truncated {
                format!("{indent}\"{line}\"")
            } else if i == 0 {
                format!("{indent}\"{line}")
            } else if is_last && !truncated {
                format!("{indent} {line}\"")
            } else if is_last && truncated {
                format!("{indent} {line}…\"")
            } else {
                format!("{indent} {line}")
            };
            lines.push(Line::from(Span::styled(text, snippet_style)));
        }
    }

    if expanded && n.notification_type == "Follow" && n.actors.len() > 1 {
        let detail_style = if dim {
            Style::default().fg(t.text_faint)
        } else {
            Style::default().fg(t.text_muted)
        };
        for (i, actor) in n.actors.iter().enumerate() {
            let is_cursor = actor_cursor == Some(i);
            let marker = if is_cursor {
                Span::styled(
                    "  ▶ → ",
                    Style::default().fg(t.accent).add_modifier(Modifier::BOLD),
                )
            } else {
                Span::styled("    → ", Style::default().fg(t.follow))
            };
            let mut row: Vec<Span<'static>> = vec![marker];
            let h_style = Style::default()
                .fg(theme::handle_color(&actor.handle))
                .add_modifier(Modifier::BOLD);
            row.push(Span::styled(format!("@{}", actor.handle), h_style));
            if actor.verified {
                row.push(Span::styled(" ✓", Style::default().fg(t.verified)));
            }
            if !actor.name.is_empty() {
                row.push(Span::styled(format!("  {}", actor.name), detail_style));
            }
            if actor.followers > 0 {
                row.push(Span::styled(
                    format!("  {}", short_count(actor.followers)),
                    Style::default().fg(meta_color),
                ));
            }
            lines.push(Line::from(row));
        }
    }

    lines
}

fn draw_detail(
    frame: &mut Frame,
    area: Rect,
    entry: Option<&mut FocusEntry>,
    ctx: &RenderContext,
    active: bool,
    reply_sort: ReplySortOrder,
    notif_seen: &SeenStore,
) {
    let Some(entry) = entry else {
        return;
    };
    match entry {
        FocusEntry::Tweet(detail) => {
            draw_tweet_detail(frame, area, detail, ctx, active, reply_sort)
        }
        FocusEntry::Likers(view) => {
            draw_likers_detail(frame, area, view, ctx.raw_display_names, active)
        }
        FocusEntry::Notifications(view) => {
            draw_notifications_detail(frame, area, view, ctx, notif_seen, active)
        }
        FocusEntry::Ask(view) => draw_ask(frame, area, view, ctx, active),
        FocusEntry::Brief(view) => draw_brief(frame, area, view, active),
    }
}

fn draw_notifications_detail(
    frame: &mut Frame,
    area: Rect,
    view: &mut crate::tui::focus::NotificationsView,
    ctx: &RenderContext,
    notif_seen: &SeenStore,
    active: bool,
) {
    let title = "notifications";
    if view.is_empty() {
        let msg = if view.loading {
            "loading notifications…"
        } else {
            view.error.as_deref().unwrap_or("no notifications")
        };
        let body = Paragraph::new(msg).block(block_with_focus(title, active));
        frame.render_widget(body, area);
        return;
    }
    let wrap_width = (area.width as usize).saturating_sub(4);
    let selected = view.selected();
    let items: Vec<PaneItem> = view
        .notifications
        .iter()
        .enumerate()
        .map(|(i, n)| {
            let seen = notif_seen.is_seen(&n.id);
            let is_expanded = ctx.expanded.contains(&n.id);
            let actor_cursor = if i == selected {
                view.actor_cursor
            } else {
                None
            };
            let liked = n
                .target_tweet_id
                .as_ref()
                .is_some_and(|tid| ctx.liked_tweet_ids.contains(tid));
            let lines = notification_lines(n, seen, wrap_width, is_expanded, actor_cursor, liked);
            PaneItem::new(lines)
        })
        .collect();
    render_scrollable(
        frame,
        area,
        title,
        items,
        &mut view.state,
        Some(selected),
        active,
    );
}

fn draw_brief(
    frame: &mut Frame,
    area: Rect,
    view: &mut crate::tui::brief::BriefView,
    active: bool,
) {
    let status = if view.loading_tweets {
        "jacking in"
    } else if view.streaming {
        "cognition pass"
    } else if view.error.is_some() {
        "aborted"
    } else if view.complete {
        "complete"
    } else {
        "standby"
    };
    let mut title = format!("profile · @{}", view.handle);
    if view.sample_count > 0 {
        title.push_str(&format!(" · {}t", view.sample_count));
    }
    if !view.span_label.is_empty() {
        title.push_str(&format!(" · {}", view.span_label));
    }
    title.push_str(" · ");
    title.push_str(status);

    let block = block_with_focus(&title, active);
    let inner = block.inner(area);
    frame.render_widget(block, area);

    let t = th();
    let mut lines: Vec<Line<'static>> = Vec::new();
    if view.loading_tweets {
        let dim = Style::default().fg(t.text_muted);
        lines.push(Line::from(Span::styled(
            format!("jacking into @{}'s timeline · newest-first", view.handle),
            dim,
        )));
        lines.push(Line::from(Span::styled(
            "window: up to 300 authored posts, 15 pages",
            dim,
        )));
        lines.push(Line::from(""));
        let progress = if view.fetch_pages == 0 && view.fetch_authored == 0 {
            "scraping page 1/15 · 0 logged".to_string()
        } else {
            format!(
                "scraping page {}/15 · {} logged",
                view.fetch_pages + 1,
                view.fetch_authored
            )
        };
        lines.push(Line::from(vec![
            Span::styled("▸ ", Style::default().fg(t.accent)),
            Span::styled(progress, Style::default().fg(t.text_muted)),
        ]));
    } else {
        let has_bold = view.text.contains("**");
        let cleaned = sanitize_brief_output(&view.text);
        if !has_bold && view.text.trim().is_empty() && view.streaming {
            let angle = current_brief_angle();
            let dim = Style::default().fg(t.text_muted);
            lines.push(Line::from(Span::styled(
                "cognition pass · reading the sample",
                dim.add_modifier(Modifier::ITALIC),
            )));
            lines.push(Line::from(""));
            lines.push(Line::from(vec![
                Span::styled("▸ ", Style::default().fg(t.accent)),
                Span::styled(angle, Style::default().fg(t.text_muted)),
            ]));
        } else if has_bold {
            lines.extend(render_markdown(cleaned));
        } else {
            lines.push(Line::from(Span::styled(
                "model returned no bold thesis · showing raw output below",
                Style::default()
                    .fg(t.warning)
                    .add_modifier(Modifier::ITALIC),
            )));
            lines.push(Line::from(""));
            lines.extend(render_markdown(view.text.trim()));
        }
    }
    if let Some(err) = &view.error {
        lines.push(Line::from(""));
        lines.push(Line::from(Span::styled(
            format!("aborted: {err}"),
            Style::default().fg(t.error),
        )));
    }
    if view.complete && view.error.is_none() {
        lines.push(Line::from(""));
        lines.push(Line::from(Span::styled(
            "R re-read · Esc close",
            Style::default().fg(t.text_muted),
        )));
    }

    let visual_rows = count_visual_rows(&lines, inner.width);
    let max_scroll = visual_rows.saturating_sub(inner.height);
    if view.scroll > max_scroll {
        view.scroll = max_scroll;
    }
    if max_scroll > 0 {
        let pct = (view.scroll as u32 * 100 / max_scroll as u32) as u16;
        let pos_label = if view.scroll == 0 {
            " · top".to_string()
        } else if view.scroll >= max_scroll {
            " · bot".to_string()
        } else {
            format!(" · {pct}%")
        };
        let title_ext = format!("{title}{pos_label}");
        let block2 = block_with_focus(&title_ext, active);
        frame.render_widget(block2, area);
    }
    let para = Paragraph::new(lines)
        .wrap(Wrap { trim: false })
        .scroll((view.scroll, 0));
    frame.render_widget(para, inner);
}

fn sanitize_brief_output(text: &str) -> &str {
    if let Some(idx) = text.find("**") {
        return &text[idx..];
    }
    ""
}

const BRIEF_ANGLES: &[&str] = &[
    "pattern-matching preoccupations",
    "tracing rhetorical tics",
    "naming observed postures",
    "reading stance and worldview",
    "mapping canonical enemies and heroes",
    "sampling emotional register",
    "indexing posting cadence and rhythm",
    "probing how the mind moves across topics",
    "inferring dominant arguing style",
    "watching attention pattern (what pulls focus, what is ignored)",
    "observing learning behavior under challenge",
    "sensing default affective register",
    "reading social-cognition tells (warmth vs suspicion)",
    "reading status-game posture",
    "locating moral foundations from what is defended and attacked",
    "inferring epistemic posture",
    "flagging contradictions and tensions",
    "noting conspicuous absences in the repertoire",
    "finding the most characteristic post",
];

fn current_brief_angle() -> &'static str {
    let idx = (std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() / 1200)
        .unwrap_or(0) as usize)
        % BRIEF_ANGLES.len();
    BRIEF_ANGLES[idx]
}

fn count_visual_rows(lines: &[Line<'static>], width: u16) -> u16 {
    use unicode_width::UnicodeWidthStr;
    let w = width.max(1) as usize;
    let mut total: u32 = 0;
    for line in lines {
        let line_w: usize = line
            .spans
            .iter()
            .map(|s| UnicodeWidthStr::width(s.content.as_ref()))
            .sum();
        if line_w == 0 {
            total += 1;
        } else {
            total += line_w.div_ceil(w) as u32;
        }
    }
    total.min(u16::MAX as u32) as u16
}

fn draw_likers_detail(
    frame: &mut Frame,
    area: Rect,
    view: &mut crate::tui::focus::LikersView,
    display_names: DisplayNameStyle,
    active: bool,
) {
    let title = if view.loading && view.users.is_empty() {
        format!("{} · loading…", view.title)
    } else {
        format!("{} · {}", view.title, view.users.len())
    };

    if view.users.is_empty() {
        let msg = if view.loading {
            "loading likers…"
        } else if let Some(err) = &view.error {
            err.as_str()
        } else {
            "no likers"
        };
        let body = Paragraph::new(msg).block(block_with_focus(&title, active));
        frame.render_widget(body, area);
        return;
    }

    let selected = view.selected();
    let items: Vec<PaneItem> = view
        .users
        .iter()
        .map(|user| {
            let t = th();
            let mut row: Vec<Span<'static>> = vec![
                Span::raw("  "),
                Span::styled(
                    user.handle.clone(),
                    Style::default()
                        .fg(theme::handle_color(&user.handle))
                        .add_modifier(Modifier::BOLD),
                ),
            ];
            if user.verified {
                row.push(Span::styled(" ✓", Style::default().fg(t.verified)));
            }
            if matches!(display_names, DisplayNameStyle::Visible) && !user.name.is_empty() {
                row.push(Span::styled(
                    format!("  {}", user.name),
                    Style::default().fg(t.text_muted),
                ));
            }
            if user.followers > 0 {
                row.push(Span::styled(
                    format!("  {} followers", short_count(user.followers)),
                    Style::default().fg(t.text_muted),
                ));
            }
            PaneItem::new(vec![Line::from(row)])
        })
        .collect();

    render_scrollable(
        frame,
        area,
        &title,
        items,
        &mut view.state,
        Some(selected),
        active,
    );
}

fn draw_ask(
    frame: &mut Frame,
    area: Rect,
    view: &mut crate::tui::ask::AskView,
    ctx: &RenderContext,
    active: bool,
) {
    use crate::tui::app::SPINNER_FRAMES;

    let status_suffix = if view.streaming {
        "streaming…"
    } else if view.error.is_some() {
        "error"
    } else {
        "ready"
    };
    let mut title = format!("ask · @{}", view.tweet.author.handle);
    let imgs = view.image_count();
    if imgs > 0 {
        title.push_str(&format!(" · {imgs} img"));
        if imgs > 1 {
            title.push('s');
        }
    }
    if view.thread_loading {
        title.push_str(" · loading thread…");
    } else {
        let ancestors = view.ancestor_count();
        if ancestors > 0 {
            title.push_str(&format!(" · thread of {}", ancestors + 1));
        }
    }
    if view.replies_loading {
        title.push_str(" · loading replies…");
    } else {
        let replies = view.reply_count();
        if replies > 0 {
            title.push_str(&format!(" · {replies} replies"));
        }
    }
    title.push_str(" · ");
    title.push_str(status_suffix);

    let block = block_with_focus(&title, active);
    let inner = block.inner(area);
    frame.render_widget(block, area);

    if inner.height < 5 {
        return;
    }

    let chip_rows = ask_chip_rows(view, inner.width);
    let input_h: u16 = 3 + chip_rows;
    let tweet_preview_h = inner.height.min(5);
    let conv_h = inner
        .height
        .saturating_sub(tweet_preview_h.saturating_add(input_h));

    let [tweet_area, conv_area, input_area] = Layout::vertical([
        Constraint::Length(tweet_preview_h),
        Constraint::Length(conv_h),
        Constraint::Length(input_h),
    ])
    .areas(inner);

    draw_ask_tweet_header(frame, tweet_area, &view.tweet, ctx);
    draw_ask_conversation(
        frame,
        conv_area,
        &view.messages,
        view.error.as_deref(),
        view.streaming,
        &mut view.state,
        view.auto_follow,
    );
    draw_ask_input(frame, input_area, view, active, SPINNER_FRAMES, chip_rows);
}

fn ask_chip_rows(view: &crate::tui::ask::AskView, width: u16) -> u16 {
    use unicode_width::UnicodeWidthStr;
    let total: usize = view
        .available_presets()
        .iter()
        .map(|(idx, p)| {
            let s = format!("[{idx}] {}", p.label);
            UnicodeWidthStr::width(s.as_str())
        })
        .sum::<usize>()
        + view.available_presets().len().saturating_sub(1) * 2;
    if total <= width as usize { 1 } else { 2 }
}

fn draw_ask_tweet_header(frame: &mut Frame, area: Rect, tweet: &Tweet, ctx: &RenderContext) {
    let t = th();
    let wrap_width = (area.width as usize).saturating_sub(2);
    let handle_line = Line::from(vec![
        Span::styled(
            format!("@{}", tweet.author.handle),
            Style::default()
                .fg(theme::handle_color(&tweet.author.handle))
                .add_modifier(Modifier::BOLD),
        ),
        Span::raw("  "),
        Span::styled(
            format_timestamp(tweet.created_at, ctx.opts.timestamps),
            Style::default().fg(t.text_muted),
        ),
    ]);
    let mut body_lines: Vec<Line<'static>> = vec![handle_line];
    let text = tweet.text.as_str();
    let max_body_lines = area.height.saturating_sub(2) as usize;
    let mut count = 0;
    for raw_line in text.lines() {
        for wrapped in wrap_text(raw_line, wrap_width) {
            if count >= max_body_lines {
                break;
            }
            body_lines.push(Line::from(Span::raw(wrapped)));
            count += 1;
        }
        if count >= max_body_lines {
            break;
        }
    }
    let separator = "─".repeat(wrap_width);
    body_lines.push(Line::from(Span::styled(
        separator,
        Style::default().fg(t.text_muted),
    )));

    let para = Paragraph::new(body_lines).wrap(Wrap { trim: false });
    frame.render_widget(para, area);
}

fn draw_ask_conversation(
    frame: &mut Frame,
    area: Rect,
    messages: &[crate::tui::ask::AskMessage],
    error: Option<&str>,
    streaming: bool,
    state: &mut PaneState,
    auto_follow: bool,
) {
    use crate::tui::ask::AskMessage;

    let t = th();
    let mut lines: Vec<Line<'static>> = Vec::new();
    if messages.is_empty() {
        lines.push(Line::from(Span::styled(
            "Ask anything about this post (answered by local gemma).",
            Style::default().fg(t.text_muted),
        )));
        lines.push(Line::from(Span::styled(
            "Press Enter to send; empty prompt uses 'Explain this post'.",
            Style::default().fg(t.text_muted),
        )));
    }
    for (idx, msg) in messages.iter().enumerate() {
        if idx > 0 {
            lines.push(Line::from(""));
        }
        match msg {
            AskMessage::User(text) => {
                lines.push(Line::from(Span::styled(
                    "you",
                    Style::default().fg(t.ask_user).add_modifier(Modifier::BOLD),
                )));
                for raw_line in text.lines() {
                    lines.push(Line::from(Span::raw(raw_line.to_string())));
                }
            }
            AskMessage::Assistant(m) => {
                let header_style = Style::default()
                    .fg(t.ask_assistant)
                    .add_modifier(Modifier::BOLD);
                let mut header_spans = vec![Span::styled("gemma", header_style)];
                if !m.complete && streaming && idx + 1 == messages.len() {
                    header_spans.push(Span::styled(" …", Style::default().fg(t.text_muted)));
                }
                lines.push(Line::from(header_spans));
                if m.text.is_empty() && !m.complete {
                    lines.push(Line::from(Span::styled(
                        "thinking…",
                        Style::default()
                            .fg(t.text_muted)
                            .add_modifier(Modifier::ITALIC),
                    )));
                }
                lines.extend(render_markdown(&m.text));
            }
        }
    }
    if let Some(err) = error {
        lines.push(Line::from(""));
        lines.push(Line::from(Span::styled(
            format!("error: {err}"),
            Style::default().fg(t.error),
        )));
    }

    let wrap_width = area.width as usize;
    let visual_lines: u16 = if wrap_width > 0 {
        lines
            .iter()
            .map(|line| {
                let w: usize = line
                    .spans
                    .iter()
                    .map(|s| unicode_width::UnicodeWidthStr::width(s.content.as_ref()))
                    .sum();
                w.max(1).div_ceil(wrap_width) as u16
            })
            .sum()
    } else {
        lines.len() as u16
    };
    let max_scroll = visual_lines.saturating_sub(area.height);
    if auto_follow || state.scroll > max_scroll {
        state.scroll = max_scroll;
    }

    let para = Paragraph::new(lines)
        .wrap(Wrap { trim: false })
        .scroll((state.scroll, 0));
    frame.render_widget(para, area);
}

fn draw_ask_input(
    frame: &mut Frame,
    area: Rect,
    view: &crate::tui::ask::AskView,
    active: bool,
    spinner: &[&str],
    chip_rows: u16,
) {
    let t = th();
    let streaming = view.streaming;
    let input = view.editor.input.as_str();

    let separator = "─".repeat(area.width as usize);
    let sep_line = Line::from(Span::styled(separator, Style::default().fg(t.text_muted)));

    let prompt_style = if active {
        Style::default().fg(t.accent).add_modifier(Modifier::BOLD)
    } else {
        Style::default().fg(t.text_muted)
    };
    let mut input_spans: Vec<Span<'static>> = vec![Span::styled("> ", prompt_style)];
    if streaming {
        let idx = (std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() / 120)
            .unwrap_or(0) as usize)
            % spinner.len().max(1);
        let frame_str = spinner.get(idx).copied().unwrap_or("·").to_string();
        input_spans.push(Span::styled(
            format!("{frame_str} thinking…"),
            Style::default().fg(t.text_muted),
        ));
    } else if input.is_empty() {
        input_spans.push(Span::styled(
            "type or [1–5] preset",
            Style::default().fg(t.text_muted),
        ));
    } else {
        input_spans.push(Span::raw(input.to_string()));
        if active {
            input_spans.push(Span::styled(
                "▏",
                Style::default().fg(t.accent).add_modifier(Modifier::BOLD),
            ));
        }
    }
    let input_line = Line::from(input_spans);

    let chips_active = active && !streaming && input.is_empty();
    let mut chip_spans: Vec<Span<'static>> = Vec::new();
    for (idx, preset) in view.available_presets() {
        if !chip_spans.is_empty() {
            chip_spans.push(Span::styled("  ", Style::default().fg(t.text_muted)));
        }
        let enabled = view.preset_enabled(preset) && chips_active;
        let (num_style, label_style) = if enabled {
            (
                Style::default().fg(t.accent).add_modifier(Modifier::BOLD),
                Style::default().fg(t.text),
            )
        } else {
            let dim = Style::default().fg(t.text_muted);
            (dim, dim)
        };
        chip_spans.push(Span::styled(format!("[{idx}] "), num_style));
        chip_spans.push(Span::styled(preset.label.to_string(), label_style));
    }
    let chip_line = Line::from(chip_spans);

    let mode_tag = match view.editor.mode {
        crate::tui::editor::VimMode::Insert => "INSERT",
        crate::tui::editor::VimMode::Normal => "NORMAL",
    };
    let mode_style = match view.editor.mode {
        crate::tui::editor::VimMode::Insert => Style::default().fg(t.mode_vim_insert),
        crate::tui::editor::VimMode::Normal => Style::default().fg(t.mode_vim_normal),
    };
    let mode_line = Line::from(Span::styled(format!("-- {mode_tag} --"), mode_style));

    let mut lines = vec![sep_line, mode_line, input_line, chip_line];
    if chip_rows == 2 {
        lines.push(Line::from(""));
    }
    let para = Paragraph::new(lines).wrap(Wrap { trim: false });
    frame.render_widget(para, area);
}

fn reply_wrap_input(
    prompt: &str,
    text: &str,
    cursor_byte_pos: usize,
    width: usize,
) -> (Vec<String>, usize, usize) {
    use unicode_width::UnicodeWidthChar;

    let target_byte = prompt.len() + cursor_byte_pos;
    let full = format!("{prompt}{text}");

    let mut result_lines: Vec<String> = Vec::new();
    let mut current = String::new();
    let mut col = 0usize;
    let mut cursor_col = 0usize;
    let mut cursor_row = 0usize;
    let mut byte_offset = 0usize;
    let mut found_cursor = false;

    for ch in full.chars() {
        let w = UnicodeWidthChar::width(ch).unwrap_or(1);

        if width > 0 && col + w > width {
            result_lines.push(std::mem::take(&mut current));
            col = 0;
        }

        if byte_offset == target_byte && !found_cursor {
            cursor_col = col;
            cursor_row = result_lines.len();
            found_cursor = true;
        }

        current.push(ch);
        col += w;
        byte_offset += ch.len_utf8();
    }

    if !found_cursor {
        if width > 0 && col >= width {
            cursor_col = 0;
            cursor_row = result_lines.len() + 1;
        } else {
            cursor_col = col;
            cursor_row = result_lines.len();
        }
    }

    if !current.is_empty() || result_lines.is_empty() {
        result_lines.push(current);
    }

    (result_lines, cursor_col, cursor_row)
}

fn render_markdown(text: &str) -> Vec<Line<'static>> {
    let t = th();
    let mut out: Vec<Line<'static>> = Vec::new();
    let mut in_code_fence = false;
    for raw in text.split('\n') {
        let line = raw.trim_end_matches('\r');
        if line.trim_start().starts_with("```") {
            in_code_fence = !in_code_fence;
            continue;
        }
        if in_code_fence {
            out.push(Line::from(vec![
                Span::styled("  ", Style::default()),
                Span::styled(line.to_string(), Style::default().fg(t.code)),
            ]));
            continue;
        }
        if let Some((level, rest)) = strip_heading(line) {
            let spans = parse_md_inline(&rest, Modifier::BOLD);
            let mut prefixed = vec![Span::styled(
                "#".repeat(level as usize) + " ",
                Style::default()
                    .fg(t.text_muted)
                    .add_modifier(Modifier::BOLD),
            )];
            prefixed.extend(spans);
            out.push(Line::from(prefixed));
            continue;
        }
        if let Some(quote) = strip_blockquote(line) {
            let gutter = Span::styled(
                "│ ",
                Style::default()
                    .fg(t.quote_block)
                    .add_modifier(Modifier::BOLD),
            );
            let mut spans: Vec<Span<'static>> = vec![gutter];
            spans.extend(parse_md_inline(&quote, Modifier::ITALIC));
            out.push(Line::from(spans));
            continue;
        }
        if let Some((indent, rest)) = strip_bullet(line) {
            let mut spans: Vec<Span<'static>> = Vec::with_capacity(3);
            if indent > 0 {
                spans.push(Span::raw(" ".repeat(indent)));
            }
            spans.push(Span::styled("• ", Style::default().fg(t.text_muted)));
            spans.extend(parse_md_inline(&rest, Modifier::empty()));
            out.push(Line::from(spans));
            continue;
        }
        if line.is_empty() {
            out.push(Line::from(""));
            continue;
        }
        let spans = parse_md_inline(line, Modifier::empty());
        out.push(Line::from(spans));
    }
    out
}

fn strip_heading(line: &str) -> Option<(u8, String)> {
    let trimmed = line.trim_start();
    let hashes = trimmed.chars().take_while(|c| *c == '#').count();
    if hashes == 0 || hashes > 6 {
        return None;
    }
    let after = &trimmed[hashes..];
    let rest = after.strip_prefix(' ')?;
    Some((hashes as u8, rest.to_string()))
}

fn strip_blockquote(line: &str) -> Option<String> {
    let trimmed = line.trim_start();
    if let Some(rest) = trimmed.strip_prefix("> ") {
        return Some(rest.to_string());
    }
    if trimmed == ">" {
        return Some(String::new());
    }
    None
}

fn strip_bullet(line: &str) -> Option<(usize, String)> {
    let leading = line.chars().take_while(|c| *c == ' ').count();
    let rest = &line[leading..];
    if let Some(after) = rest.strip_prefix("- ") {
        return Some((leading, after.to_string()));
    }
    if let Some(after) = rest.strip_prefix("* ")
        && !after.starts_with('*')
    {
        return Some((leading, after.to_string()));
    }
    None
}

fn parse_md_inline(text: &str, base_modifier: Modifier) -> Vec<Span<'static>> {
    let chars: Vec<char> = text.chars().collect();
    let mut spans: Vec<Span<'static>> = Vec::new();
    let mut buf = String::new();
    let mut bold = false;
    let mut italic = false;
    let mut code = false;
    let mut i = 0;

    while i < chars.len() {
        let ch = chars[i];

        if ch == '`' {
            flush_md_span(&mut buf, &mut spans, base_modifier, bold, italic, code);
            code = !code;
            i += 1;
            continue;
        }
        if code {
            buf.push(ch);
            i += 1;
            continue;
        }
        if ch == '*' && i + 1 < chars.len() && chars[i + 1] == '*' {
            let ok_toggle = if !bold {
                i + 2 < chars.len() && !chars[i + 2].is_whitespace()
            } else {
                !buf.is_empty() && !buf.ends_with(char::is_whitespace)
            };
            if ok_toggle {
                flush_md_span(&mut buf, &mut spans, base_modifier, bold, italic, code);
                bold = !bold;
                i += 2;
                continue;
            }
        }
        if ch == '*' {
            let prev_is_space = if buf.is_empty() {
                spans.last().and_then(|s| s.content.chars().last())
            } else {
                buf.chars().last()
            }
            .map(|c| c.is_whitespace())
            .unwrap_or(true);
            let next_ch = chars.get(i + 1).copied();
            let ok_toggle = if !italic {
                next_ch.is_some_and(|c| !c.is_whitespace() && c != '*')
            } else {
                !buf.is_empty() && !buf.ends_with(char::is_whitespace)
            };
            if ok_toggle && (italic || prev_is_space || spans.is_empty() && buf.is_empty()) {
                flush_md_span(&mut buf, &mut spans, base_modifier, bold, italic, code);
                italic = !italic;
                i += 1;
                continue;
            }
        }
        buf.push(ch);
        i += 1;
    }

    flush_md_span(&mut buf, &mut spans, base_modifier, bold, italic, code);
    spans
}

fn flush_md_span(
    buf: &mut String,
    spans: &mut Vec<Span<'static>>,
    base_modifier: Modifier,
    bold: bool,
    italic: bool,
    code: bool,
) {
    if buf.is_empty() {
        return;
    }
    let mut style = Style::default();
    let mut modifier = base_modifier;
    if bold {
        modifier = modifier.union(Modifier::BOLD);
    }
    if italic {
        modifier = modifier.union(Modifier::ITALIC);
    }
    if !modifier.is_empty() {
        style = style.add_modifier(modifier);
    }
    if code {
        style = style.fg(th().code);
    }
    spans.push(Span::styled(std::mem::take(buf), style));
}

fn draw_tweet_detail(
    frame: &mut Frame,
    area: Rect,
    detail: &mut crate::tui::focus::TweetDetail,
    ctx: &RenderContext,
    active: bool,
    reply_sort: ReplySortOrder,
) {
    let bar_height: u16 = if detail.reply_bar.is_some() { 4 } else { 0 };
    let (thread_area, bar_area) = if bar_height > 0 && area.height > bar_height + 4 {
        let [top, bot] =
            Layout::vertical([Constraint::Min(0), Constraint::Length(bar_height)]).areas(area);
        (top, Some(bot))
    } else {
        (area, None)
    };

    let reply_suffix = if detail.loading {
        " [loading replies…]".to_string()
    } else if detail.replies.is_empty() && detail.error.is_none() {
        " · no replies".to_string()
    } else if detail.replies.is_empty() {
        String::new()
    } else {
        let new_count = detail.new_reply_ids.len();
        let sort_label = if matches!(reply_sort, ReplySortOrder::Newest) {
            String::new()
        } else {
            format!(" by {}", reply_sort.label())
        };
        let new_label = if new_count > 0 {
            format!(" · {new_count} new")
        } else {
            String::new()
        };
        format!(
            " · {} replies{}{}",
            detail.replies.len(),
            sort_label,
            new_label
        )
    };
    let title = format!("tweet @{}{}", detail.tweet.author.handle, reply_suffix);

    let wrap_width = (thread_area.width as usize).saturating_sub(4);

    let selected = detail.selected();
    let focal_lines = tweet_lines(&detail.tweet, ctx, false, false, wrap_width, true);
    let mut items: Vec<PaneItem> = Vec::with_capacity(1 + detail.replies.len());
    items.push(PaneItem::new(focal_lines));

    for tw in &detail.replies {
        let is_seen = ctx.seen.is_seen(&tw.rest_id);
        let is_expanded = ctx.expanded.contains(&tw.rest_id);
        let is_new = detail.new_reply_ids.contains(&tw.rest_id);
        let mut lines = tweet_lines(tw, ctx, is_seen, true, wrap_width, is_expanded);
        if is_new {
            if let Some(first) = lines.first_mut() {
                first
                    .spans
                    .insert(0, Span::styled("● ", Style::default().fg(th().success)));
            }
        }
        if let Some(thread) = ctx.inline_threads.get(&tw.rest_id) {
            append_inline_thread(&mut lines, thread, ctx, wrap_width);
        }
        items.push(PaneItem::new(lines));
    }

    if detail.replies.is_empty() && detail.loading {
        items.push(PaneItem::new(vec![Line::from(Span::styled(
            "  loading replies…",
            Style::default().fg(th().warning),
        ))]));
    }
    if let Some(err) = &detail.error {
        items.push(PaneItem::new(vec![Line::from(Span::styled(
            format!("  error: {err}"),
            Style::default().fg(th().error),
        ))]));
    }

    render_scrollable(
        frame,
        thread_area,
        &title,
        items,
        &mut detail.state,
        Some(selected),
        active,
    );

    if let Some(bar_area) = bar_area {
        if let Some(bar) = &detail.reply_bar {
            draw_reply_bar(frame, bar_area, bar, active, ctx.write_rate_limit);
        }
    }
}

fn draw_reply_bar(
    frame: &mut Frame,
    area: Rect,
    bar: &crate::tui::compose::ReplyBar,
    active: bool,
    write_rate_limit: Option<std::time::Duration>,
) {
    let t = th();
    let wrap_width = area.width as usize;

    let separator = "─".repeat(wrap_width);
    let sep_line = Line::from(Span::styled(separator, Style::default().fg(t.text_muted)));

    let prompt_style = if active {
        Style::default().fg(t.accent).add_modifier(Modifier::BOLD)
    } else {
        Style::default().fg(t.text_muted)
    };

    let mut lines: Vec<Line<'static>> = vec![sep_line];

    let (cursor_col, cursor_row) = if bar.sending || bar.editor.input.is_empty() {
        let mut spans: Vec<Span<'static>> = vec![Span::styled("> ", prompt_style)];
        if bar.sending {
            spans.push(Span::styled("sending…", Style::default().fg(t.text_muted)));
        } else {
            spans.push(Span::styled(
                "type your reply…",
                Style::default().fg(t.text_muted),
            ));
        }
        lines.push(Line::from(spans));
        (2usize, 0usize)
    } else {
        let (wrapped, c_col, c_row) =
            reply_wrap_input("> ", &bar.editor.input, bar.editor.cursor_pos, wrap_width);
        for (i, visual_line) in wrapped.into_iter().enumerate() {
            if i == 0 && visual_line.len() >= 2 {
                let rest = visual_line[2..].to_string();
                lines.push(Line::from(vec![
                    Span::styled("> ", prompt_style),
                    Span::raw(rest),
                ]));
            } else {
                lines.push(Line::from(Span::raw(visual_line)));
            }
        }
        (c_col, c_row)
    };

    let char_count = bar.editor.char_count();
    let count_style = if char_count > 280 {
        Style::default().fg(t.error)
    } else {
        Style::default().fg(t.text_muted)
    };
    let mode_tag = match bar.editor.mode {
        crate::tui::editor::VimMode::Insert => "INSERT",
        crate::tui::editor::VimMode::Normal => "NORMAL",
    };
    let mode_style = match bar.editor.mode {
        crate::tui::editor::VimMode::Insert => Style::default().fg(t.mode_vim_insert),
        crate::tui::editor::VimMode::Normal => Style::default().fg(t.mode_vim_normal),
    };
    let hint_span = if let Some(remaining) = write_rate_limit {
        Span::styled(
            format!("  ⊘ X cooldown · wait {}", format_countdown(remaining)),
            Style::default().fg(t.error).add_modifier(Modifier::BOLD),
        )
    } else {
        Span::styled(
            "  Enter send · Esc close",
            Style::default().fg(t.text_muted),
        )
    };
    lines.push(Line::from(vec![
        Span::styled(format!("-- {mode_tag} -- "), mode_style),
        Span::styled(format!("{char_count}/280"), count_style),
        hint_span,
    ]));

    if let Some(ref err) = bar.error {
        lines.push(Line::from(Span::styled(
            err.clone(),
            Style::default().fg(t.error),
        )));
    }

    let para = Paragraph::new(lines);
    frame.render_widget(para, area);

    if active && !bar.sending {
        let cursor_x = area.x + cursor_col as u16;
        let cursor_y = area.y + 1 + cursor_row as u16;
        if cursor_x < area.right() && cursor_y < area.bottom() {
            frame.set_cursor_position((cursor_x, cursor_y));
        }
    }
}

fn author_spans(handle: &str, verified: bool, name: &str, show_name: bool) -> Vec<Span<'static>> {
    let t = th();
    let color = theme::handle_color(handle);
    let mut spans = vec![Span::styled(
        format!("@{handle}"),
        Style::default().fg(color).add_modifier(Modifier::BOLD),
    )];
    if verified {
        spans.push(Span::styled(" ✓", Style::default().fg(t.verified)));
    }
    if show_name && !name.is_empty() {
        spans.push(Span::raw("  "));
        spans.push(Span::styled(
            name.to_string(),
            Style::default().fg(t.text_muted),
        ));
    }
    spans
}

const TEXT_LINES_IN_CARD: usize = 3;

pub fn zebra_bg() -> Color {
    th().zebra_bg
}
const GLYPH_REPLIES: &str = "↳";
const GLYPH_RETWEETS: &str = "⟲";
const GLYPH_LIKES: &str = "♥";
const GLYPH_VIEWS: &str = "◉";
const GLYPH_IS_REPLY: &str = "⮎";
const GLYPH_PHOTO: &str = "▣";
const GLYPH_VIDEO: &str = "▶";
const GLYPH_GIF: &str = "↻";
const GLYPH_YOUTUBE: &str = "▶";
const GLYPH_ARTICLE: &str = "❏";
const GLYPH_LINK: &str = "🔗";
const GLYPH_POLL: &str = "▥";

fn tweet_lines(
    t: &Tweet,
    ctx: &RenderContext,
    seen: bool,
    in_reply_context: bool,
    wrap_width: usize,
    expanded: bool,
) -> Vec<Line<'static>> {
    let opts = ctx.opts;
    let translated_text = ctx.translations.get(&t.rest_id);
    let photo_count = t
        .media
        .iter()
        .filter(|m| {
            matches!(
                m.kind,
                crate::model::MediaKind::Photo
                    | crate::model::MediaKind::Video
                    | crate::model::MediaKind::AnimatedGif
            )
        })
        .count();
    let has_photo_media = photo_count > 0;
    let first_media_kind = t.media.first().map(|m| &m.kind);

    let effective_expanded = expanded || opts.media_auto_expand;

    let theme_guard = th();
    let dot = if seen {
        Span::raw("  ")
    } else {
        Span::styled("● ", Style::default().fg(theme_guard.unread_dot))
    };

    let mut header: Vec<Span<'static>> = vec![dot];
    if t.in_reply_to_tweet_id.is_some() && !in_reply_context {
        header.push(Span::styled(
            format!("{GLYPH_IS_REPLY} "),
            Style::default().fg(theme_guard.text_muted),
        ));
    }
    let show_name = matches!(opts.display_names, DisplayNameStyle::Visible);
    header.extend(author_spans(
        &t.author.handle,
        t.author.verified,
        &t.author.name,
        show_name,
    ));
    header.push(Span::styled(
        "  ·  ",
        Style::default().fg(theme_guard.text_muted),
    ));
    header.push(Span::styled(
        format_timestamp(t.created_at, opts.timestamps),
        Style::default().fg(theme_guard.text_muted),
    ));
    if translated_text.is_some() {
        header.push(Span::raw("  "));
        header.push(Span::styled(
            "[EN]",
            Style::default().fg(theme_guard.translation),
        ));
    }
    if let Some(kind) = first_media_kind {
        let (glyph, color) = media_kind_badge(kind, &theme_guard);
        header.push(Span::raw("  "));
        let label = if photo_count > 1 {
            format!("{glyph}×{photo_count}")
        } else {
            glyph.to_string()
        };
        header.push(Span::styled(label, Style::default().fg(color)));
    }
    let show_extra = effective_expanded || matches!(opts.metrics, MetricsStyle::Visible);
    let extras = if show_extra {
        extra_stats_spans(t)
    } else {
        engagement_only_spans(t)
    };
    if let Some(reply_span) = reply_count_span(t) {
        header.push(Span::raw("    "));
        header.push(reply_span);
    }
    if !extras.is_empty() {
        header.push(Span::raw("    "));
        header.extend(extras);
    }

    let mut lines: Vec<Line<'static>> = vec![Line::from(header)];

    let body_base_style = if seen {
        Style::default().fg(theme_guard.text_dim)
    } else {
        Style::default()
            .fg(theme_guard.text)
            .add_modifier(Modifier::BOLD)
    };

    let body_text: &str = if let Some(tr) = translated_text {
        tr
    } else if in_reply_context && t.in_reply_to_tweet_id.is_some() {
        strip_leading_mentions(&t.text)
    } else {
        &t.text
    };

    let indent: Span<'static> = Span::raw("  ");
    let text_width = wrap_width.saturating_sub(2).max(1);

    let mut wrapped: Vec<String> = Vec::new();
    for text_line in body_text.lines() {
        wrapped.extend(wrap_text(text_line, text_width));
    }
    let total_text_lines = wrapped.len();

    let render_body_line = |wline: &str| -> Vec<Span<'static>> {
        let mut word_spans = highlight_text(wline);
        for s in word_spans.iter_mut() {
            if seen || s.style.fg.is_none() {
                s.style = body_base_style;
            }
        }
        word_spans
    };

    let cap = if effective_expanded {
        total_text_lines
    } else {
        TEXT_LINES_IN_CARD
    };
    for wline in wrapped.iter().take(cap) {
        let mut spans = vec![indent.clone()];
        spans.extend(render_body_line(wline));
        lines.push(Line::from(spans));
    }
    if !effective_expanded && total_text_lines > cap {
        lines.push(Line::from(vec![
            indent.clone(),
            Span::styled(
                format!("… +{} more  (press x to expand)", total_text_lines - cap),
                Style::default().fg(theme_guard.text_muted),
            ),
        ]));
    }

    if let Some(qt) = &t.quoted_tweet {
        let qt_wrap = wrap_width.saturating_sub(6);
        let qt_style = Style::default().fg(theme_guard.text_muted);
        let qt_handle_color = theme::handle_color(&qt.author.handle);
        let gutter_top = Span::styled("┌ ", qt_style);
        let gutter_mid = Span::styled("│ ", qt_style);
        let gutter_bot = Span::styled("└", qt_style);

        let mut header_spans = vec![
            Span::raw("  "),
            gutter_top,
            Span::styled(
                format!("@{}", qt.author.handle),
                Style::default()
                    .fg(qt_handle_color)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::styled(
                format!("  ·  {}", format_timestamp(qt.created_at, opts.timestamps)),
                qt_style,
            ),
        ];
        if let Some(first_media) = qt.media.first() {
            let (glyph, color) = media_kind_badge(&first_media.kind, &theme_guard);
            header_spans.push(Span::raw("  "));
            header_spans.push(Span::styled(glyph.to_string(), Style::default().fg(color)));
        }
        lines.push(Line::from(header_spans));

        let qt_body = &qt.text;
        let qt_cap = if effective_expanded { usize::MAX } else { 2 };
        let mut qt_wrapped: Vec<String> = Vec::new();
        for text_line in qt_body.lines() {
            qt_wrapped.extend(wrap_text(text_line, qt_wrap));
        }
        let qt_total = qt_wrapped.len();
        for wline in qt_wrapped.iter().take(qt_cap) {
            lines.push(Line::from(vec![
                Span::raw("  "),
                gutter_mid.clone(),
                Span::styled(wline.to_string(), qt_style),
            ]));
        }
        if qt_total > qt_cap {
            lines.push(Line::from(vec![
                Span::raw("  "),
                gutter_mid.clone(),
                Span::styled(format!("… +{} more", qt_total - qt_cap), qt_style),
            ]));
        }

        if effective_expanded && opts.media_enabled {
            let qt_visuals: Vec<&crate::model::Media> = qt
                .media
                .iter()
                .filter(|m| {
                    matches!(
                        m.kind,
                        crate::model::MediaKind::Photo
                            | crate::model::MediaKind::Video
                            | crate::model::MediaKind::AnimatedGif
                    )
                })
                .collect();
            let qt_indent = Span::styled("  │ ", Style::default().fg(theme_guard.text_muted));
            let qt_max_cols = image_max_cols(qt_wrap);
            for m in &qt_visuals {
                let url = m.url.as_str();
                match render_image_lines(
                    ctx.media_reg,
                    url,
                    qt_max_cols,
                    ctx.opts.media_max_rows,
                    &qt_indent,
                ) {
                    Some(img_lines) => lines.extend(img_lines),
                    None => match ctx.media_reg.get(url) {
                        Some(MediaEntry::Failed(_)) => lines.push(media_badge_failed()),
                        _ => lines.push(media_badge_loading()),
                    },
                }
                if let Some(cap) = motion_caption_with_indent(&m.kind, &qt_indent) {
                    lines.push(cap);
                }
            }
        }

        lines.push(Line::from(vec![Span::raw("  "), gutter_bot]));
    }

    if effective_expanded && opts.media_enabled && has_photo_media {
        let visuals: Vec<&crate::model::Media> = t
            .media
            .iter()
            .filter(|m| {
                matches!(
                    m.kind,
                    crate::model::MediaKind::Photo
                        | crate::model::MediaKind::Video
                        | crate::model::MediaKind::AnimatedGif
                )
            })
            .collect();
        let visible_count = visuals.len().min(4);
        let overflow = visuals.len().saturating_sub(visible_count);
        let max_cols = image_max_cols(wrap_width);
        for m in &visuals[..visible_count] {
            let url = m.url.as_str();
            match render_image_lines(
                ctx.media_reg,
                url,
                max_cols,
                ctx.opts.media_max_rows,
                &indent,
            ) {
                Some(img_lines) => lines.extend(img_lines),
                None => match ctx.media_reg.get(url) {
                    Some(MediaEntry::Failed(_)) => lines.push(media_badge_failed()),
                    _ => lines.push(media_badge_loading()),
                },
            }
            if let Some(cap) = motion_caption(&m.kind) {
                lines.push(cap);
            }
        }
        if overflow > 0 {
            lines.push(Line::from(vec![
                indent.clone(),
                Span::styled(
                    format!("[+{overflow} more]"),
                    Style::default().fg(theme_guard.text_muted),
                ),
            ]));
        }
    }

    if opts.media_enabled {
        for m in &t.media {
            match &m.kind {
                crate::model::MediaKind::YouTube { video_id } => {
                    lines.extend(render_youtube_card(
                        ctx,
                        video_id,
                        &m.url,
                        image_max_cols(wrap_width),
                        ctx.opts.media_max_rows,
                        &indent,
                    ));
                }
                crate::model::MediaKind::Article {
                    title,
                    preview_text,
                    ..
                } => {
                    lines.extend(render_article_card(
                        ctx,
                        title,
                        preview_text,
                        &m.url,
                        card_image_max_cols(wrap_width),
                        card_image_max_rows(ctx.opts.media_max_rows),
                        &indent,
                    ));
                }
                crate::model::MediaKind::LinkCard {
                    title,
                    description,
                    domain,
                    ..
                } => {
                    lines.extend(render_link_card(
                        ctx,
                        title,
                        description,
                        domain,
                        &m.url,
                        card_image_max_cols(wrap_width),
                        card_image_max_rows(ctx.opts.media_max_rows),
                        &indent,
                    ));
                }
                crate::model::MediaKind::Poll {
                    options,
                    ends_at,
                    counts_final,
                } => {
                    lines.extend(render_poll_card(
                        options,
                        *ends_at,
                        *counts_final,
                        image_max_cols(wrap_width),
                        &indent,
                    ));
                }
                _ => {}
            }
        }
    }

    lines
}

fn image_max_cols(wrap_width: usize) -> usize {
    wrap_width.saturating_sub(4).clamp(10, 80)
}

fn card_image_max_cols(wrap_width: usize) -> usize {
    image_max_cols(wrap_width).min(50)
}

fn card_image_max_rows(media_max_rows: usize) -> usize {
    media_max_rows.min(8)
}

/// Maps a `MediaKind` to its header-row glyph and accent color from
/// the active theme. Centralised so the source-list, quote-tweet, and
/// motion-caption sites can't drift.
fn media_kind_badge(kind: &crate::model::MediaKind, t: &Theme) -> (&'static str, Color) {
    match kind {
        crate::model::MediaKind::Photo => (GLYPH_PHOTO, t.media_photo),
        crate::model::MediaKind::Video => (GLYPH_VIDEO, t.media_video),
        crate::model::MediaKind::AnimatedGif => (GLYPH_GIF, t.media_gif),
        crate::model::MediaKind::YouTube { .. } => (GLYPH_YOUTUBE, t.youtube_red),
        crate::model::MediaKind::Article { .. } => (GLYPH_ARTICLE, t.media_article),
        crate::model::MediaKind::LinkCard { .. } => (GLYPH_LINK, t.media_link),
        crate::model::MediaKind::Poll { .. } => (GLYPH_POLL, t.media_poll),
    }
}

/// Caption row shown under a video/gif thumbnail so the user knows the
/// visual is playable (press `m` to open externally).
fn motion_caption(kind: &crate::model::MediaKind) -> Option<Line<'static>> {
    motion_caption_with_indent(kind, &Span::raw("  "))
}

fn motion_caption_with_indent(
    kind: &crate::model::MediaKind,
    indent: &Span<'static>,
) -> Option<Line<'static>> {
    let t = th();
    let (glyph, label, color) = match kind {
        crate::model::MediaKind::Video => (GLYPH_VIDEO, "video", t.media_video),
        crate::model::MediaKind::AnimatedGif => (GLYPH_GIF, "gif", t.media_gif),
        _ => return None,
    };
    Some(Line::from(vec![
        indent.clone(),
        Span::styled(
            format!("{glyph} {label}"),
            Style::default().fg(color).add_modifier(Modifier::ITALIC),
        ),
    ]))
}

fn render_youtube_card(
    ctx: &RenderContext,
    video_id: &str,
    thumbnail_url: &str,
    max_cols: usize,
    max_rows: usize,
    indent: &Span<'static>,
) -> Vec<Line<'static>> {
    use crate::tui::youtube::MetaState;
    use unicode_width::UnicodeWidthStr;

    let t = th();
    let border_style = Style::default().fg(t.card_border);
    let play_style = Style::default()
        .fg(t.youtube_red)
        .add_modifier(Modifier::BOLD);
    let brand_style = Style::default()
        .fg(t.card_title)
        .add_modifier(Modifier::BOLD);
    let title_style = Style::default().fg(t.card_title);
    let meta_style = Style::default().fg(t.card_meta);

    let (title, author) = match ctx.youtube.get(video_id) {
        Some(MetaState::Ready(m)) => (m.title.clone(), m.author_name.clone()),
        Some(MetaState::Failed) => (String::new(), String::new()),
        Some(MetaState::Loading) | None => ("loading…".to_string(), String::new()),
    };

    let image_cells = image_cells_for_card(ctx.media_reg, thumbnail_url, max_cols, max_rows);
    let inner_w: usize = match image_cells {
        Some((c, _)) => c as usize,
        None => max_cols.saturating_sub(2).max(20),
    };

    let mut lines: Vec<Line<'static>> = Vec::new();

    let label = "  ▶ YouTube ";
    let label_w = UnicodeWidthStr::width(label);
    let top_right_dashes = inner_w.saturating_sub(label_w);
    lines.push(Line::from(vec![
        indent.clone(),
        Span::styled("┌", border_style),
        Span::styled("  ", border_style),
        Span::styled("▶", play_style),
        Span::styled(" YouTube ", brand_style),
        Span::styled("─".repeat(top_right_dashes), border_style),
        Span::styled("┐", border_style),
    ]));

    match image_cells {
        Some((nc, nr)) => {
            if let Some(MediaEntry::ReadyKitty { id, .. }) = ctx.media_reg.get(thumbnail_url) {
                for row in 0..nr as usize {
                    let placeholder = placeholder_row_span(*id, row, nc as usize);
                    lines.push(Line::from(vec![
                        indent.clone(),
                        Span::styled("│", border_style),
                        placeholder,
                        Span::styled("│", border_style),
                    ]));
                }
            } else if let Some(MediaEntry::ReadyPixels { pixels, w, h }) =
                ctx.media_reg.get(thumbnail_url)
            {
                let empty_indent = Span::raw("");
                let sextants =
                    media::render_sextants(pixels, *w, *h, nc as usize, nr as usize, &empty_indent);
                for row in sextants {
                    lines.push(wrap_row_in_border(indent, row, inner_w, &border_style));
                }
            } else {
                for _ in 0..nr as usize {
                    lines.push(blank_body_row(indent, inner_w, &border_style));
                }
            }
        }
        None => {
            for _ in 0..4 {
                lines.push(blank_body_row(indent, inner_w, &border_style));
            }
        }
    }

    lines.push(Line::from(vec![
        indent.clone(),
        Span::styled("├", border_style),
        Span::styled("─".repeat(inner_w), border_style),
        Span::styled("┤", border_style),
    ]));

    let title_pad = " ".to_string();
    let title_body_w = inner_w.saturating_sub(2).max(1);
    let title_display = truncate_to_width(&title, title_body_w);
    let title_padded = pad_to_width(&title_display, title_body_w);
    lines.push(Line::from(vec![
        indent.clone(),
        Span::styled("│", border_style),
        Span::raw(title_pad.clone()),
        Span::styled(title_padded, title_style.add_modifier(Modifier::BOLD)),
        Span::raw(title_pad.clone()),
        Span::styled("│", border_style),
    ]));

    let author_line = if author.is_empty() {
        "youtube.com".to_string()
    } else {
        format!("by {author} · youtube.com")
    };
    let author_display = truncate_to_width(&author_line, title_body_w);
    let author_padded = pad_to_width(&author_display, title_body_w);
    lines.push(Line::from(vec![
        indent.clone(),
        Span::styled("│", border_style),
        Span::raw(title_pad.clone()),
        Span::styled(author_padded, meta_style),
        Span::raw(title_pad),
        Span::styled("│", border_style),
    ]));

    lines.push(Line::from(vec![
        indent.clone(),
        Span::styled("└", border_style),
        Span::styled("─".repeat(inner_w), border_style),
        Span::styled("┘", border_style),
    ]));

    lines
}

#[allow(clippy::too_many_arguments)]
fn render_article_card(
    ctx: &RenderContext,
    title: &str,
    preview_text: &str,
    cover_url: &str,
    max_cols: usize,
    max_rows: usize,
    indent: &Span<'static>,
) -> Vec<Line<'static>> {
    use unicode_width::UnicodeWidthStr;

    let t = th();
    let border_style = Style::default().fg(t.card_border);
    let badge_style = Style::default()
        .fg(t.media_article)
        .add_modifier(Modifier::BOLD);
    let title_style = Style::default()
        .fg(t.card_title)
        .add_modifier(Modifier::BOLD);
    let preview_style = Style::default().fg(t.card_body);
    let meta_style = Style::default().fg(t.card_meta);

    let has_cover = !cover_url.is_empty();
    let image_cells = if has_cover {
        image_cells_for_card(ctx.media_reg, cover_url, max_cols, max_rows)
    } else {
        None
    };
    let inner_w: usize = match image_cells {
        Some((c, _)) => c as usize,
        None => max_cols.saturating_sub(2).max(20),
    };

    let mut lines: Vec<Line<'static>> = Vec::new();

    let label = "  ❏ Article ";
    let label_w = UnicodeWidthStr::width(label);
    let top_right_dashes = inner_w.saturating_sub(label_w);
    lines.push(Line::from(vec![
        indent.clone(),
        Span::styled("┌", border_style),
        Span::styled("  ", border_style),
        Span::styled("❏", badge_style),
        Span::styled(
            " Article ",
            Style::default()
                .fg(t.card_title)
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled("─".repeat(top_right_dashes), border_style),
        Span::styled("┐", border_style),
    ]));

    if has_cover {
        match image_cells {
            Some((nc, nr)) => {
                if let Some(MediaEntry::ReadyKitty { id, .. }) = ctx.media_reg.get(cover_url) {
                    for row in 0..nr as usize {
                        let placeholder = placeholder_row_span(*id, row, nc as usize);
                        lines.push(Line::from(vec![
                            indent.clone(),
                            Span::styled("│", border_style),
                            placeholder,
                            Span::styled("│", border_style),
                        ]));
                    }
                } else if let Some(MediaEntry::ReadyPixels { pixels, w, h }) =
                    ctx.media_reg.get(cover_url)
                {
                    let empty_indent = Span::raw("");
                    let sextants = media::render_sextants(
                        pixels,
                        *w,
                        *h,
                        nc as usize,
                        nr as usize,
                        &empty_indent,
                    );
                    for row in sextants {
                        lines.push(wrap_row_in_border(indent, row, inner_w, &border_style));
                    }
                } else {
                    for _ in 0..nr as usize {
                        lines.push(blank_body_row(indent, inner_w, &border_style));
                    }
                }
            }
            None => {
                for _ in 0..4 {
                    lines.push(blank_body_row(indent, inner_w, &border_style));
                }
            }
        }

        lines.push(Line::from(vec![
            indent.clone(),
            Span::styled("├", border_style),
            Span::styled("─".repeat(inner_w), border_style),
            Span::styled("┤", border_style),
        ]));
    }

    let body_w = inner_w.saturating_sub(2).max(1);
    let pad = " ".to_string();

    if title.is_empty() && preview_text.is_empty() {
        let fallback = pad_to_width(&truncate_to_width("x.com/i/article/…", body_w), body_w);
        lines.push(Line::from(vec![
            indent.clone(),
            Span::styled("│", border_style),
            Span::raw(pad.clone()),
            Span::styled(fallback, meta_style),
            Span::raw(pad.clone()),
            Span::styled("│", border_style),
        ]));
    } else {
        if !title.is_empty() {
            for wline in wrap_text(title, body_w).into_iter().take(2) {
                let padded = pad_to_width(&wline, body_w);
                lines.push(Line::from(vec![
                    indent.clone(),
                    Span::styled("│", border_style),
                    Span::raw(pad.clone()),
                    Span::styled(padded, title_style),
                    Span::raw(pad.clone()),
                    Span::styled("│", border_style),
                ]));
            }
        }
        if !preview_text.is_empty() {
            for wline in wrap_text(preview_text, body_w).into_iter().take(2) {
                let padded = pad_to_width(&wline, body_w);
                lines.push(Line::from(vec![
                    indent.clone(),
                    Span::styled("│", border_style),
                    Span::raw(pad.clone()),
                    Span::styled(padded, preview_style),
                    Span::raw(pad.clone()),
                    Span::styled("│", border_style),
                ]));
            }
        }
        let domain = pad_to_width(&truncate_to_width("x.com", body_w), body_w);
        lines.push(Line::from(vec![
            indent.clone(),
            Span::styled("│", border_style),
            Span::raw(pad.clone()),
            Span::styled(domain, meta_style),
            Span::raw(pad.clone()),
            Span::styled("│", border_style),
        ]));
    }

    lines.push(Line::from(vec![
        indent.clone(),
        Span::styled("└", border_style),
        Span::styled("─".repeat(inner_w), border_style),
        Span::styled("┘", border_style),
    ]));

    lines
}

#[allow(clippy::too_many_arguments)]
fn render_link_card(
    ctx: &RenderContext,
    title: &str,
    description: &str,
    domain: &str,
    cover_url: &str,
    max_cols: usize,
    max_rows: usize,
    indent: &Span<'static>,
) -> Vec<Line<'static>> {
    use unicode_width::UnicodeWidthStr;

    let t = th();
    let border_style = Style::default().fg(t.card_border);
    let badge_style = Style::default()
        .fg(t.media_link)
        .add_modifier(Modifier::BOLD);
    let label_style = Style::default()
        .fg(t.card_title)
        .add_modifier(Modifier::BOLD);
    let title_style = Style::default()
        .fg(t.card_title)
        .add_modifier(Modifier::BOLD);
    let body_style = Style::default().fg(t.card_body);
    let meta_style = Style::default().fg(t.card_meta);

    let has_cover = !cover_url.is_empty();
    let image_cells = if has_cover {
        image_cells_for_card(ctx.media_reg, cover_url, max_cols, max_rows)
    } else {
        None
    };
    let inner_w: usize = match image_cells {
        Some((c, _)) => c as usize,
        None => max_cols.saturating_sub(2).max(20),
    };

    let mut lines: Vec<Line<'static>> = Vec::new();

    let label = "  🔗 Link ";
    let label_w = UnicodeWidthStr::width(label);
    let top_right_dashes = inner_w.saturating_sub(label_w);
    lines.push(Line::from(vec![
        indent.clone(),
        Span::styled("┌", border_style),
        Span::styled("  ", border_style),
        Span::styled("🔗", badge_style),
        Span::styled(" Link ", label_style),
        Span::styled("─".repeat(top_right_dashes), border_style),
        Span::styled("┐", border_style),
    ]));

    if has_cover {
        match image_cells {
            Some((nc, nr)) => {
                if let Some(MediaEntry::ReadyKitty { id, .. }) = ctx.media_reg.get(cover_url) {
                    for row in 0..nr as usize {
                        let placeholder = placeholder_row_span(*id, row, nc as usize);
                        lines.push(Line::from(vec![
                            indent.clone(),
                            Span::styled("│", border_style),
                            placeholder,
                            Span::styled("│", border_style),
                        ]));
                    }
                } else if let Some(MediaEntry::ReadyPixels { pixels, w, h }) =
                    ctx.media_reg.get(cover_url)
                {
                    let empty_indent = Span::raw("");
                    let sextants = media::render_sextants(
                        pixels,
                        *w,
                        *h,
                        nc as usize,
                        nr as usize,
                        &empty_indent,
                    );
                    for row in sextants {
                        lines.push(wrap_row_in_border(indent, row, inner_w, &border_style));
                    }
                } else {
                    for _ in 0..nr as usize {
                        lines.push(blank_body_row(indent, inner_w, &border_style));
                    }
                }
            }
            None => {
                for _ in 0..4 {
                    lines.push(blank_body_row(indent, inner_w, &border_style));
                }
            }
        }

        lines.push(Line::from(vec![
            indent.clone(),
            Span::styled("├", border_style),
            Span::styled("─".repeat(inner_w), border_style),
            Span::styled("┤", border_style),
        ]));
    }

    let body_w = inner_w.saturating_sub(2).max(1);
    let pad = " ".to_string();

    if !title.is_empty() {
        for wline in wrap_text(title, body_w).into_iter().take(2) {
            let padded = pad_to_width(&wline, body_w);
            lines.push(Line::from(vec![
                indent.clone(),
                Span::styled("│", border_style),
                Span::raw(pad.clone()),
                Span::styled(padded, title_style),
                Span::raw(pad.clone()),
                Span::styled("│", border_style),
            ]));
        }
    }
    if !description.is_empty() {
        for wline in wrap_text(description, body_w).into_iter().take(2) {
            let padded = pad_to_width(&wline, body_w);
            lines.push(Line::from(vec![
                indent.clone(),
                Span::styled("│", border_style),
                Span::raw(pad.clone()),
                Span::styled(padded, body_style),
                Span::raw(pad.clone()),
                Span::styled("│", border_style),
            ]));
        }
    }
    let footer = if domain.is_empty() { "link" } else { domain };
    let footer_padded = pad_to_width(&truncate_to_width(footer, body_w), body_w);
    lines.push(Line::from(vec![
        indent.clone(),
        Span::styled("│", border_style),
        Span::raw(pad.clone()),
        Span::styled(footer_padded, meta_style),
        Span::raw(pad.clone()),
        Span::styled("│", border_style),
    ]));

    lines.push(Line::from(vec![
        indent.clone(),
        Span::styled("└", border_style),
        Span::styled("─".repeat(inner_w), border_style),
        Span::styled("┘", border_style),
    ]));

    lines
}

fn render_poll_card(
    options: &[crate::model::PollOption],
    ends_at: Option<chrono::DateTime<chrono::Utc>>,
    counts_final: bool,
    max_cols: usize,
    indent: &Span<'static>,
) -> Vec<Line<'static>> {
    use unicode_width::UnicodeWidthStr;

    let t = th();
    let border_style = Style::default().fg(t.card_border);
    let badge_style = Style::default()
        .fg(t.media_poll)
        .add_modifier(Modifier::BOLD);
    let label_style = Style::default()
        .fg(t.card_title)
        .add_modifier(Modifier::BOLD);
    let label_text_style = Style::default().fg(t.card_title);
    let bar_lead_style = Style::default()
        .fg(t.media_poll)
        .add_modifier(Modifier::BOLD);
    let bar_style = Style::default().fg(t.card_border);
    let meta_style = Style::default().fg(t.card_meta);
    let pct_style = Style::default()
        .fg(t.card_title)
        .add_modifier(Modifier::BOLD);

    let inner_w = max_cols.saturating_sub(2).max(20);
    let total_votes: u64 = options.iter().map(|o| o.count).sum();
    let leader_idx = options
        .iter()
        .enumerate()
        .max_by_key(|(_, o)| o.count)
        .map(|(i, _)| i);

    let mut lines: Vec<Line<'static>> = Vec::new();

    let header_label = "  ▥ Poll ";
    let header_w = UnicodeWidthStr::width(header_label);
    let top_dashes = inner_w.saturating_sub(header_w);
    lines.push(Line::from(vec![
        indent.clone(),
        Span::styled("┌", border_style),
        Span::styled("  ", border_style),
        Span::styled("▥", badge_style),
        Span::styled(" Poll ", label_style),
        Span::styled("─".repeat(top_dashes), border_style),
        Span::styled("┐", border_style),
    ]));

    let body_w = inner_w.saturating_sub(2).max(1);
    let pad = " ".to_string();

    for (i, opt) in options.iter().enumerate() {
        let pct = if total_votes > 0 {
            (opt.count as f64 * 100.0 / total_votes as f64).round() as u64
        } else {
            0
        };
        let is_leader = leader_idx == Some(i) && total_votes > 0;

        let pct_text = format!("{pct:>3}%");
        let label_cap = body_w.saturating_sub(pct_text.len() + 1).max(1);
        let label_display = truncate_to_width(&opt.label, label_cap);
        let label_width = UnicodeWidthStr::width(label_display.as_str());
        let spacer = body_w.saturating_sub(label_width + pct_text.len());
        let mut row_spans = vec![
            indent.clone(),
            Span::styled("│", border_style),
            Span::raw(pad.clone()),
            Span::styled(
                label_display,
                if is_leader {
                    label_text_style.add_modifier(Modifier::BOLD)
                } else {
                    label_text_style
                },
            ),
            Span::raw(" ".repeat(spacer)),
            Span::styled(pct_text, pct_style),
            Span::raw(pad.clone()),
            Span::styled("│", border_style),
        ];
        lines.push(Line::from(row_spans.split_off(0)));

        let bar_w = body_w;
        let filled = ((bar_w as u64 * opt.count) / total_votes.max(1)) as usize;
        let filled = filled.min(bar_w);
        let empty = bar_w - filled;
        let filled_str = "█".repeat(filled);
        let empty_str = "░".repeat(empty);
        lines.push(Line::from(vec![
            indent.clone(),
            Span::styled("│", border_style),
            Span::raw(pad.clone()),
            Span::styled(
                filled_str,
                if is_leader { bar_lead_style } else { bar_style },
            ),
            Span::styled(empty_str, bar_style),
            Span::raw(pad.clone()),
            Span::styled("│", border_style),
        ]));
    }

    let footer = poll_footer(total_votes, ends_at, counts_final);
    let footer_padded = pad_to_width(&truncate_to_width(&footer, body_w), body_w);
    lines.push(Line::from(vec![
        indent.clone(),
        Span::styled("│", border_style),
        Span::raw(pad.clone()),
        Span::styled(footer_padded, meta_style),
        Span::raw(pad.clone()),
        Span::styled("│", border_style),
    ]));

    lines.push(Line::from(vec![
        indent.clone(),
        Span::styled("└", border_style),
        Span::styled("─".repeat(inner_w), border_style),
        Span::styled("┘", border_style),
    ]));

    lines
}

fn poll_footer(
    total: u64,
    ends_at: Option<chrono::DateTime<chrono::Utc>>,
    counts_final: bool,
) -> String {
    let votes = format!(
        "{} vote{}",
        crate::util::short_count(total),
        if total == 1 { "" } else { "s" }
    );
    if counts_final {
        return format!("{votes} · final");
    }
    if let Some(end) = ends_at {
        let now = chrono::Utc::now();
        if end <= now {
            return format!("{votes} · ended");
        }
        let remaining = end - now;
        let mins = remaining.num_minutes().max(0);
        let human = if mins >= 24 * 60 {
            format!("{}d left", mins / (24 * 60))
        } else if mins >= 60 {
            format!("{}h left", mins / 60)
        } else {
            format!("{mins}m left")
        };
        return format!("{votes} · {human}");
    }
    votes
}

fn image_cells_for_card(
    registry: &MediaRegistry,
    url: &str,
    max_cols: usize,
    max_rows: usize,
) -> Option<(u32, u32)> {
    let entry = registry.get(url)?;
    let inner_cols = (max_cols.saturating_sub(2)).max(10) as u32;
    match entry {
        MediaEntry::ReadyKitty { w, h, .. } => {
            let cell = registry.cell_size()?;
            let (nc, nr) = media::kitty_image_cells(cell, *w, *h, inner_cols);
            let (c, r) = media::fit_cells_to_pane(nc, nr, inner_cols, max_rows as u32);
            if c == 0 || r == 0 { None } else { Some((c, r)) }
        }
        MediaEntry::ReadyPixels { w, h, .. } => {
            let (nc, nr) =
                media::kitty_image_cells(media::CellSize { w: 10, h: 20 }, *w, *h, inner_cols);
            let (c, r) = media::fit_cells_to_pane(nc, nr, inner_cols, max_rows as u32);
            if c == 0 || r == 0 { None } else { Some((c, r)) }
        }
        _ => None,
    }
}

fn blank_body_row(indent: &Span<'static>, inner_w: usize, border_style: &Style) -> Line<'static> {
    Line::from(vec![
        indent.clone(),
        Span::styled("│", *border_style),
        Span::raw(" ".repeat(inner_w)),
        Span::styled("│", *border_style),
    ])
}

fn wrap_row_in_border(
    indent: &Span<'static>,
    mut row: Line<'static>,
    inner_w: usize,
    border_style: &Style,
) -> Line<'static> {
    use unicode_width::UnicodeWidthStr;
    let row_w: usize = row
        .spans
        .iter()
        .map(|s| UnicodeWidthStr::width(s.content.as_ref()))
        .sum();
    let pad = inner_w.saturating_sub(row_w);
    let mut spans = vec![indent.clone(), Span::styled("│", *border_style)];
    spans.append(&mut row.spans);
    if pad > 0 {
        spans.push(Span::raw(" ".repeat(pad)));
    }
    spans.push(Span::styled("│", *border_style));
    Line::from(spans)
}

fn placeholder_row_span(id: u32, row: usize, cols: usize) -> Span<'static> {
    media::placeholder_row_for(id, row, cols)
}

fn truncate_to_width(s: &str, w: usize) -> String {
    use unicode_width::UnicodeWidthChar;
    let mut out = String::new();
    let mut width = 0;
    for c in s.chars() {
        let cw = UnicodeWidthChar::width(c).unwrap_or(0);
        if width + cw > w {
            if w >= 1 && width < w {
                out.push('…');
            }
            return out;
        }
        out.push(c);
        width += cw;
    }
    out
}

fn pad_to_width(s: &str, w: usize) -> String {
    use unicode_width::UnicodeWidthStr;
    let cur = UnicodeWidthStr::width(s);
    if cur >= w {
        return s.to_string();
    }
    let mut out = s.to_string();
    out.push_str(&" ".repeat(w - cur));
    out
}

fn render_image_lines(
    registry: &MediaRegistry,
    url: &str,
    max_cols: usize,
    max_rows: usize,
    indent: &Span<'static>,
) -> Option<Vec<Line<'static>>> {
    match registry.get(url)? {
        MediaEntry::ReadyKitty { id, w, h } => {
            let cell = registry.cell_size()?;
            let (nc, nr) = media::kitty_image_cells(cell, *w, *h, max_cols as u32);
            let (c, r) = media::fit_cells_to_pane(nc, nr, max_cols as u32, max_rows as u32);
            if c == 0 || r == 0 {
                return None;
            }
            Some(media::placeholder_lines(*id, r, c, indent))
        }
        MediaEntry::ReadyPixels { pixels, w, h } => Some(media::render_sextants(
            pixels, *w, *h, max_cols, max_rows, indent,
        )),
        _ => None,
    }
}

/// Drives the For You background wallpaper. Called AFTER `terminal.draw()`
/// so its cursor home-jump (needed for kitty direct-placement) never races
/// ratatui's diff writes for the current frame — ratatui always emits CUP
/// for the first cell of the next frame, so the cursor side-effect of our
/// DECRC is self-correcting.
///
/// Returns `true` when a placement was created or removed, so the caller can
/// force-invalidate ratatui's previous buffer if it needs a clean full
/// redraw on the next frame.
pub fn update_background(app: &mut App, terminal_width: u16, terminal_height: u16) -> bool {
    if app.mordor_active() {
        if !app.background.enabled() {
            if !app.media.is_kitty() {
                return false;
            }
            app.background.enable_and_prime();
        }
        app.background.show(terminal_width, terminal_height)
    } else if app.background.enabled() {
        app.background.hide()
    } else {
        false
    }
}

pub fn emit_media_placements(app: &App, terminal_width: u16) {
    if !app.media.is_kitty() {
        return;
    }
    let Some(cell) = app.media.cell_size() else {
        return;
    };

    let terminal_h = ratatui::crossterm::terminal::size()
        .map(|(_, h)| h)
        .unwrap_or(40);
    let pane_h = terminal_h.saturating_sub(2) as usize;
    let max_rows = (pane_h.saturating_sub(4) / 2).clamp(6, 24);

    let (source_wrap, detail_wrap) = if app.is_split() {
        let left = (terminal_width as u32 * app.split_pct as u32 / 100) as u16;
        let right = terminal_width.saturating_sub(left);
        ((left as usize), Some(right as usize))
    } else {
        (terminal_width as usize, None)
    };

    for tweet in app.source.tweets.iter() {
        emit_placement_for_tweet(&app.media, cell, tweet, source_wrap, max_rows);
        if let Some(thread) = app.inline_threads.get(&tweet.rest_id) {
            for (depth, reply) in &thread.replies {
                let child_wrap = source_wrap.saturating_sub(4 + depth * 2);
                emit_placement_for_tweet(&app.media, cell, reply, child_wrap, max_rows);
            }
        }
    }

    if let Some(FocusEntry::Tweet(detail)) = app.focus_stack.last() {
        let wrap = detail_wrap.unwrap_or(source_wrap);
        emit_placement_for_tweet(&app.media, cell, &detail.tweet, wrap, max_rows);
        for reply in &detail.replies {
            emit_placement_for_tweet(&app.media, cell, reply, wrap, max_rows);
            if let Some(thread) = app.inline_threads.get(&reply.rest_id) {
                for (depth, child) in &thread.replies {
                    let child_wrap = wrap.saturating_sub(4 + depth * 2);
                    emit_placement_for_tweet(&app.media, cell, child, child_wrap, max_rows);
                }
            }
        }
    }
}

fn emit_placement_for_tweet(
    registry: &MediaRegistry,
    cell: media::CellSize,
    tweet: &Tweet,
    wrap_width: usize,
    max_rows: usize,
) {
    let max_cols = image_max_cols(wrap_width);
    for media_item in tweet.media.iter().take(4) {
        match &media_item.kind {
            crate::model::MediaKind::Photo
            | crate::model::MediaKind::Video
            | crate::model::MediaKind::AnimatedGif => {
                if let Some(MediaEntry::ReadyKitty { id, w, h }) = registry.get(&media_item.url) {
                    let (nc, nr) = media::kitty_image_cells(cell, *w, *h, max_cols as u32);
                    let (c, r) = media::fit_cells_to_pane(nc, nr, max_cols as u32, max_rows as u32);
                    if c > 0 && r > 0 {
                        media::emit_kitty_placement(*id, c, r);
                    }
                }
            }
            crate::model::MediaKind::YouTube { .. }
            | crate::model::MediaKind::Article { .. }
            | crate::model::MediaKind::LinkCard { .. } => {
                let inner_cols = (max_cols.saturating_sub(2)).max(10) as u32;
                if let Some(MediaEntry::ReadyKitty { id, w, h }) = registry.get(&media_item.url) {
                    let (nc, nr) = media::kitty_image_cells(cell, *w, *h, inner_cols);
                    let (c, r) = media::fit_cells_to_pane(nc, nr, inner_cols, max_rows as u32);
                    if c > 0 && r > 0 {
                        media::emit_kitty_placement(*id, c, r);
                    }
                }
            }
            _ => {}
        }
    }
    if let Some(qt) = &tweet.quoted_tweet {
        let qt_wrap = wrap_width.saturating_sub(4);
        emit_placement_for_tweet(registry, cell, qt, qt_wrap, max_rows);
    }
}

fn append_inline_thread(
    lines: &mut Vec<Line<'static>>,
    thread: &InlineThread,
    ctx: &RenderContext,
    wrap_width: usize,
) {
    let t = th();
    lines.push(Line::from(Span::styled(
        "  ── replies ──",
        Style::default().fg(t.text_muted),
    )));
    if thread.loading {
        lines.push(Line::from(Span::styled(
            "    loading thread…",
            Style::default().fg(t.warning),
        )));
        return;
    }
    if let Some(err) = &thread.error {
        lines.push(Line::from(Span::styled(
            format!("    error: {err}"),
            Style::default().fg(t.error),
        )));
        return;
    }
    if thread.replies.is_empty() {
        lines.push(Line::from(Span::styled(
            "    no replies",
            Style::default().fg(t.text_muted),
        )));
        return;
    }
    for (depth, reply) in &thread.replies {
        let indent_cols = 4 + depth * 2;
        let child_wrap = wrap_width.saturating_sub(indent_cols);
        let reply_lines = tweet_lines(reply, ctx, false, true, child_wrap, true);
        let gutter_str: String = format!("  {:>width$}│ ", "", width = depth * 2);
        for mut line in reply_lines {
            let gutter = Span::styled(gutter_str.clone(), Style::default().fg(t.text_muted));
            let mut new_spans = vec![gutter];
            new_spans.append(&mut line.spans);
            lines.push(Line::from(new_spans));
        }
    }
}

fn wrap_text(text: &str, width: usize) -> Vec<String> {
    use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};
    if text.is_empty() {
        return vec![String::new()];
    }
    let mut lines: Vec<String> = Vec::new();
    let mut current = String::new();
    let mut current_w = 0usize;
    let push_word = |w: &str, lines: &mut Vec<String>| {
        let mut buf = String::new();
        let mut buf_w = 0usize;
        for ch in w.chars() {
            let cw = UnicodeWidthChar::width(ch).unwrap_or(0);
            if buf_w + cw > width && !buf.is_empty() {
                lines.push(std::mem::take(&mut buf));
                buf_w = 0;
            }
            buf.push(ch);
            buf_w += cw;
        }
        if !buf.is_empty() {
            lines.push(buf);
        }
    };
    for word in text.split(' ') {
        let w = UnicodeWidthStr::width(word);
        if current.is_empty() {
            if w > width {
                push_word(word, &mut lines);
                if let Some(last) = lines.pop() {
                    current_w = UnicodeWidthStr::width(last.as_str());
                    current = last;
                }
            } else {
                current.push_str(word);
                current_w = w;
            }
        } else if current_w + 1 + w <= width {
            current.push(' ');
            current.push_str(word);
            current_w += 1 + w;
        } else {
            lines.push(std::mem::take(&mut current));
            current_w = 0;
            if w > width {
                push_word(word, &mut lines);
                if let Some(last) = lines.pop() {
                    current_w = UnicodeWidthStr::width(last.as_str());
                    current = last;
                }
            } else {
                current.push_str(word);
                current_w = w;
            }
        }
    }
    if !current.is_empty() {
        lines.push(current);
    }
    if lines.is_empty() {
        lines.push(String::new());
    }
    lines
}

fn strip_leading_mentions(text: &str) -> &str {
    let mut s = text.trim_start();
    while s.starts_with('@') {
        let rest = &s[1..];
        let end = rest
            .find(|c: char| !(c.is_ascii_alphanumeric() || c == '_'))
            .unwrap_or(rest.len());
        if end == 0 {
            return s;
        }
        s = rest[end..].trim_start();
    }
    s
}

fn reply_count_span(t: &Tweet) -> Option<Span<'static>> {
    if t.reply_count == 0 {
        return None;
    }
    Some(Span::styled(
        format!("{GLYPH_REPLIES} {}", short_count(t.reply_count)),
        Style::default().fg(th().text_muted),
    ))
}

fn engaged_style(color: Color) -> Style {
    Style::default().fg(color).add_modifier(Modifier::BOLD)
}

fn extra_stats_spans(t: &Tweet) -> Vec<Span<'static>> {
    let theme_guard = th();
    let dim = Style::default().fg(theme_guard.text_muted);
    let mut parts: Vec<Span<'static>> = Vec::new();
    let push = |span: Span<'static>, parts: &mut Vec<Span<'static>>| {
        if !parts.is_empty() {
            parts.push(Span::raw("  "));
        }
        parts.push(span);
    };
    if t.retweet_count > 0 {
        push(
            Span::styled(
                format!("{GLYPH_RETWEETS} {}", short_count(t.retweet_count)),
                dim,
            ),
            &mut parts,
        );
    }
    if t.like_count > 0 || t.favorited {
        let style = if t.favorited {
            engaged_style(theme_guard.liked)
        } else {
            dim
        };
        push(
            Span::styled(
                format!("{GLYPH_LIKES} {}", short_count(t.like_count)),
                style,
            ),
            &mut parts,
        );
    }
    if let Some(v) = t.view_count
        && v > 0
    {
        push(
            Span::styled(format!("{GLYPH_VIEWS} {}", short_count(v)), dim),
            &mut parts,
        );
    }
    parts
}

fn engagement_only_spans(t: &Tweet) -> Vec<Span<'static>> {
    if !t.favorited {
        return Vec::new();
    }
    vec![Span::styled(
        GLYPH_LIKES.to_string(),
        engaged_style(th().liked),
    )]
}

fn highlight_text(text: &str) -> Vec<Span<'static>> {
    let mut spans: Vec<Span<'static>> = Vec::new();
    let mut word_start = 0usize;
    let bytes = text.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b' ' || bytes[i] == b'\t' {
            if word_start < i {
                push_word(&text[word_start..i], &mut spans);
            }
            spans.push(Span::raw(text[i..=i].to_string()));
            word_start = i + 1;
        }
        i += 1;
    }
    if word_start < bytes.len() {
        push_word(&text[word_start..], &mut spans);
    }
    if spans.is_empty() {
        spans.push(Span::raw(String::new()));
    }
    spans
}

fn push_word(word: &str, spans: &mut Vec<Span<'static>>) {
    if word.starts_with('@') && word.len() > 1 {
        let handle = word[1..].trim_end_matches(|c: char| !(c.is_ascii_alphanumeric() || c == '_'));
        let color = if handle.is_empty() {
            th().accent
        } else {
            theme::handle_color(handle)
        };
        spans.push(Span::styled(word.to_string(), Style::default().fg(color)));
    } else if word.starts_with('#') && word.len() > 1 {
        spans.push(Span::styled(
            word.to_string(),
            Style::default().fg(th().hashtag),
        ));
    } else if word.starts_with("http://") || word.starts_with("https://") {
        spans.push(Span::styled(
            word.to_string(),
            Style::default().fg(th().url),
        ));
    } else {
        spans.push(Span::raw(word.to_string()));
    }
}

fn format_timestamp(dt: DateTime<Utc>, style: TimestampStyle) -> String {
    match style {
        TimestampStyle::Absolute => dt.format("%Y-%m-%d %H:%M UTC").to_string(),
        TimestampStyle::Relative => relative_time(dt),
    }
}

fn relative_time(dt: DateTime<Utc>) -> String {
    let delta = Utc::now().signed_duration_since(dt);
    let secs = delta.num_seconds();
    if secs < 0 {
        return "now".into();
    }
    if secs < 60 {
        return format!("{secs}s");
    }
    let mins = secs / 60;
    if mins < 60 {
        return format!("{mins}m");
    }
    let hours = mins / 60;
    if hours < 24 {
        return format!("{hours}h");
    }
    let days = hours / 24;
    if days < 30 {
        return format!("{days}d");
    }
    let months = days / 30;
    if months < 12 {
        return format!("{months}mo");
    }
    let years = days / 365;
    format!("{years}y")
}

fn draw_footer(frame: &mut Frame, area: Rect, app: &App) {
    let clock_cfg = &app.app_config.clock;
    let clock_w = if matches!(clock_cfg.position, crate::config::ClockPosition::Footer) {
        crate::tui::clock::inline_width(clock_cfg).saturating_add(2)
    } else {
        0
    };
    let (left, right) = split_right(area, clock_w);

    let t = th();
    if app.mode == InputMode::Command {
        let spans = vec![
            Span::styled(
                "CMD ",
                Style::default()
                    .fg(t.mode_cmd_fg)
                    .bg(t.mode_cmd_bg)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::raw("  :"),
            Span::styled(app.command_buffer.clone(), Style::default().fg(t.text)),
            Span::styled("▎", Style::default().fg(t.mode_cmd_cursor)),
        ];
        frame.render_widget(Paragraph::new(Line::from(spans)), left);
        if clock_w > 0 {
            crate::tui::clock::render_inline(frame, right, clock_cfg);
        }
        return;
    }

    let mut spans = vec![
        Span::styled(
            "NORMAL ",
            Style::default()
                .fg(t.mode_normal_fg)
                .bg(t.mode_normal_bg)
                .add_modifier(Modifier::BOLD),
        ),
        Span::raw("  "),
    ];
    if let Some(err) = &app.error {
        spans.push(Span::styled(
            format!(" error: {err} "),
            Style::default()
                .fg(t.brand_fg)
                .bg(t.error)
                .add_modifier(Modifier::BOLD),
        ));
    } else {
        let count = app.source.len();
        let sel = if count > 0 {
            app.source.selected() + 1
        } else {
            0
        };
        spans.push(Span::styled(
            format!("{sel}/{count}"),
            Style::default().fg(t.text_muted),
        ));
        spans.push(Span::raw("   "));
        spans.push(Span::styled(
            app.status.clone(),
            Style::default().fg(t.text_muted),
        ));
    }
    frame.render_widget(Paragraph::new(Line::from(spans)), left);
    if clock_w > 0 {
        crate::tui::clock::render_inline(frame, right, clock_cfg);
    }
}

fn draw_help_overlay(frame: &mut Frame, area: Rect, scroll: u16) {
    let w = area.width.min(72);
    let h = area.height.saturating_sub(2);
    let x = (area.width.saturating_sub(w)) / 2;
    let y = (area.height.saturating_sub(h)) / 2;
    let popup = Rect {
        x,
        y,
        width: w,
        height: h,
    };

    frame.render_widget(Clear, popup);

    let t = th();
    let dim = Style::default().fg(t.text_muted);
    let heading = Style::default().fg(t.heading).add_modifier(Modifier::BOLD);
    let icon_style = Style::default().fg(t.warning);

    let lines = vec![
        Line::from(Span::styled("unrager", heading)),
        Line::from(""),
        Line::from(Span::styled("NAVIGATION", heading)),
        Line::from("  j / k / ↓ ↑    move selection"),
        Line::from("  g / G          top / bottom of the list"),
        Line::from("  Tab            swap active pane (when split)"),
        Line::from("  , / .          narrow / widen the source pane split"),
        Line::from("  Enter / l      open selected tweet into detail pane"),
        Line::from(
            "  Esc / q        back out (detail → history → home); q quits on home:following",
        ),
        Line::from(""),
        Line::from(Span::styled("LEADER  <space>", heading)),
        Line::from("  <space> o      toggle all / originals on home"),
        Line::from("  <space> f      toggle For You / Following on home"),
        Line::from("  <space> m      toggle metric counts"),
        Line::from("  <space> n      toggle display names"),
        Line::from("  <space> d      toggle relative / absolute timestamps"),
        Line::from("  <space> t      cycle x-dark / x-light theme"),
        Line::from("  <space> i      toggle media auto-expand"),
        Line::from("  <space> r      toggle rage filter"),
        Line::from(""),
        Line::from(Span::styled("SOURCES", heading)),
        Line::from("  R              toggle tweets / replies on profile"),
        Line::from("  L              who liked this tweet (own tweets only)"),
        Line::from("  :home [following]           home feed"),
        Line::from("  :user <handle>              user timeline"),
        Line::from("  :search <query> [!top|...]  live search"),
        Line::from("  :mentions [@handle]         mentions feed"),
        Line::from("  :notifs                     notifications"),
        Line::from("  :bookmarks <query>          bookmark search"),
        Line::from("  :read / :thread <id|url>    open a tweet"),
        Line::from("  :theme <auto|x-dark|x-light> swap theme live"),
        Line::from("  ] / [                       history fwd / back"),
        Line::from(""),
        Line::from(Span::styled("READ TRACKING", heading)),
        Line::from("  u              jump to next unread"),
        Line::from("  U              mark all loaded as read"),
        Line::from(""),
        Line::from(Span::styled("ACTIONS", heading)),
        Line::from("  Ctrl-r         reload source / refresh thread replies"),
        Line::from("  y              yank fixupx URL to clipboard"),
        Line::from("  Y              yank selected tweet JSON"),
        Line::from("  n              open notifications as detail pane"),
        Line::from("  o              open tweet in browser (auto-likes when write-rate-limited)"),
        Line::from("  O              open author profile in browser"),
        Line::from("  m              open all attachments in native viewer"),
        Line::from("  p              open profile of selected tweet's author"),
        Line::from("  P              open own profile in browser"),
        Line::from("  T              translate tweet to English (toggle)"),
        Line::from("  A              ask gemma (digit = preset, thread context if in detail)"),
        Line::from("  B              run a profile on the selected author (R re-read)"),
        Line::from("  r              reply to selected tweet (auto-likes the target on submit)"),
        Line::from("  f              like / unlike"),
        Line::from("  s              cycle reply sort order"),
        Line::from("  x              expand / collapse tweet body"),
        Line::from("  X              toggle inline thread replies"),
        Line::from("  Ctrl-d / Ctrl-u  half-page down / up"),
        Line::from("  Ctrl-c           quit immediately"),
        Line::from("  W                changelog (release history)"),
        Line::from("  ?                toggle this help"),
        Line::from(""),
        Line::from(Span::styled("ICONOGRAPHY", heading)),
        Line::from(""),
        Line::from(vec![
            Span::styled("  ●  ", icon_style),
            Span::raw("unread tweet"),
        ]),
        Line::from(vec![
            Span::styled("  ⮎  ", icon_style),
            Span::raw("tweet is a reply"),
        ]),
        Line::from(vec![
            Span::styled("  ↳  ", icon_style),
            Span::raw("replies"),
        ]),
        Line::from(vec![
            Span::styled("  ⟲  ", icon_style),
            Span::raw("retweets"),
        ]),
        Line::from(vec![
            Span::styled("  ♥  ", icon_style),
            Span::raw("likes ("),
            Span::styled("red", Style::default().fg(t.liked)),
            Span::raw(" = you liked)"),
        ]),
        Line::from(vec![Span::styled("  ◉  ", icon_style), Span::raw("views")]),
        Line::from(vec![
            Span::styled("  ▣  ", icon_style),
            Span::raw("photo attached"),
        ]),
        Line::from(vec![
            Span::styled("  ▶  ", icon_style),
            Span::raw("video attached"),
        ]),
        Line::from(vec![
            Span::styled("  ↻  ", icon_style),
            Span::raw("gif attached"),
        ]),
        Line::from(""),
        Line::from(Span::styled("  status bar", heading)),
        Line::from(vec![
            Span::styled("  N↑ ", Style::default().fg(t.success)),
            Span::raw("N unread tweets loaded"),
        ]),
        Line::from(vec![
            Span::styled("  −N ", Style::default().fg(t.success)),
            Span::raw("N tweets hidden by rage filter"),
        ]),
        Line::from(vec![
            Span::styled("  filter⌀ ", Style::default().fg(t.text_muted)),
            Span::raw("filter off (run `unrager doctor` to diagnose)"),
        ]),
        Line::from(vec![
            Span::styled("  ◇  ", Style::default().fg(t.accent)),
            Span::raw("originals-only mode active"),
        ]),
        Line::from(vec![
            Span::styled("  N◆ ", Style::default().fg(t.new_unread)),
            Span::raw("N detail panes stacked"),
        ]),
        Line::from(vec![
            Span::styled("  ↑X.Y.Z ", Style::default().fg(t.update)),
            Span::raw("newer version available (`unrager update`)"),
        ]),
        Line::from(""),
        Line::from(Span::styled("j/k scroll  ·  any other key to close", dim)),
    ];

    let help = Paragraph::new(lines)
        .block(
            Block::default()
                .borders(Borders::ALL)
                .border_style(Style::default().fg(t.accent))
                .title(" ? "),
        )
        .scroll((scroll, 0))
        .wrap(Wrap { trim: false });
    frame.render_widget(help, popup);
}

fn draw_changelog_overlay(frame: &mut Frame, area: Rect, app: &App) {
    let w = area.width.min(76);
    let h = area.height.saturating_sub(2);
    let x = (area.width.saturating_sub(w)) / 2;
    let y = (area.height.saturating_sub(h)) / 2;
    let popup = Rect {
        x,
        y,
        width: w,
        height: h,
    };

    frame.render_widget(Clear, popup);

    let t = th();
    let dim = Style::default().fg(t.text_muted);
    let version_style = Style::default().fg(t.update).add_modifier(Modifier::BOLD);
    let current_style = Style::default().fg(t.success).add_modifier(Modifier::BOLD);
    let heading_style = Style::default().fg(t.heading).add_modifier(Modifier::BOLD);

    let mut lines: Vec<Line> = Vec::new();

    match &app.changelog {
        None => {
            lines.push(Line::from(Span::styled("loading changelog...", dim)));
        }
        Some(releases) if releases.is_empty() => {
            lines.push(Line::from(Span::styled("could not fetch releases", dim)));
        }
        Some(releases) => {
            for (i, release) in releases.iter().enumerate() {
                if i > 0 {
                    lines.push(Line::from(Span::styled(
                        "─".repeat((w as usize).saturating_sub(4)),
                        dim,
                    )));
                    lines.push(Line::from(""));
                }

                let tag_style = if release.is_current {
                    current_style
                } else {
                    version_style
                };
                let mut version_spans = vec![Span::styled(&release.version, tag_style)];
                if release.is_current {
                    version_spans.push(Span::styled(" (current)", current_style));
                }
                lines.push(Line::from(version_spans));
                lines.push(Line::from(""));

                for raw_line in release.body.lines() {
                    let trimmed = raw_line.trim();
                    if let Some(section) = trimmed.strip_prefix("## ") {
                        lines.push(Line::from(Span::styled(section, heading_style)));
                    } else if trimmed.starts_with("- ") {
                        lines.push(Line::from(format!("  {trimmed}")));
                    } else if trimmed.to_lowercase().starts_with("**full changelog**") {
                        continue;
                    } else if !trimmed.is_empty() {
                        lines.push(Line::from(trimmed.to_string()));
                    }
                }
                lines.push(Line::from(""));
            }
        }
    }

    lines.push(Line::from(Span::styled(
        "j/k scroll  ·  any other key to close",
        dim,
    )));

    let changelog = Paragraph::new(lines)
        .block(
            Block::default()
                .borders(Borders::ALL)
                .border_style(Style::default().fg(t.accent))
                .title(" changelog "),
        )
        .scroll((app.changelog_scroll, 0))
        .wrap(Wrap { trim: false });
    frame.render_widget(changelog, popup);
}

fn draw_leader_overlay(frame: &mut Frame, area: Rect, app: &App) {
    let t = th();
    let dim = Style::default().fg(t.text_muted);
    let key_style = Style::default().fg(t.accent).add_modifier(Modifier::BOLD);
    let on_style = Style::default().fg(t.success);
    let off_style = Style::default().fg(t.text_muted);

    let on_off = |on: bool| -> Span<'static> {
        if on {
            Span::styled(" on", on_style)
        } else {
            Span::styled(" off", off_style)
        }
    };

    let originals_on = matches!(app.feed_mode, crate::tui::app::FeedMode::Originals);
    let following_on = matches!(
        app.source.kind,
        Some(crate::tui::source::SourceKind::Home { following: true })
    );
    let metrics_on = matches!(app.metrics, crate::tui::app::MetricsStyle::Visible);
    let names_on = matches!(
        app.display_names,
        crate::tui::app::DisplayNameStyle::Visible
    );
    let absolute_on = matches!(app.timestamps, crate::tui::app::TimestampStyle::Absolute);
    let images_on = app.media_auto_expand;
    let filter_on = matches!(app.filter_mode, crate::tui::filter::FilterMode::On);

    let rows: Vec<(&str, &str, Option<Span>)> = vec![
        ("o", "originals only", Some(on_off(originals_on))),
        (
            "f",
            "feed",
            Some(Span::styled(
                if following_on {
                    " following"
                } else {
                    " for you"
                },
                on_style,
            )),
        ),
        ("m", "metrics", Some(on_off(metrics_on))),
        ("n", "display names", Some(on_off(names_on))),
        (
            "d",
            "date format",
            Some(Span::styled(
                if absolute_on {
                    " absolute"
                } else {
                    " relative"
                },
                on_style,
            )),
        ),
        (
            "t",
            "theme",
            Some(Span::styled(
                format!(" {}", app.theme_name),
                Style::default().fg(t.success),
            )),
        ),
        ("i", "images auto-expand", Some(on_off(images_on))),
        ("r", "rage filter", Some(on_off(filter_on))),
    ];

    let mut lines: Vec<Line> = Vec::with_capacity(rows.len() + 3);
    lines.push(Line::from(Span::styled(
        "leader — pick a toggle",
        Style::default().fg(t.heading).add_modifier(Modifier::BOLD),
    )));
    lines.push(Line::from(""));
    for (k, label, suffix) in rows {
        let mut spans = vec![
            Span::raw(" "),
            Span::styled(k.to_string(), key_style),
            Span::raw("  "),
            Span::raw(label.to_string()),
        ];
        if let Some(s) = suffix {
            spans.push(s);
        }
        lines.push(Line::from(spans));
    }
    lines.push(Line::from(""));
    lines.push(Line::from(Span::styled(" Esc  cancel", dim)));

    let w: u16 = 34;
    let h: u16 = (lines.len() as u16).saturating_add(2).min(area.height);
    let x = area.width.saturating_sub(w + 2);
    let y = area.height.saturating_sub(h + 2);
    let popup = Rect {
        x,
        y,
        width: w,
        height: h,
    };
    frame.render_widget(Clear, popup);
    let popup_widget = Paragraph::new(lines).block(
        Block::default()
            .borders(Borders::ALL)
            .border_style(Style::default().fg(t.accent))
            .title(" <space> "),
    );
    frame.render_widget(popup_widget, popup);
}

#[cfg(test)]
mod tests {
    use super::{strip_leading_mentions, wrap_text};

    #[test]
    fn strips_single_mention() {
        assert_eq!(strip_leading_mentions("@jack hello"), "hello");
    }

    #[test]
    fn strips_multiple_mentions() {
        assert_eq!(
            strip_leading_mentions("@jack @alice @bob great point!"),
            "great point!"
        );
    }

    #[test]
    fn leaves_mid_body_mentions_alone() {
        assert_eq!(
            strip_leading_mentions("thanks @jack for the reply"),
            "thanks @jack for the reply"
        );
    }

    #[test]
    fn empty_input() {
        assert_eq!(strip_leading_mentions(""), "");
    }

    #[test]
    fn only_mentions() {
        assert_eq!(strip_leading_mentions("@jack @alice"), "");
    }

    #[test]
    fn handles_underscore_in_handle() {
        assert_eq!(strip_leading_mentions("@some_user hi there"), "hi there");
    }

    #[test]
    fn wrap_empty_string() {
        assert_eq!(wrap_text("", 40), vec![""]);
    }

    #[test]
    fn wrap_short_line_unchanged() {
        assert_eq!(wrap_text("hello world", 40), vec!["hello world"]);
    }

    #[test]
    fn wrap_breaks_at_word_boundary() {
        assert_eq!(wrap_text("hello world foo", 11), vec!["hello world", "foo"]);
    }

    #[test]
    fn wrap_word_exactly_at_width() {
        assert_eq!(wrap_text("abcde fghij", 5), vec!["abcde", "fghij"]);
    }

    #[test]
    fn wrap_word_wider_than_width() {
        assert_eq!(wrap_text("abcdefghij", 4), vec!["abcd", "efgh", "ij"]);
    }

    #[test]
    fn wrap_mixed_long_and_short() {
        assert_eq!(
            wrap_text("hi abcdefghij bye", 5),
            vec!["hi", "abcde", "fghij", "bye"]
        );
    }

    #[test]
    fn wrap_cjk_double_width() {
        assert_eq!(wrap_text("你好世界", 4), vec!["你好", "世界"]);
    }

    #[test]
    fn wrap_cjk_odd_boundary() {
        assert_eq!(wrap_text("a你好b", 3), vec!["a你", "好b"]);
    }

    #[test]
    fn wrap_preserves_multiple_words() {
        let result = wrap_text("the quick brown fox jumps over the lazy dog", 15);
        assert_eq!(
            result,
            vec!["the quick brown", "fox jumps over", "the lazy dog"]
        );
    }
}
