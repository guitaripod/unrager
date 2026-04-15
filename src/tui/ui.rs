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
use chrono::{DateTime, Utc};
use ratatui::Frame;
use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Clear, Paragraph, Wrap};
use std::borrow::Cow;
use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, Ordering};

static PALETTE_IS_DARK: AtomicBool = AtomicBool::new(true);

pub struct PaneItem {
    pub lines: Vec<Line<'static>>,
    pub zebra: bool,
}

impl PaneItem {
    pub fn new(lines: Vec<Line<'static>>) -> Self {
        Self {
            lines,
            zebra: false,
        }
    }

    pub fn with_zebra(mut self, zebra: bool) -> Self {
        self.zebra = zebra;
        self
    }
}

fn highlight_bg(active: bool) -> Color {
    if active {
        Color::Indexed(24)
    } else {
        Color::Indexed(238)
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

fn apply_line_modifier(line: &mut Line<'static>, modifier: Modifier) {
    line.style = line.style.add_modifier(modifier);
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
    let (marker_text, marker_style) = if active {
        (
            "▶ ",
            Style::default()
                .fg(Color::Cyan)
                .bg(highlight_bg)
                .add_modifier(Modifier::BOLD),
        )
    } else {
        ("· ", Style::default().fg(Color::DarkGray).bg(highlight_bg))
    };
    let marker = Span::styled(marker_text, marker_style);

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
        let _ = item.zebra;
        let mut item_lines = item.lines;
        for (j, line) in item_lines.iter_mut().enumerate() {
            if let Some(bg) = bg {
                apply_line_bg(line, bg);
                if is_selected && active {
                    apply_line_modifier(line, Modifier::BOLD);
                }
                if is_selected && j == 0 {
                    prepend_selection_marker(line, active, bg);
                }
                pad_line_to_width(line, row_width, bg);
            }
        }
        flat.extend(item_lines);
        if i + 1 < n_items {
            flat.push(Line::from(Span::styled(
                "─".repeat(row_width as usize),
                Style::default().fg(Color::Indexed(236)),
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
    pub is_dark: bool,
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
    pub translations: &'a HashMap<String, String>,
}

pub fn draw(frame: &mut Frame, app: &mut App) {
    PALETTE_IS_DARK.store(app.is_dark, Ordering::Relaxed);
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
        is_dark: app.is_dark,
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
        translations: &app.translations,
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
            &app.notif_seen,
            app.notif_actor_cursor,
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
        );
    } else {
        draw_source_list(
            frame,
            main,
            &mut app.source,
            &ctx,
            &app.notif_seen,
            app.notif_actor_cursor,
            app.error.as_deref(),
            true,
            filter_ctx,
        );
    }

    draw_footer(frame, bottom, app);

    if app.mode == InputMode::Help {
        draw_help_overlay(frame, frame.area(), app.help_scroll);
    }
}

#[derive(Debug, Clone, Copy)]
pub struct FilterRenderCtx {
    pub mode: FilterMode,
    pub pending: usize,
    pub enabled: bool,
}

fn format_countdown(remaining: std::time::Duration) -> String {
    let secs = remaining.as_secs();
    if secs < 60 {
        format!("{secs}s")
    } else {
        format!("{}:{:02}", secs / 60, secs % 60)
    }
}

fn draw_header(frame: &mut Frame, area: Rect, app: &App) {
    let mut spans = vec![
        Span::styled(
            " unrager ",
            Style::default()
                .bg(Color::Blue)
                .fg(Color::White)
                .add_modifier(Modifier::BOLD),
        ),
        Span::raw(" "),
        Span::styled(app.source.title(), Style::default().fg(Color::White)),
    ];
    if app.source.loading {
        let frame = SPINNER_FRAMES[app.spinner_frame % SPINNER_FRAMES.len()];
        spans.push(Span::raw("  "));
        spans.push(Span::styled(
            format!("{frame} loading"),
            Style::default().fg(Color::Yellow),
        ));
    }
    if app.source.exhausted && !app.source.is_empty() {
        spans.push(Span::raw("  "));
        spans.push(Span::styled(
            if app.source.is_notifications() {
                "[end of notifications]"
            } else {
                "[end of timeline]"
            },
            Style::default().fg(Color::DarkGray),
        ));
    }
    let unread = if app.source.is_notifications() {
        let ids: Vec<String> = app
            .source
            .notifications
            .iter()
            .map(|n| n.id.clone())
            .collect();
        app.notif_seen.count_unseen(&ids)
    } else {
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
            Style::default().fg(Color::Green),
        ));
    }
    if app.focus_stack.len() > 1 {
        spans.push(Span::raw("  "));
        spans.push(Span::styled(
            format!("{}◆", app.focus_stack.len()),
            Style::default().fg(Color::Magenta),
        ));
    }
    if let Some(remaining) = app.client.rate_limit_remaining() {
        spans.push(Span::raw("  "));
        spans.push(Span::styled(
            format!("⊘ rate-limited · {}", format_countdown(remaining)),
            Style::default().fg(Color::Red).add_modifier(Modifier::BOLD),
        ));
    }
    if app.filter_classifier.is_some()
        && app.filter_mode == FilterMode::On
        && app.filter_hidden_count > 0
    {
        spans.push(Span::raw("  "));
        spans.push(Span::styled(
            format!("−{}", app.filter_hidden_count),
            Style::default().fg(Color::Green),
        ));
    } else if app.filter_classifier.is_none() {
        spans.push(Span::raw("  "));
        spans.push(Span::styled(
            "filter⌀",
            Style::default().fg(Color::DarkGray),
        ));
    }
    if matches!(app.feed_mode, crate::tui::app::FeedMode::Originals)
        && matches!(app.source.kind, Some(SourceKind::Home { .. }))
    {
        spans.push(Span::raw("  "));
        spans.push(Span::styled("◇", Style::default().fg(Color::Cyan)));
    }
    if !app.source.is_notifications() && app.notif_unread_badge > 0 {
        spans.push(Span::raw("  "));
        spans.push(Span::styled(
            format!("{}n", app.notif_unread_badge),
            Style::default()
                .fg(Color::Magenta)
                .add_modifier(Modifier::BOLD),
        ));
    }
    if !app.whisper.text.is_empty() {
        spans.push(Span::raw("  "));
        let whisper_color = match app.whisper.phase {
            crate::tui::whisper::WhisperPhase::Quiet => Color::DarkGray,
            crate::tui::whisper::WhisperPhase::Active => Color::White,
            crate::tui::whisper::WhisperPhase::Surge => Color::Yellow,
            crate::tui::whisper::WhisperPhase::Cooling => Color::DarkGray,
        };
        spans.push(Span::styled(
            app.whisper.text.clone(),
            Style::default()
                .fg(whisper_color)
                .add_modifier(Modifier::ITALIC),
        ));
    }
    frame.render_widget(Paragraph::new(Line::from(spans)), area);
}

fn block_with_focus(title: &str, active: bool) -> Block<'_> {
    let border_style = if active {
        Style::default().fg(Color::Cyan)
    } else {
        Style::default().fg(Color::DarkGray)
    };
    Block::default()
        .borders(Borders::ALL)
        .border_style(border_style)
        .title(format!(" {title} "))
}

#[allow(clippy::too_many_arguments)]
fn draw_source_list(
    frame: &mut Frame,
    area: Rect,
    source: &mut Source,
    ctx: &RenderContext,
    notif_seen: &SeenStore,
    notif_actor_cursor: Option<usize>,
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
            if source.is_notifications() {
                "loading notifications…"
            } else {
                "loading timeline…"
            }
        } else if source.is_notifications() {
            error.unwrap_or("no notifications")
        } else {
            error.unwrap_or("no tweets")
        };
        let body = Paragraph::new(msg).block(block_with_focus(&title, active));
        frame.render_widget(body, area);
        return;
    }

    let wrap_width = (area.width as usize).saturating_sub(4);
    let selected = source.selected();

    let items: Vec<PaneItem> = if source.is_notifications() {
        source
            .notifications
            .iter()
            .enumerate()
            .map(|(i, n)| {
                let seen = notif_seen.is_seen(&n.id);
                let is_expanded = ctx.expanded.contains(&n.id);
                let actor_cursor = if i == selected {
                    notif_actor_cursor
                } else {
                    None
                };
                let lines = notification_lines(n, seen, wrap_width, is_expanded, actor_cursor);
                PaneItem::new(lines).with_zebra(i % 2 == 1)
            })
            .collect()
    } else {
        source
            .tweets
            .iter()
            .enumerate()
            .map(|(i, t)| {
                let is_seen = ctx.seen.is_seen(&t.rest_id);
                let is_expanded = ctx.expanded.contains(&t.rest_id);
                let lines = tweet_lines(t, ctx, is_seen, false, wrap_width, is_expanded);
                PaneItem::new(lines).with_zebra(i % 2 == 1)
            })
            .collect()
    };

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
) -> Vec<Line<'static>> {
    let mut lines = Vec::with_capacity(2);

    let dim = seen;
    let meta_color = if dim {
        Color::Indexed(239)
    } else {
        Color::DarkGray
    };

    let (icon, icon_color) = match n.notification_type.as_str() {
        "Like" => ("♥", Color::Red),
        "Retweet" => ("⟲", Color::Green),
        "Follow" => ("→", Color::Blue),
        "Reply" => ("↳", Color::Yellow),
        "Quote" => ("❝", Color::Magenta),
        "Mention" => ("@", Color::Cyan),
        "Milestone" => ("★", Color::Yellow),
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
        ("● ", Style::default().fg(Color::Green))
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
            .fg(handle_color(&first.handle))
            .add_modifier(Modifier::BOLD);
        header.push(Span::styled(format!("@{}", first.handle), handle_style));
        if first.verified {
            header.push(Span::styled(" ✓", Style::default().fg(Color::Blue)));
        }

        let others = n
            .others_count
            .unwrap_or((n.actors.len() as u64).saturating_sub(1));
        if others == 0 {
        } else if n.actors.len() >= 2 && others == 1 {
            header.push(Span::styled(", ", Style::default().fg(meta_color)));
            let second = &n.actors[1];
            let h2_style = Style::default()
                .fg(handle_color(&second.handle))
                .add_modifier(Modifier::BOLD);
            header.push(Span::styled(format!("@{}", second.handle), h2_style));
            if second.verified {
                header.push(Span::styled(" ✓", Style::default().fg(Color::Blue)));
            }
        } else {
            header.push(Span::styled(
                format!(" +{others}"),
                Style::default().fg(meta_color),
            ));
        }

        header.push(Span::styled(
            format!(" {verb}"),
            Style::default().fg(if dim {
                Color::Indexed(242)
            } else {
                Color::Gray
            }),
        ));
    } else {
        header.push(Span::styled(
            verb.to_string(),
            Style::default().fg(if dim {
                Color::Indexed(242)
            } else {
                Color::Gray
            }),
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

    lines.push(Line::from(header));

    if let Some(snippet) = &n.target_tweet_snippet {
        let snippet_style = if dim {
            Style::default().fg(Color::Indexed(241))
        } else {
            Style::default().fg(Color::Indexed(252))
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
            Style::default().fg(Color::Indexed(242))
        } else {
            Style::default().fg(Color::Gray)
        };
        for (i, actor) in n.actors.iter().enumerate() {
            let is_cursor = actor_cursor == Some(i);
            let marker = if is_cursor {
                Span::styled(
                    "  ▶ → ",
                    Style::default()
                        .fg(Color::Cyan)
                        .add_modifier(Modifier::BOLD),
                )
            } else {
                Span::styled("    → ", Style::default().fg(Color::Blue))
            };
            let mut row: Vec<Span<'static>> = vec![marker];
            let h_style = Style::default()
                .fg(handle_color(&actor.handle))
                .add_modifier(Modifier::BOLD);
            row.push(Span::styled(format!("@{}", actor.handle), h_style));
            if actor.verified {
                row.push(Span::styled(" ✓", Style::default().fg(Color::Blue)));
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
        FocusEntry::Ask(view) => draw_ask(frame, area, view, ctx, active),
        FocusEntry::Brief(view) => draw_brief(frame, area, view, active),
    }
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

    let mut lines: Vec<Line<'static>> = Vec::new();
    if view.loading_tweets {
        let dim = Style::default().fg(Color::DarkGray);
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
            Span::styled("▸ ", Style::default().fg(Color::Cyan)),
            Span::styled(progress, Style::default().fg(Color::Gray)),
        ]));
    } else {
        let has_bold = view.text.contains("**");
        let cleaned = sanitize_brief_output(&view.text);
        if !has_bold && view.text.trim().is_empty() && view.streaming {
            let angle = current_brief_angle();
            let dim = Style::default().fg(Color::DarkGray);
            lines.push(Line::from(Span::styled(
                "cognition pass · reading the sample",
                dim.add_modifier(Modifier::ITALIC),
            )));
            lines.push(Line::from(""));
            lines.push(Line::from(vec![
                Span::styled("▸ ", Style::default().fg(Color::Cyan)),
                Span::styled(angle, Style::default().fg(Color::Gray)),
            ]));
        } else if has_bold {
            lines.extend(render_markdown(cleaned));
        } else {
            lines.push(Line::from(Span::styled(
                "model returned no bold thesis · showing raw output below",
                Style::default()
                    .fg(Color::Yellow)
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
            Style::default().fg(Color::Red),
        )));
    }
    if view.complete && view.error.is_none() {
        lines.push(Line::from(""));
        lines.push(Line::from(Span::styled(
            "R re-read · Esc close",
            Style::default().fg(Color::DarkGray),
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
        .enumerate()
        .map(|(i, user)| {
            let mut row: Vec<Span<'static>> = vec![
                Span::raw("  "),
                Span::styled(
                    user.handle.clone(),
                    Style::default()
                        .fg(handle_color(&user.handle))
                        .add_modifier(Modifier::BOLD),
                ),
            ];
            if user.verified {
                row.push(Span::styled(" ✓", Style::default().fg(Color::Blue)));
            }
            if matches!(display_names, DisplayNameStyle::Visible) && !user.name.is_empty() {
                row.push(Span::styled(
                    format!("  {}", user.name),
                    Style::default().fg(Color::Gray),
                ));
            }
            if user.followers > 0 {
                row.push(Span::styled(
                    format!("  {} followers", short_count(user.followers)),
                    Style::default().fg(Color::DarkGray),
                ));
            }
            PaneItem::new(vec![Line::from(row)]).with_zebra(i % 2 == 1)
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
    } else if view.messages.is_empty() {
        "ready"
    } else {
        "done"
    };
    let mut title = format!("ask · @{}", view.tweet.author.handle);
    let imgs = view.image_count();
    if imgs > 0 {
        title.push_str(&format!(" · {imgs} img"));
        if imgs > 1 {
            title.push('s');
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
    let input_h: u16 = 2 + chip_rows;
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
    let wrap_width = (area.width as usize).saturating_sub(2);
    let handle_line = Line::from(vec![
        Span::styled(
            format!("@{}", tweet.author.handle),
            Style::default()
                .fg(handle_color(&tweet.author.handle))
                .add_modifier(Modifier::BOLD),
        ),
        Span::raw("  "),
        Span::styled(
            format_timestamp(tweet.created_at, ctx.opts.timestamps),
            Style::default().fg(Color::DarkGray),
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
        Style::default().fg(Color::DarkGray),
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

    let mut lines: Vec<Line<'static>> = Vec::new();
    if messages.is_empty() {
        lines.push(Line::from(Span::styled(
            "Ask anything about this post (answered by local gemma).",
            Style::default().fg(Color::DarkGray),
        )));
        lines.push(Line::from(Span::styled(
            "Press Enter to send; empty prompt uses 'Explain this post'.",
            Style::default().fg(Color::DarkGray),
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
                    Style::default()
                        .fg(Color::Cyan)
                        .add_modifier(Modifier::BOLD),
                )));
                for raw_line in text.lines() {
                    lines.push(Line::from(Span::raw(raw_line.to_string())));
                }
            }
            AskMessage::Assistant(m) => {
                let header_style = Style::default()
                    .fg(Color::Magenta)
                    .add_modifier(Modifier::BOLD);
                let mut header_spans = vec![Span::styled("gemma", header_style)];
                if !m.complete && streaming && idx + 1 == messages.len() {
                    header_spans.push(Span::styled(" …", Style::default().fg(Color::DarkGray)));
                }
                lines.push(Line::from(header_spans));
                if m.text.is_empty() && !m.complete {
                    lines.push(Line::from(Span::styled(
                        "thinking…",
                        Style::default()
                            .fg(Color::DarkGray)
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
            Style::default().fg(Color::Red),
        )));
    }

    let total = lines.len() as u16;
    let max_scroll = total.saturating_sub(area.height);
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
    let streaming = view.streaming;
    let input = view.input.as_str();

    let separator = "─".repeat(area.width as usize);
    let sep_line = Line::from(Span::styled(
        separator,
        Style::default().fg(Color::DarkGray),
    ));

    let prompt_style = if active {
        Style::default()
            .fg(Color::Cyan)
            .add_modifier(Modifier::BOLD)
    } else {
        Style::default().fg(Color::DarkGray)
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
            Style::default().fg(Color::DarkGray),
        ));
    } else if input.is_empty() {
        input_spans.push(Span::styled(
            "type or [1–5] preset",
            Style::default().fg(Color::DarkGray),
        ));
    } else {
        input_spans.push(Span::raw(input.to_string()));
        if active {
            input_spans.push(Span::styled(
                "▏",
                Style::default()
                    .fg(Color::Cyan)
                    .add_modifier(Modifier::BOLD),
            ));
        }
    }
    let input_line = Line::from(input_spans);

    let chips_active = active && !streaming && input.is_empty();
    let mut chip_spans: Vec<Span<'static>> = Vec::new();
    for (idx, preset) in view.available_presets() {
        if !chip_spans.is_empty() {
            chip_spans.push(Span::styled("  ", Style::default().fg(Color::DarkGray)));
        }
        let enabled = view.preset_enabled(preset) && chips_active;
        let (num_style, label_style) = if enabled {
            (
                Style::default()
                    .fg(Color::Cyan)
                    .add_modifier(Modifier::BOLD),
                Style::default().fg(Color::Gray),
            )
        } else {
            let dim = Style::default().fg(Color::DarkGray);
            (dim, dim)
        };
        chip_spans.push(Span::styled(format!("[{idx}] "), num_style));
        chip_spans.push(Span::styled(preset.label.to_string(), label_style));
    }
    let chip_line = Line::from(chip_spans);

    let mut lines = vec![sep_line, input_line, chip_line];
    if chip_rows == 2 {
        lines.push(Line::from(""));
    }
    let para = Paragraph::new(lines).wrap(Wrap { trim: false });
    frame.render_widget(para, area);
}

fn render_markdown(text: &str) -> Vec<Line<'static>> {
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
                Span::styled(line.to_string(), Style::default().fg(Color::Yellow)),
            ]));
            continue;
        }
        if let Some((level, rest)) = strip_heading(line) {
            let spans = parse_md_inline(&rest, Modifier::BOLD);
            let mut prefixed = vec![Span::styled(
                "#".repeat(level as usize) + " ",
                Style::default()
                    .fg(Color::DarkGray)
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
                    .fg(Color::Cyan)
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
            spans.push(Span::styled("• ", Style::default().fg(Color::DarkGray)));
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
        style = style.fg(Color::Yellow);
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
    let reply_suffix = if detail.loading {
        " [loading replies…]".to_string()
    } else if detail.replies.is_empty() && detail.error.is_none() {
        " · no replies".to_string()
    } else if detail.replies.is_empty() {
        String::new()
    } else {
        let sort_label = if matches!(reply_sort, ReplySortOrder::Newest) {
            String::new()
        } else {
            format!(" by {}", reply_sort.label())
        };
        format!(" · {} replies{}", detail.replies.len(), sort_label)
    };
    let title = format!("tweet @{}{}", detail.tweet.author.handle, reply_suffix);

    let wrap_width = (area.width as usize).saturating_sub(4);

    let selected = detail.selected();
    let focal_lines = tweet_lines(&detail.tweet, ctx, false, false, wrap_width, true);
    let mut items: Vec<PaneItem> = Vec::with_capacity(1 + detail.replies.len());
    items.push(PaneItem::new(focal_lines));

    for (i, t) in detail.replies.iter().enumerate() {
        let is_seen = ctx.seen.is_seen(&t.rest_id);
        let is_expanded = ctx.expanded.contains(&t.rest_id);
        let mut lines = tweet_lines(t, ctx, is_seen, true, wrap_width, is_expanded);
        if let Some(thread) = ctx.inline_threads.get(&t.rest_id) {
            append_inline_thread(&mut lines, thread, ctx, wrap_width);
        }
        items.push(PaneItem::new(lines).with_zebra(i % 2 == 0));
    }

    if detail.replies.is_empty() && detail.loading {
        items.push(PaneItem::new(vec![Line::from(Span::styled(
            "  loading replies…",
            Style::default().fg(Color::Yellow),
        ))]));
    }
    if let Some(err) = &detail.error {
        items.push(PaneItem::new(vec![Line::from(Span::styled(
            format!("  error: {err}"),
            Style::default().fg(Color::Red),
        ))]));
    }

    render_scrollable(
        frame,
        area,
        &title,
        items,
        &mut detail.state,
        Some(selected),
        active,
    );
}

fn author_spans(handle: &str, verified: bool, name: &str, show_name: bool) -> Vec<Span<'static>> {
    let color = handle_color(handle);
    let mut spans = vec![Span::styled(
        format!("@{handle}"),
        Style::default().fg(color).add_modifier(Modifier::BOLD),
    )];
    if verified {
        spans.push(Span::styled(" ✓", Style::default().fg(Color::Blue)));
    }
    if show_name && !name.is_empty() {
        spans.push(Span::raw("  "));
        spans.push(Span::styled(
            name.to_string(),
            Style::default().fg(Color::Gray),
        ));
    }
    spans
}

const HANDLE_PALETTE_DARK: &[Color] = &[
    Color::Indexed(39),
    Color::Indexed(45),
    Color::Indexed(51),
    Color::Indexed(48),
    Color::Indexed(82),
    Color::Indexed(118),
    Color::Indexed(154),
    Color::Indexed(226),
    Color::Indexed(220),
    Color::Indexed(214),
    Color::Indexed(208),
    Color::Indexed(203),
    Color::Indexed(198),
    Color::Indexed(205),
    Color::Indexed(213),
    Color::Indexed(177),
    Color::Indexed(141),
    Color::Indexed(105),
    Color::Indexed(75),
    Color::Indexed(80),
];

const HANDLE_PALETTE_LIGHT: &[Color] = &[
    Color::Indexed(19),
    Color::Indexed(25),
    Color::Indexed(24),
    Color::Indexed(22),
    Color::Indexed(28),
    Color::Indexed(29),
    Color::Indexed(64),
    Color::Indexed(100),
    Color::Indexed(94),
    Color::Indexed(130),
    Color::Indexed(124),
    Color::Indexed(88),
    Color::Indexed(52),
    Color::Indexed(126),
    Color::Indexed(132),
    Color::Indexed(90),
    Color::Indexed(92),
    Color::Indexed(55),
    Color::Indexed(57),
    Color::Indexed(60),
];

fn handle_color(handle: &str) -> Color {
    let mut h: u64 = 0xcbf29ce484222325;
    for b in handle.as_bytes() {
        h ^= b.to_ascii_lowercase() as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    let palette = if PALETTE_IS_DARK.load(Ordering::Relaxed) {
        HANDLE_PALETTE_DARK
    } else {
        HANDLE_PALETTE_LIGHT
    };
    palette[(h as usize) % palette.len()]
}

const TEXT_LINES_IN_CARD: usize = 3;

pub const ZEBRA_BG: Color = Color::Indexed(236);
const GLYPH_REPLIES: &str = "↳";
const GLYPH_RETWEETS: &str = "⟲";
const GLYPH_LIKES: &str = "♥";
const GLYPH_VIEWS: &str = "◉";
const GLYPH_IS_REPLY: &str = "⮎";
const GLYPH_PHOTO: &str = "▣";
const GLYPH_VIDEO: &str = "▶";
const GLYPH_GIF: &str = "↻";

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
        .filter(|m| matches!(m.kind, crate::model::MediaKind::Photo))
        .count();
    let has_photo_media = photo_count > 0;
    let first_media_kind = t.media.first().map(|m| m.kind);

    let effective_expanded = expanded || opts.media_auto_expand;

    let dot = if seen {
        Span::raw("  ")
    } else {
        Span::styled("● ", Style::default().fg(Color::Green))
    };

    let mut header: Vec<Span<'static>> = vec![dot];
    if t.in_reply_to_tweet_id.is_some() && !in_reply_context {
        header.push(Span::styled(
            format!("{GLYPH_IS_REPLY} "),
            Style::default().fg(Color::Indexed(244)),
        ));
    }
    let show_name = matches!(opts.display_names, DisplayNameStyle::Visible);
    header.extend(author_spans(
        &t.author.handle,
        t.author.verified,
        &t.author.name,
        show_name,
    ));
    header.push(Span::styled("  ·  ", Style::default().fg(Color::DarkGray)));
    header.push(Span::styled(
        format_timestamp(t.created_at, opts.timestamps),
        Style::default().fg(Color::DarkGray),
    ));
    if translated_text.is_some() {
        header.push(Span::raw("  "));
        header.push(Span::styled("[EN]", Style::default().fg(Color::Cyan)));
    }
    if let Some(kind) = first_media_kind {
        let (glyph, color) = match kind {
            crate::model::MediaKind::Photo => (GLYPH_PHOTO, Color::Indexed(75)),
            crate::model::MediaKind::Video => (GLYPH_VIDEO, Color::Indexed(203)),
            crate::model::MediaKind::AnimatedGif => (GLYPH_GIF, Color::Indexed(214)),
        };
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
        Vec::new()
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

    let primary_color = if opts.is_dark {
        Color::White
    } else {
        Color::Black
    };
    let body_base_style = if seen {
        Style::default().fg(Color::Indexed(241))
    } else {
        Style::default()
            .fg(primary_color)
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
                Style::default().fg(Color::DarkGray),
            ),
        ]));
    }

    if let Some(qt) = &t.quoted_tweet {
        let qt_wrap = wrap_width.saturating_sub(6);
        let qt_style = Style::default().fg(Color::DarkGray);
        let qt_handle_color = handle_color(&qt.author.handle);
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
            let (glyph, color) = match first_media.kind {
                crate::model::MediaKind::Photo => (GLYPH_PHOTO, Color::Indexed(75)),
                crate::model::MediaKind::Video => (GLYPH_VIDEO, Color::Indexed(203)),
                crate::model::MediaKind::AnimatedGif => (GLYPH_GIF, Color::Indexed(214)),
            };
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
            let qt_photos: Vec<&str> = qt
                .media
                .iter()
                .filter(|m| matches!(m.kind, crate::model::MediaKind::Photo))
                .map(|m| m.url.as_str())
                .collect();
            let qt_indent = Span::styled("  │ ", Style::default().fg(Color::DarkGray));
            let qt_max_cols = image_max_cols(qt_wrap);
            for url in &qt_photos {
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
            }
        }

        lines.push(Line::from(vec![Span::raw("  "), gutter_bot]));
    }

    if effective_expanded && opts.media_enabled && has_photo_media {
        let photo_urls: Vec<&str> = t
            .media
            .iter()
            .filter(|m| matches!(m.kind, crate::model::MediaKind::Photo))
            .map(|m| m.url.as_str())
            .collect();
        let visible_count = photo_urls.len().min(4);
        let overflow = photo_urls.len().saturating_sub(visible_count);
        let max_cols = image_max_cols(wrap_width);
        for url in &photo_urls[..visible_count] {
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
        }
        if overflow > 0 {
            lines.push(Line::from(vec![
                indent.clone(),
                Span::styled(
                    format!("[+{overflow} more]"),
                    Style::default().fg(Color::DarkGray),
                ),
            ]));
        }
    }

    lines
}

fn image_max_cols(wrap_width: usize) -> usize {
    wrap_width.saturating_sub(4).clamp(10, 80)
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
        if !matches!(media_item.kind, crate::model::MediaKind::Photo) {
            continue;
        }
        if let Some(MediaEntry::ReadyKitty { id, w, h }) = registry.get(&media_item.url) {
            let (nc, nr) = media::kitty_image_cells(cell, *w, *h, max_cols as u32);
            let (c, r) = media::fit_cells_to_pane(nc, nr, max_cols as u32, max_rows as u32);
            if c > 0 && r > 0 {
                media::emit_kitty_placement(*id, c, r);
            }
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
    lines.push(Line::from(Span::styled(
        "  ── replies ──",
        Style::default().fg(Color::DarkGray),
    )));
    if thread.loading {
        lines.push(Line::from(Span::styled(
            "    loading thread…",
            Style::default().fg(Color::Yellow),
        )));
        return;
    }
    if let Some(err) = &thread.error {
        lines.push(Line::from(Span::styled(
            format!("    error: {err}"),
            Style::default().fg(Color::Red),
        )));
        return;
    }
    if thread.replies.is_empty() {
        lines.push(Line::from(Span::styled(
            "    no replies",
            Style::default().fg(Color::DarkGray),
        )));
        return;
    }
    for (depth, reply) in &thread.replies {
        let indent_cols = 4 + depth * 2;
        let child_wrap = wrap_width.saturating_sub(indent_cols);
        let reply_lines = tweet_lines(reply, ctx, false, true, child_wrap, true);
        let gutter_str: String = format!("  {:>width$}│ ", "", width = depth * 2);
        for mut line in reply_lines {
            let gutter = Span::styled(gutter_str.clone(), Style::default().fg(Color::DarkGray));
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
        Style::default().fg(Color::DarkGray),
    ))
}

fn extra_stats_spans(t: &Tweet) -> Vec<Span<'static>> {
    let style = Style::default().fg(Color::DarkGray);
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
                style,
            ),
            &mut parts,
        );
    }
    if t.like_count > 0 {
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
            Span::styled(format!("{GLYPH_VIEWS} {}", short_count(v)), style),
            &mut parts,
        );
    }
    parts
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
            Color::Cyan
        } else {
            handle_color(handle)
        };
        spans.push(Span::styled(word.to_string(), Style::default().fg(color)));
    } else if word.starts_with('#') && word.len() > 1 {
        spans.push(Span::styled(
            word.to_string(),
            Style::default().fg(Color::Magenta),
        ));
    } else if word.starts_with("http://") || word.starts_with("https://") {
        spans.push(Span::styled(
            word.to_string(),
            Style::default().fg(Color::Blue),
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

fn short_count(n: u64) -> String {
    if n >= 1_000_000 {
        format!("{:.1}M", n as f64 / 1_000_000.0)
    } else if n >= 1_000 {
        format!("{:.1}K", n as f64 / 1_000.0)
    } else {
        n.to_string()
    }
}

fn draw_footer(frame: &mut Frame, area: Rect, app: &App) {
    if app.mode == InputMode::Command {
        let spans = vec![
            Span::styled(
                "CMD ",
                Style::default()
                    .fg(Color::Black)
                    .bg(Color::Magenta)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::raw("  :"),
            Span::styled(
                app.command_buffer.clone(),
                Style::default().fg(Color::White),
            ),
            Span::styled("▎", Style::default().fg(Color::Yellow)),
        ];
        frame.render_widget(Paragraph::new(Line::from(spans)), area);
        return;
    }

    let mut spans = vec![
        Span::styled(
            "NORMAL ",
            Style::default()
                .fg(Color::Black)
                .bg(Color::Yellow)
                .add_modifier(Modifier::BOLD),
        ),
        Span::raw("  "),
    ];
    if let Some(err) = &app.error {
        spans.push(Span::styled(
            format!(" error: {err} "),
            Style::default()
                .fg(Color::White)
                .bg(Color::Red)
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
            Style::default().fg(Color::Gray),
        ));
        spans.push(Span::raw("   "));
        spans.push(Span::styled(
            app.status.clone(),
            Style::default().fg(Color::DarkGray),
        ));
    }
    frame.render_widget(Paragraph::new(Line::from(spans)), area);
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

    let dim = Style::default().fg(Color::DarkGray);
    let heading = Style::default()
        .fg(Color::White)
        .add_modifier(Modifier::BOLD);
    let icon_style = Style::default().fg(Color::Yellow);

    let lines = vec![
        Line::from(Span::styled("unrager", heading)),
        Line::from(""),
        Line::from(Span::styled("NAVIGATION", heading)),
        Line::from("  j / k / ↓ ↑    move selection"),
        Line::from("  g / G          top / bottom of the list"),
        Line::from("  Tab            swap active pane (when split)"),
        Line::from("  , / .          narrow / widen the source pane split"),
        Line::from("  h / ←          go home (source); back (detail)"),
        Line::from("  Enter / l      open selected tweet into detail pane"),
        Line::from("  Esc            back out (detail → history → home)"),
        Line::from("  q              same as Esc, quits when on home: following"),
        Line::from(""),
        Line::from(Span::styled("SOURCES", heading)),
        Line::from("  V              toggle all / originals on home"),
        Line::from("  F              toggle For You / Following on home"),
        Line::from("  R              toggle tweets / replies on profile"),
        Line::from("  L              who liked this tweet (own tweets only)"),
        Line::from("  :home [following]           home feed"),
        Line::from("  :user <handle>              user timeline"),
        Line::from("  :search <query> [!top|...]  live search"),
        Line::from("  :mentions [@handle]         mentions feed"),
        Line::from("  :notifs                     notifications"),
        Line::from("  :bookmarks <query>          bookmark search"),
        Line::from("  :read / :thread <id|url>    open a tweet"),
        Line::from("  ] / [                       history fwd / back"),
        Line::from(""),
        Line::from(Span::styled("READ TRACKING", heading)),
        Line::from("  u              jump to next unread"),
        Line::from("  U              mark all loaded as read"),
        Line::from(""),
        Line::from(Span::styled("ACTIONS", heading)),
        Line::from("  r              reload current source"),
        Line::from("  y              yank fixupx URL to clipboard"),
        Line::from("  Y              yank selected tweet JSON"),
        Line::from("  n              open notifications"),
        Line::from("  o              open tweet in browser"),
        Line::from("  O              open author profile in browser"),
        Line::from("  m              open first media URL externally"),
        Line::from("  t              toggle relative / absolute timestamps"),
        Line::from("  M              toggle metric counts"),
        Line::from("  N              toggle display names"),
        Line::from("  I              toggle media auto-expand"),
        Line::from("  Z              toggle dark / light theme palette"),
        Line::from("  p              my profile"),
        Line::from("  P              open own profile in browser"),
        Line::from("  T              translate tweet to English (toggle)"),
        Line::from("  A              ask gemma (digit = preset, thread context if in detail)"),
        Line::from("  B              run a profile on the selected author (R re-read)"),
        Line::from("  c              toggle rage filter"),
        Line::from("  s              cycle reply sort order"),
        Line::from("  x              expand / collapse tweet body"),
        Line::from("  X              toggle inline thread replies"),
        Line::from("  Ctrl-d / Ctrl-u  half-page down / up"),
        Line::from("  Ctrl-c           quit immediately"),
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
        Line::from(vec![Span::styled("  ♥  ", icon_style), Span::raw("likes")]),
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
            Span::styled("  N↑ ", Style::default().fg(Color::Green)),
            Span::raw("N unread tweets loaded"),
        ]),
        Line::from(vec![
            Span::styled("  −N ", Style::default().fg(Color::Green)),
            Span::raw("N tweets hidden by rage filter"),
        ]),
        Line::from(vec![
            Span::styled("  filter⌀ ", Style::default().fg(Color::DarkGray)),
            Span::raw("filter off (run `unrager doctor` to diagnose)"),
        ]),
        Line::from(vec![
            Span::styled("  ◇  ", Style::default().fg(Color::Cyan)),
            Span::raw("originals-only mode active"),
        ]),
        Line::from(vec![
            Span::styled("  N◆ ", Style::default().fg(Color::Magenta)),
            Span::raw("N detail panes stacked"),
        ]),
        Line::from(""),
        Line::from(Span::styled("j/k scroll  ·  any other key to close", dim)),
    ];

    let help = Paragraph::new(lines)
        .block(
            Block::default()
                .borders(Borders::ALL)
                .border_style(Style::default().fg(Color::Yellow))
                .title(" ? "),
        )
        .scroll((scroll, 0))
        .wrap(Wrap { trim: false });
    frame.render_widget(help, popup);
}

#[cfg(test)]
mod tests {
    use super::{short_count, strip_leading_mentions, wrap_text};

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

    #[test]
    fn short_count_below_thousand() {
        assert_eq!(short_count(0), "0");
        assert_eq!(short_count(1), "1");
        assert_eq!(short_count(999), "999");
    }

    #[test]
    fn short_count_thousands() {
        assert_eq!(short_count(1000), "1.0K");
        assert_eq!(short_count(1500), "1.5K");
        assert_eq!(short_count(999_999), "1000.0K");
    }

    #[test]
    fn short_count_millions() {
        assert_eq!(short_count(1_000_000), "1.0M");
        assert_eq!(short_count(1_500_000), "1.5M");
        assert_eq!(short_count(42_300_000), "42.3M");
    }
}
