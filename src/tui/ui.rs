use crate::tui::app::App;
use ratatui::Frame;
use ratatui::layout::{Constraint, Layout};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Paragraph};

pub fn draw(frame: &mut Frame, app: &App) {
    let [top, main, bottom] = Layout::vertical([
        Constraint::Length(1),
        Constraint::Min(0),
        Constraint::Length(1),
    ])
    .areas(frame.area());

    let header = Line::from(vec![
        Span::styled(
            " unrager ",
            Style::default()
                .bg(Color::Blue)
                .fg(Color::White)
                .add_modifier(Modifier::BOLD),
        ),
        Span::raw(" "),
        Span::styled("TUI scaffolding", Style::default().fg(Color::Gray)),
    ]);
    frame.render_widget(Paragraph::new(header), top);

    let body = Paragraph::new(vec![
        Line::from(""),
        Line::from("  unrager TUI is up."),
        Line::from(""),
        Line::from("  The real interface lands in subsequent commits:"),
        Line::from("    C2: home timeline source"),
        Line::from("    C3: split view + thread replies"),
        Line::from("    C4: command palette and source switching"),
        Line::from("    C5: seen tracking + session persistence"),
        Line::from("    C6: polish (yank, media, help overlay)"),
        Line::from(""),
        Line::from("  Press q, Esc, or Ctrl-C to quit."),
    ])
    .block(Block::default().borders(Borders::ALL).title(" unrager "));
    frame.render_widget(body, main);

    let hint = Line::from(vec![
        Span::styled("NORMAL  ", Style::default().fg(Color::Yellow)),
        Span::raw(&app.status),
    ]);
    frame.render_widget(Paragraph::new(hint), bottom);
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::Terminal;
    use ratatui::backend::TestBackend;

    #[test]
    fn draws_scaffolding_screen() {
        let backend = TestBackend::new(80, 20);
        let mut terminal = Terminal::new(backend).unwrap();
        let app = App {
            running: true,
            status: "test".into(),
            last_tick: std::time::Instant::now(),
        };
        terminal.draw(|frame| draw(frame, &app)).unwrap();
        let buffer = terminal.backend().buffer().clone();
        let rendered: String = buffer
            .content
            .iter()
            .map(|cell| cell.symbol())
            .collect::<Vec<_>>()
            .join("");
        assert!(rendered.contains("unrager"));
        assert!(rendered.contains("TUI"));
        assert!(rendered.contains("NORMAL"));
    }
}
