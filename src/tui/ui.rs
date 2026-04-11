use crate::model::Tweet;
use crate::tui::app::App;
use ratatui::Frame;
use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, List, ListItem, ListState, Paragraph};

pub fn draw(frame: &mut Frame, app: &App) {
    let [top, main, bottom] = Layout::vertical([
        Constraint::Length(1),
        Constraint::Min(0),
        Constraint::Length(1),
    ])
    .areas(frame.area());

    draw_header(frame, top, app);
    draw_main(frame, main, app);
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
    frame.render_widget(Paragraph::new(Line::from(spans)), area);
}

fn draw_main(frame: &mut Frame, area: Rect, app: &App) {
    if app.source.tweets.is_empty() {
        let msg = if app.source.loading {
            "loading timeline…"
        } else if let Some(err) = &app.error {
            err.as_str()
        } else {
            "no tweets"
        };
        let body =
            Paragraph::new(msg).block(Block::default().borders(Borders::ALL).title(" unrager "));
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
        .block(Block::default().borders(Borders::ALL).title(" unrager "))
        .highlight_style(
            Style::default()
                .bg(Color::Indexed(236))
                .add_modifier(Modifier::BOLD),
        )
        .highlight_symbol("▶ ");

    let mut state = ListState::default();
    state.select(Some(app.source.selected));
    frame.render_stateful_widget(list, area, &mut state);
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
            "j/k nav  g/G top/bot  r reload  q quit",
            Style::default().fg(Color::DarkGray),
        ));
    }
    frame.render_widget(Paragraph::new(Line::from(spans)), area);
}
