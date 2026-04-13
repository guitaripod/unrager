use crate::model::Tweet;
use crate::parse::notification::RawNotification;
use crate::tui::app::{
    ActivePane, App, DisplayNameStyle, InlineThread, InputMode, MetricsStyle, ReplySortOrder,
    SPINNER_FRAMES, TimestampStyle,
};
use crate::tui::filter::FilterMode;
use crate::tui::focus::FocusEntry;
use crate::tui::media::{
    self, MediaEntry, MediaRegistry, media_badge_failed, media_badge_loading, placeholder_row_span,
};
use crate::tui::seen::SeenStore;
use crate::tui::source::{Source, SourceKind};
use chrono::{DateTime, Utc};
use ratatui::Frame;
use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Clear, List, ListItem, ListState, Paragraph, Wrap};
use std::collections::{HashMap, HashSet};

const SCROLL_LOOKAHEAD: usize = 3;

fn last_visible_index(items: &[ListItem<'_>], offset: usize, inner_h: usize) -> usize {
    let mut rows = 0usize;
    let mut last = offset;
    for (i, item) in items.iter().enumerate().skip(offset) {
        let h = item.height().max(1);
        if rows + h > inner_h {
            break;
        }
        rows += h;
        last = i;
    }
    last
}

fn apply_scroll_padding(state: &mut ListState, items: &[ListItem<'_>], area_height: u16) {
    if items.is_empty() {
        return;
    }
    let inner = area_height.saturating_sub(2) as usize;
    if inner == 0 {
        return;
    }
    let sel = state.selected().unwrap_or(0);
    if sel >= items.len() {
        return;
    }
    let mut off = state.offset().min(sel);
    let target_sel = (sel + SCROLL_LOOKAHEAD).min(items.len().saturating_sub(1));
    loop {
        let lv = last_visible_index(items, off, inner);
        if lv >= target_sel {
            break;
        }
        if off >= sel {
            break;
        }
        off += 1;
    }
    *state.offset_mut() = off;
}

#[derive(Debug, Clone, Copy)]
pub struct RenderOpts {
    pub timestamps: TimestampStyle,
    pub metrics: MetricsStyle,
    pub display_names: DisplayNameStyle,
    pub is_dark: bool,
    pub media_enabled: bool,
    pub media_auto_expand: bool,
}

pub struct RenderContext<'a> {
    pub opts: RenderOpts,
    pub seen: &'a SeenStore,
    pub expanded: &'a HashSet<String>,
    pub inline_threads: &'a HashMap<String, InlineThread>,
    pub media_reg: &'a MediaRegistry,
    pub translations: &'a HashMap<String, String>,
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
        media_enabled: app.media.supported,
        media_auto_expand: app.media_auto_expand,
    };
    let filter_ctx = FilterRenderCtx {
        mode: filter_mode,
        pending: filter_pending,
        enabled: filter_enabled,
    };

    let ctx = RenderContext {
        opts,
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

pub fn emit_media_placements(app: &App, terminal_width: u16) {
    if !app.media.supported {
        return;
    }
    let wrap_width = (terminal_width as usize).saturating_sub(4);

    let needs_source = app.media_auto_expand
        || app
            .source
            .tweets
            .iter()
            .any(|t| app.expanded_bodies.contains(&t.rest_id));
    if needs_source {
        emit_placements_for_tweets(&app.media, app.source.tweets.iter(), wrap_width);
    }

    if let Some(FocusEntry::Tweet(detail)) = app.focus_stack.last() {
        let focal_iter = std::iter::once(&detail.tweet);
        let replies_iter = detail.replies.iter();
        emit_placements_for_tweets(&app.media, focal_iter.chain(replies_iter), wrap_width);
    }
}

#[derive(Debug, Clone, Copy)]
pub struct FilterRenderCtx {
    pub mode: FilterMode,
    pub pending: usize,
    pub enabled: bool,
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
    if app.filter_classifier.is_some()
        && app.filter_mode == FilterMode::On
        && app.filter_hidden_count > 0
    {
        spans.push(Span::raw("  "));
        spans.push(Span::styled(
            format!("−{}", app.filter_hidden_count),
            Style::default().fg(Color::Green),
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

    let items: Vec<ListItem> = if source.is_notifications() {
        source
            .notifications
            .iter()
            .enumerate()
            .map(|(i, n)| {
                let seen = notif_seen.is_seen(&n.id);
                let is_expanded = ctx.expanded.contains(&n.id);
                let lines = notification_lines(n, seen, wrap_width, is_expanded);
                let mut item = ListItem::new(lines);
                if i % 2 == 1 {
                    item = item.style(Style::default().bg(ZEBRA_BG));
                }
                item
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
                let mut item = ListItem::new(lines);
                if i % 2 == 1 {
                    item = item.style(Style::default().bg(ZEBRA_BG));
                }
                item
            })
            .collect()
    };

    apply_scroll_padding(&mut source.list_state, &items, area.height);

    let list = List::new(items)
        .block(block_with_focus(&title, active))
        .highlight_style(highlight_style(active))
        .highlight_symbol(highlight_symbol(active));

    frame.render_stateful_widget(list, area, &mut source.list_state);
}

fn notification_lines(
    n: &RawNotification,
    seen: bool,
    wrap_width: usize,
    expanded: bool,
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

    let bullet = if dim { "  " } else { "● " };
    let bullet_style = if dim {
        Style::default()
    } else {
        Style::default().fg(Color::Green)
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
        let mut handle_style = Style::default().fg(handle_color(&first.handle));
        if !dim {
            handle_style = handle_style.add_modifier(Modifier::BOLD);
        }
        header.push(Span::styled(first.handle.clone(), handle_style));

        let others = n
            .others_count
            .unwrap_or((n.actors.len() as u64).saturating_sub(1));
        if others == 0 {
        } else if n.actors.len() >= 2 && others == 1 {
            header.push(Span::styled(", ", Style::default().fg(meta_color)));
            let second = &n.actors[1];
            let mut h2_style = Style::default().fg(handle_color(&second.handle));
            if !dim {
                h2_style = h2_style.add_modifier(Modifier::BOLD);
            }
            header.push(Span::styled(second.handle.clone(), h2_style));
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
            Style::default().fg(Color::Indexed(239))
        } else {
            Style::default().fg(Color::Indexed(245))
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
    let Some(FocusEntry::Tweet(detail)) = entry else {
        return;
    };

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

    let focal_lines = tweet_lines(&detail.tweet, ctx, false, false, wrap_width, true);
    let mut items: Vec<ListItem> = Vec::with_capacity(1 + detail.replies.len());
    items.push(ListItem::new(focal_lines));

    for (i, t) in detail.replies.iter().enumerate() {
        let is_seen = ctx.seen.is_seen(&t.rest_id);
        let is_expanded = ctx.expanded.contains(&t.rest_id);
        let mut lines = tweet_lines(t, ctx, is_seen, true, wrap_width, is_expanded);
        if let Some(thread) = ctx.inline_threads.get(&t.rest_id) {
            append_inline_thread(&mut lines, thread, ctx, wrap_width);
        }
        let mut item = ListItem::new(lines);
        if i % 2 == 0 {
            item = item.style(Style::default().bg(ZEBRA_BG));
        }
        items.push(item);
    }

    if detail.replies.is_empty() && detail.loading {
        items.push(ListItem::new(Line::from(Span::styled(
            "  loading replies…",
            Style::default().fg(Color::Yellow),
        ))));
    }
    if let Some(err) = &detail.error {
        items.push(ListItem::new(Line::from(Span::styled(
            format!("  error: {err}"),
            Style::default().fg(Color::Red),
        ))));
    }

    apply_scroll_padding(&mut detail.list_state, &items, area.height);

    let list = List::new(items)
        .block(block_with_focus(&title, active))
        .highlight_style(highlight_style(active))
        .highlight_symbol(highlight_symbol(active));

    frame.render_stateful_widget(list, area, &mut detail.list_state);
}

fn highlight_style(active: bool) -> Style {
    if active {
        Style::default()
            .bg(Color::Indexed(24))
            .add_modifier(Modifier::BOLD)
    } else {
        Style::default().bg(Color::Indexed(238))
    }
}

fn highlight_symbol(active: bool) -> &'static str {
    if active { "▶ " } else { "· " }
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

const HANDLE_PALETTE: &[Color] = &[
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

fn handle_color(handle: &str) -> Color {
    let mut h: u64 = 0xcbf29ce484222325;
    for b in handle.as_bytes() {
        h ^= b.to_ascii_lowercase() as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    HANDLE_PALETTE[(h as usize) % HANDLE_PALETTE.len()]
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

    let effective_expanded =
        expanded || (opts.media_auto_expand && opts.media_enabled && has_photo_media);

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
        Style::default().fg(Color::DarkGray)
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
            if !qt_photos.is_empty() {
                let vis = qt_photos.len().min(4);
                let (cell_cols, cell_rows) = media::layout_for(vis, qt_wrap.saturating_add(2));
                let ready_ids: Vec<Option<u32>> = qt_photos[..vis]
                    .iter()
                    .map(|url| match ctx.media_reg.get(url) {
                        Some(MediaEntry::Ready { id_expanded, .. }) => Some(*id_expanded),
                        _ => None,
                    })
                    .collect();
                if ready_ids.iter().all(|o| o.is_some()) {
                    for row in 0..cell_rows {
                        let mut spans: Vec<Span<'static>> =
                            vec![Span::raw("  "), gutter_mid.clone()];
                        for (i, maybe_id) in ready_ids.iter().enumerate() {
                            if i > 0 {
                                spans.push(Span::raw("  "));
                            }
                            if let Some(id) = maybe_id {
                                spans.push(placeholder_row_span(*id, row, cell_cols));
                            }
                        }
                        lines.push(Line::from(spans));
                    }
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
        let slice = &photo_urls[..visible_count];
        let overflow = photo_urls.len().saturating_sub(visible_count);
        let (cell_cols, cell_rows) = media::layout_for(visible_count, wrap_width);

        let ready_ids: Vec<Option<u32>> = slice
            .iter()
            .map(|url| match ctx.media_reg.get(url) {
                Some(MediaEntry::Ready { id_expanded, .. }) => Some(*id_expanded),
                _ => None,
            })
            .collect();
        let any_not_ready = ready_ids.iter().any(|o| o.is_none());
        let first_state = ctx.media_reg.get(slice[0]);

        if any_not_ready {
            match first_state {
                Some(MediaEntry::Failed(_)) => lines.push(media_badge_failed()),
                _ => lines.push(media_badge_loading()),
            }
        } else {
            for row in 0..cell_rows {
                let mut spans: Vec<Span<'static>> = vec![indent.clone()];
                for (i, maybe_id) in ready_ids.iter().enumerate() {
                    if i > 0 {
                        spans.push(Span::raw("  "));
                    }
                    if let Some(id) = maybe_id {
                        spans.push(placeholder_row_span(*id, row, cell_cols));
                    }
                }
                lines.push(Line::from(spans));
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
    }

    lines
}

fn emit_placements_for_tweets<'a, I>(registry: &MediaRegistry, tweets: I, wrap_width: usize)
where
    I: IntoIterator<Item = &'a Tweet>,
{
    if !registry.supported {
        return;
    }
    use std::io::Write;
    let mut out = std::io::stdout().lock();
    for tweet in tweets {
        let photo_count = tweet
            .media
            .iter()
            .filter(|m| matches!(m.kind, crate::model::MediaKind::Photo))
            .count();
        if photo_count == 0 {
            continue;
        }
        let visible = photo_count.min(4);
        let (cols, rows) = media::layout_for(visible, wrap_width);
        for media in &tweet.media {
            if !matches!(media.kind, crate::model::MediaKind::Photo) {
                continue;
            }
            if let Some(MediaEntry::Ready { id_expanded, .. }) = registry.get(&media.url) {
                let _ = write!(
                    out,
                    "\x1b_Ga=p,U=1,i={id_expanded},c={cols},r={rows},q=2\x1b\\"
                );
            }
        }
    }
    let _ = out.flush();
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
        let reply_lines = tweet_lines(reply, ctx, false, true, child_wrap, false);
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
        Line::from("  q / Esc        pop detail pane; quit if stack empty"),
        Line::from(""),
        Line::from(Span::styled("SOURCES", heading)),
        Line::from("  V              toggle all / originals on home"),
        Line::from("  F              toggle For You / Following on home"),
        Line::from("  R              toggle tweets / replies on profile"),
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
        Line::from("  p              my profile"),
        Line::from("  P              open own profile in browser"),
        Line::from("  T              translate tweet to English (toggle)"),
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
