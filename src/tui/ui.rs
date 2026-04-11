use crate::model::Tweet;
use crate::tui::app::{ActivePane, App, InputMode};
use crate::tui::focus::{FocusEntry, TweetDetail};
use ratatui::Frame;
use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, List, ListItem, ListState, Paragraph, Wrap};

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
        .map(|t| ListItem::new(tweet_lines(t)))
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

    draw_focal_tweet(frame, focal_area, detail, &title, active);
    draw_replies(frame, replies_area, detail, active);
}

fn draw_focal_tweet(
    frame: &mut Frame,
    area: Rect,
    detail: &TweetDetail,
    title: &str,
    active: bool,
) {
    let t = &detail.tweet;
    let mut lines = vec![
        Line::from(vec![
            Span::styled(
                format!("@{}", t.author.handle),
                Style::default()
                    .fg(Color::Cyan)
                    .add_modifier(Modifier::BOLD),
            ),
            if t.author.verified {
                Span::styled(" ✓", Style::default().fg(Color::Blue))
            } else {
                Span::raw("")
            },
            Span::raw("  "),
            Span::styled(t.author.name.clone(), Style::default().fg(Color::Gray)),
        ]),
        Line::from(vec![
            Span::styled(
                t.created_at.format("%Y-%m-%d %H:%M UTC").to_string(),
                Style::default().fg(Color::DarkGray),
            ),
            Span::raw("  "),
            Span::styled(t.url.clone(), Style::default().fg(Color::DarkGray)),
        ]),
        Line::from(""),
    ];
    for text_line in t.text.lines() {
        lines.push(Line::from(text_line.to_string()));
    }
    lines.push(Line::from(""));
    lines.push(Line::from(vec![
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
    ]));

    let p = Paragraph::new(lines)
        .wrap(Wrap { trim: false })
        .block(block_with_focus(title, active));
    frame.render_widget(p, area);
}

fn draw_replies(frame: &mut Frame, area: Rect, detail: &TweetDetail, active: bool) {
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
        .map(|t| ListItem::new(tweet_lines(t)))
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

fn tweet_lines(t: &Tweet) -> Vec<Line<'_>> {
    let mut name_spans: Vec<Span> = vec![Span::styled(
        format!("@{}", t.author.handle),
        Style::default()
            .fg(Color::Cyan)
            .add_modifier(Modifier::BOLD),
    )];
    if t.author.verified {
        name_spans.push(Span::styled(" ✓", Style::default().fg(Color::Blue)));
    }
    if !t.author.name.is_empty() {
        name_spans.push(Span::raw("  "));
        name_spans.push(Span::styled(
            t.author.name.clone(),
            Style::default().fg(Color::Gray),
        ));
    }
    name_spans.push(Span::raw("  "));
    name_spans.push(Span::styled(
        t.created_at.format("%Y-%m-%d %H:%M UTC").to_string(),
        Style::default().fg(Color::DarkGray),
    ));

    let mut lines = vec![Line::from(name_spans)];

    for text_line in t.text.lines().take(6) {
        lines.push(Line::from(vec![Span::raw(text_line.to_string())]));
    }
    if t.text.lines().count() > 6 {
        lines.push(Line::from(vec![Span::styled(
            "…",
            Style::default().fg(Color::DarkGray),
        )]));
    }

    let mut stats = vec![
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
        stats.push(Span::raw("   "));
        stats.push(Span::styled(
            format!("👁 {}", short_count(v)),
            Style::default().fg(Color::DarkGray),
        ));
    }
    lines.push(Line::from(stats));
    lines.push(Line::from(""));
    lines
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
        let hints = if app.is_split() {
            "j/k nav  Enter open  h back  Tab swap  : cmd  q pop"
        } else {
            "j/k nav  Enter open  g/G top/bot  : cmd  ]/[ hist  r reload  q quit"
        };
        spans.push(Span::styled(hints, Style::default().fg(Color::DarkGray)));
    }
    frame.render_widget(Paragraph::new(Line::from(spans)), area);
}
