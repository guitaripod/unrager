use crate::model::Tweet;
use crate::tui::app::{ActivePane, App, InputMode, TimestampStyle};
use crate::tui::focus::{FocusEntry, TweetDetail};
use chrono::{DateTime, Utc};
use ratatui::Frame;
use ratatui::layout::{Constraint, Layout, Margin, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Clear, List, ListItem, ListState, Paragraph, Wrap};

pub fn draw(frame: &mut Frame, app: &App) {
    let [top, main, bottom] = Layout::vertical([
        Constraint::Length(1),
        Constraint::Min(0),
        Constraint::Length(1),
    ])
    .areas(frame.area());

    draw_header(frame, top, app);

    if app.is_split() {
        let [left, right] =
            Layout::horizontal([Constraint::Percentage(50), Constraint::Percentage(50)])
                .areas(main);
        draw_source_list(frame, left, app, app.active == ActivePane::Source);
        draw_detail(frame, right, app, app.active == ActivePane::Detail);
    } else {
        draw_source_list(frame, main, app, true);
    }

    draw_footer(frame, bottom, app);

    if app.mode == InputMode::Help {
        draw_help_overlay(frame, frame.area());
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
        spans.push(Span::raw("  "));
        spans.push(Span::styled(
            "[loading…]",
            Style::default().fg(Color::Yellow),
        ));
    }
    if app.source.exhausted && !app.source.tweets.is_empty() {
        spans.push(Span::raw("  "));
        spans.push(Span::styled(
            "[end of timeline]",
            Style::default().fg(Color::DarkGray),
        ));
    }
    let ids: Vec<String> = app
        .source
        .tweets
        .iter()
        .map(|t| t.rest_id.clone())
        .collect();
    let unread = app.seen.count_unseen(&ids);
    if unread > 0 {
        spans.push(Span::raw("  "));
        spans.push(Span::styled(
            format!("[{unread} unread]"),
            Style::default().fg(Color::Green),
        ));
    }
    if app.is_split() {
        spans.push(Span::raw("  "));
        spans.push(Span::styled(
            format!("[stack: {}]", app.focus_stack.len()),
            Style::default().fg(Color::Magenta),
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

fn draw_source_list(frame: &mut Frame, area: Rect, app: &App, active: bool) {
    let title = app.source.title();

    if app.source.tweets.is_empty() {
        let msg = if app.source.loading {
            "loading timeline…"
        } else if let Some(err) = &app.error {
            err.as_str()
        } else {
            "no tweets"
        };
        let body = Paragraph::new(msg).block(block_with_focus(&title, active));
        frame.render_widget(body, area);
        return;
    }

    let items: Vec<ListItem> = app
        .source
        .tweets
        .iter()
        .map(|t| {
            let seen = app.seen.is_seen(&t.rest_id);
            ListItem::new(tweet_lines(t, app.timestamps, seen))
        })
        .collect();

    let list = List::new(items)
        .block(block_with_focus(&title, active))
        .highlight_style(highlight_style(active))
        .highlight_symbol(highlight_symbol(active));

    let mut state = ListState::default();
    state.select(Some(app.source.selected));
    frame.render_stateful_widget(list, area, &mut state);
}

fn draw_detail(frame: &mut Frame, area: Rect, app: &App, active: bool) {
    let Some(FocusEntry::Tweet(detail)) = app.focus_stack.last() else {
        return;
    };

    let title = format!("tweet @{}", detail.tweet.author.handle);

    let [focal_area, replies_area] =
        Layout::vertical([Constraint::Length(12), Constraint::Min(0)]).areas(area);

    draw_focal_tweet(frame, focal_area, detail, &title, active, app.timestamps);
    draw_replies(frame, replies_area, detail, active, app);
}

fn draw_focal_tweet(
    frame: &mut Frame,
    area: Rect,
    detail: &TweetDetail,
    title: &str,
    active: bool,
    timestamps: TimestampStyle,
) {
    let t = &detail.tweet;
    let mut lines = vec![
        Line::from(author_spans(
            &t.author.handle,
            t.author.verified,
            &t.author.name,
        )),
        Line::from(vec![
            Span::styled(
                format_timestamp(t.created_at, timestamps),
                Style::default().fg(Color::DarkGray),
            ),
            Span::raw("  "),
            Span::styled(t.url.clone(), Style::default().fg(Color::DarkGray)),
        ]),
        Line::from(""),
    ];
    for text_line in t.text.lines() {
        lines.push(Line::from(highlight_text(text_line)));
    }
    lines.push(Line::from(""));
    lines.push(stats_line(t));

    let p = Paragraph::new(lines)
        .wrap(Wrap { trim: false })
        .block(block_with_focus(title, active));
    frame.render_widget(p, area);
}

fn draw_replies(frame: &mut Frame, area: Rect, detail: &TweetDetail, active: bool, app: &App) {
    let title = if detail.loading {
        "replies [loading…]".to_string()
    } else if detail.replies.is_empty() {
        "replies".to_string()
    } else {
        format!("replies ({})", detail.replies.len())
    };

    if detail.replies.is_empty() {
        let msg = if detail.loading {
            "loading replies…"
        } else if let Some(err) = &detail.error {
            err.as_str()
        } else {
            "no replies"
        };
        let body = Paragraph::new(msg).block(block_with_focus(&title, active));
        frame.render_widget(body, area);
        return;
    }

    let items: Vec<ListItem> = detail
        .replies
        .iter()
        .map(|t| {
            let seen = app.seen.is_seen(&t.rest_id);
            ListItem::new(tweet_lines(t, app.timestamps, seen))
        })
        .collect();

    let list = List::new(items)
        .block(block_with_focus(&title, active))
        .highlight_style(highlight_style(active))
        .highlight_symbol(highlight_symbol(active));

    let mut state = ListState::default();
    state.select(Some(detail.selected));
    frame.render_stateful_widget(list, area, &mut state);
}

fn highlight_style(active: bool) -> Style {
    if active {
        Style::default()
            .bg(Color::Indexed(236))
            .add_modifier(Modifier::BOLD)
    } else {
        Style::default().bg(Color::Indexed(234))
    }
}

fn highlight_symbol(active: bool) -> &'static str {
    if active { "▶ " } else { "· " }
}

fn author_spans<'a>(handle: &'a str, verified: bool, name: &'a str) -> Vec<Span<'a>> {
    let mut spans = vec![Span::styled(
        format!("@{handle}"),
        Style::default()
            .fg(Color::Cyan)
            .add_modifier(Modifier::BOLD),
    )];
    if verified {
        spans.push(Span::styled(" ✓", Style::default().fg(Color::Blue)));
    }
    if !name.is_empty() {
        spans.push(Span::raw("  "));
        spans.push(Span::styled(
            name.to_string(),
            Style::default().fg(Color::Gray),
        ));
    }
    spans
}

fn stats_line(t: &Tweet) -> Line<'static> {
    let mut spans = vec![
        Span::styled(
            format!("💬 {}", short_count(t.reply_count)),
            Style::default().fg(Color::DarkGray),
        ),
        Span::raw("   "),
        Span::styled(
            format!("🔁 {}", short_count(t.retweet_count)),
            Style::default().fg(Color::DarkGray),
        ),
        Span::raw("   "),
        Span::styled(
            format!("♥ {}", short_count(t.like_count)),
            Style::default().fg(Color::DarkGray),
        ),
    ];
    if let Some(v) = t.view_count {
        spans.push(Span::raw("   "));
        spans.push(Span::styled(
            format!("👁 {}", short_count(v)),
            Style::default().fg(Color::DarkGray),
        ));
    }
    Line::from(spans)
}

fn tweet_lines(t: &Tweet, timestamps: TimestampStyle, seen: bool) -> Vec<Line<'_>> {
    let mut name_spans = author_spans(&t.author.handle, t.author.verified, &t.author.name);
    name_spans.push(Span::raw("  "));
    name_spans.push(Span::styled(
        format_timestamp(t.created_at, timestamps),
        Style::default().fg(Color::DarkGray),
    ));
    if !seen {
        name_spans.insert(0, Span::styled("●  ", Style::default().fg(Color::Green)));
    } else {
        name_spans.insert(0, Span::styled("   ", Style::default()));
    }

    let mut lines = vec![Line::from(name_spans)];

    let text_style = if seen {
        Style::default().fg(Color::DarkGray)
    } else {
        Style::default()
    };

    for text_line in t.text.lines().take(6) {
        let mut spans = highlight_text(text_line);
        if seen {
            for s in spans.iter_mut() {
                s.style = text_style;
            }
        }
        lines.push(Line::from(spans));
    }
    if t.text.lines().count() > 6 {
        lines.push(Line::from(vec![Span::styled(
            "…",
            Style::default().fg(Color::DarkGray),
        )]));
    }

    lines.push(stats_line(t));
    lines.push(Line::from(""));
    lines
}

fn highlight_text(text: &str) -> Vec<Span<'_>> {
    let mut spans = Vec::new();
    let mut word_start = 0usize;
    let bytes = text.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b' ' || bytes[i] == b'\t' {
            if word_start < i {
                push_word(&text[word_start..i], &mut spans);
            }
            spans.push(Span::raw(&text[i..=i]));
            word_start = i + 1;
        }
        i += 1;
    }
    if word_start < bytes.len() {
        push_word(&text[word_start..], &mut spans);
    }
    if spans.is_empty() {
        spans.push(Span::raw(""));
    }
    spans
}

fn push_word<'a>(word: &'a str, spans: &mut Vec<Span<'a>>) {
    if word.starts_with('@') && word.len() > 1 {
        spans.push(Span::styled(word, Style::default().fg(Color::Cyan)));
    } else if word.starts_with('#') && word.len() > 1 {
        spans.push(Span::styled(word, Style::default().fg(Color::Magenta)));
    } else if word.starts_with("http://") || word.starts_with("https://") {
        spans.push(Span::styled(word, Style::default().fg(Color::Blue)));
    } else {
        spans.push(Span::raw(word));
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
        return "just now".into();
    }
    if secs < 60 {
        return format!("{secs}s ago");
    }
    let mins = secs / 60;
    if mins < 60 {
        return format!("{mins}m ago");
    }
    let hours = mins / 60;
    if hours < 24 {
        return format!("{hours}h ago");
    }
    let days = hours / 24;
    if days < 30 {
        return format!("{days}d ago");
    }
    let months = days / 30;
    if months < 12 {
        return format!("{months}mo ago");
    }
    let years = days / 365;
    format!("{years}y ago")
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
            format!("error: {err}"),
            Style::default().fg(Color::Red),
        ));
    } else {
        let count = app.source.tweets.len();
        let sel = if count > 0 {
            app.source.selected + 1
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

fn draw_help_overlay(frame: &mut Frame, area: Rect) {
    let w = area.width.min(72);
    let h = area.height.min(24);
    let x = (area.width.saturating_sub(w)) / 2;
    let y = (area.height.saturating_sub(h)) / 2;
    let popup = Rect {
        x,
        y,
        width: w,
        height: h,
    };

    frame.render_widget(Clear, popup);

    let lines = vec![
        Line::from(Span::styled(
            "unrager — key bindings",
            Style::default()
                .fg(Color::White)
                .add_modifier(Modifier::BOLD),
        )),
        Line::from(""),
        Line::from("NAVIGATION"),
        Line::from("  j / k / ↓ ↑    move selection"),
        Line::from("  g / G          top / bottom of the list"),
        Line::from("  Tab            swap active pane (when split)"),
        Line::from("  h / ←          move focus from detail back to source"),
        Line::from("  Enter / l      open selected tweet into detail pane"),
        Line::from("  q / Esc        pop detail pane; quit if stack is empty"),
        Line::from(""),
        Line::from("SOURCES"),
        Line::from("  :home [following]          home For You / Following feed"),
        Line::from("  :user <handle>              timeline of a user"),
        Line::from("  :search <query> [!top|...]  live search"),
        Line::from("  :mentions [@handle]         mentions feed"),
        Line::from("  :bookmarks <query>          search within your bookmarks"),
        Line::from("  :read / :thread <id|url>    open a specific tweet"),
        Line::from("  ] / [                       history forward / back"),
        Line::from(""),
        Line::from("READ TRACKING"),
        Line::from("  u              jump to next unread in current source"),
        Line::from("  U              mark all loaded tweets as read"),
        Line::from(""),
        Line::from("ACTIONS"),
        Line::from("  r              reload current source"),
        Line::from("  y              yank selected tweet URL to clipboard"),
        Line::from("  Y              yank selected tweet JSON to clipboard"),
        Line::from("  m              open first media url externally"),
        Line::from("  t              toggle relative / absolute timestamps"),
        Line::from(""),
        Line::from(Span::styled(
            "press any key to close",
            Style::default().fg(Color::DarkGray),
        )),
    ];

    let help = Paragraph::new(lines)
        .block(
            Block::default()
                .borders(Borders::ALL)
                .border_style(Style::default().fg(Color::Yellow))
                .title(" help "),
        )
        .wrap(Wrap { trim: false });
    frame.render_widget(help, popup.inner(Margin::new(0, 0)));
}
