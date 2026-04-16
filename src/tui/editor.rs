use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

const DEFAULT_CHAR_LIMIT: usize = usize::MAX;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VimMode {
    Normal,
    Insert,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EditorResult {
    Consumed,
    Submit,
    ExitNormal,
}

#[derive(Debug)]
pub struct VimEditor {
    pub input: String,
    pub cursor_pos: usize,
    pub mode: VimMode,
    pub char_limit: usize,
    pending_d: bool,
}

impl Default for VimEditor {
    fn default() -> Self {
        Self::new()
    }
}

impl VimEditor {
    pub fn new() -> Self {
        Self {
            input: String::new(),
            cursor_pos: 0,
            mode: VimMode::Insert,
            char_limit: DEFAULT_CHAR_LIMIT,
            pending_d: false,
        }
    }

    pub fn with_limit(limit: usize) -> Self {
        Self {
            char_limit: limit,
            ..Self::new()
        }
    }

    pub fn normal() -> Self {
        Self {
            mode: VimMode::Normal,
            ..Self::new()
        }
    }

    pub fn handle_key(&mut self, key: KeyEvent) -> EditorResult {
        match self.mode {
            VimMode::Insert => self.handle_insert(key),
            VimMode::Normal => self.handle_normal(key),
        }
    }

    fn handle_insert(&mut self, key: KeyEvent) -> EditorResult {
        match (key.code, key.modifiers) {
            (KeyCode::Esc, _) => {
                self.enter_normal();
                EditorResult::Consumed
            }
            (KeyCode::Enter, m) if m.contains(KeyModifiers::SHIFT) => {
                self.insert_char('\n');
                EditorResult::Consumed
            }
            (KeyCode::Enter, _) => EditorResult::Submit,
            (KeyCode::Backspace, _) => {
                self.delete_back();
                EditorResult::Consumed
            }
            (KeyCode::Char('u'), KeyModifiers::CONTROL) => {
                self.clear_to_start();
                EditorResult::Consumed
            }
            (KeyCode::Char('w'), KeyModifiers::CONTROL) => {
                self.delete_word_back();
                EditorResult::Consumed
            }
            (KeyCode::Left, _) => {
                self.move_left();
                EditorResult::Consumed
            }
            (KeyCode::Right, _) => {
                self.move_right();
                EditorResult::Consumed
            }
            (KeyCode::Home, _) | (KeyCode::Char('a'), KeyModifiers::CONTROL) => {
                self.move_home();
                EditorResult::Consumed
            }
            (KeyCode::End, _) | (KeyCode::Char('e'), KeyModifiers::CONTROL) => {
                self.move_end();
                EditorResult::Consumed
            }
            (KeyCode::Char(c), m)
                if !m.contains(KeyModifiers::CONTROL) && !m.contains(KeyModifiers::ALT) =>
            {
                self.insert_char(c);
                EditorResult::Consumed
            }
            _ => EditorResult::Consumed,
        }
    }

    fn handle_normal(&mut self, key: KeyEvent) -> EditorResult {
        if self.pending_d {
            self.pending_d = false;
            if key.code == KeyCode::Char('d') {
                self.clear_line();
                return EditorResult::Consumed;
            }
            return EditorResult::Consumed;
        }

        match (key.code, key.modifiers) {
            (KeyCode::Esc, _) | (KeyCode::Char('q'), KeyModifiers::NONE) => {
                EditorResult::ExitNormal
            }
            (KeyCode::Enter, _) => EditorResult::Submit,
            (KeyCode::Char('i'), KeyModifiers::NONE) => {
                self.enter_insert();
                EditorResult::Consumed
            }
            (KeyCode::Char('a'), KeyModifiers::NONE) => {
                self.enter_insert_after();
                EditorResult::Consumed
            }
            (KeyCode::Char('I'), _) => {
                self.enter_insert_start();
                EditorResult::Consumed
            }
            (KeyCode::Char('A'), _) => {
                self.enter_insert_end();
                EditorResult::Consumed
            }
            (KeyCode::Char('h'), KeyModifiers::NONE) | (KeyCode::Left, _) => {
                self.move_left();
                EditorResult::Consumed
            }
            (KeyCode::Char('l'), KeyModifiers::NONE) | (KeyCode::Right, _) => {
                self.move_right();
                EditorResult::Consumed
            }
            (KeyCode::Char('w'), KeyModifiers::NONE) => {
                self.move_word_forward();
                EditorResult::Consumed
            }
            (KeyCode::Char('b'), KeyModifiers::NONE) => {
                self.move_word_back();
                EditorResult::Consumed
            }
            (KeyCode::Char('e'), KeyModifiers::NONE) => {
                self.move_word_end();
                EditorResult::Consumed
            }
            (KeyCode::Char('0'), KeyModifiers::NONE) => {
                self.move_home();
                EditorResult::Consumed
            }
            (KeyCode::Char('$'), _) | (KeyCode::End, _) => {
                self.move_end_normal();
                EditorResult::Consumed
            }
            (KeyCode::Home, _) | (KeyCode::Char('^'), _) => {
                self.move_home();
                EditorResult::Consumed
            }
            (KeyCode::Char('x'), KeyModifiers::NONE) => {
                self.delete_forward();
                self.clamp_cursor();
                EditorResult::Consumed
            }
            (KeyCode::Char('X'), _) => {
                self.delete_back();
                EditorResult::Consumed
            }
            (KeyCode::Char('d'), KeyModifiers::NONE) => {
                self.pending_d = true;
                EditorResult::Consumed
            }
            (KeyCode::Char('D'), _) => {
                self.delete_to_end();
                self.clamp_cursor();
                EditorResult::Consumed
            }
            (KeyCode::Char('C'), _) => {
                self.delete_to_end();
                self.mode = VimMode::Insert;
                EditorResult::Consumed
            }
            (KeyCode::Char('s'), KeyModifiers::NONE) => {
                self.delete_forward();
                self.mode = VimMode::Insert;
                EditorResult::Consumed
            }
            (KeyCode::Char('S'), _) => {
                self.clear_line();
                self.mode = VimMode::Insert;
                EditorResult::Consumed
            }
            _ => EditorResult::Consumed,
        }
    }

    pub fn char_count(&self) -> usize {
        self.input.chars().count()
    }

    fn insert_char(&mut self, c: char) {
        if self.char_count() >= self.char_limit {
            return;
        }
        self.input.insert(self.cursor_pos, c);
        self.cursor_pos += c.len_utf8();
    }

    fn delete_back(&mut self) {
        if self.cursor_pos == 0 {
            return;
        }
        let prev = prev_char_boundary(&self.input, self.cursor_pos);
        self.input.drain(prev..self.cursor_pos);
        self.cursor_pos = prev;
    }

    fn delete_forward(&mut self) {
        if self.cursor_pos >= self.input.len() {
            return;
        }
        let next = next_char_boundary(&self.input, self.cursor_pos);
        self.input.drain(self.cursor_pos..next);
    }

    fn delete_word_back(&mut self) {
        if self.cursor_pos == 0 {
            return;
        }
        let before = &self.input[..self.cursor_pos];
        let trimmed_end = before.trim_end_matches(char::is_whitespace).len();
        let cut_to = before[..trimmed_end]
            .rfind(char::is_whitespace)
            .map(|i| i + 1)
            .unwrap_or(0);
        self.input.drain(cut_to..self.cursor_pos);
        self.cursor_pos = cut_to;
    }

    fn delete_to_end(&mut self) {
        self.input.truncate(self.cursor_pos);
    }

    fn clear_line(&mut self) {
        self.input.clear();
        self.cursor_pos = 0;
    }

    fn clear_to_start(&mut self) {
        self.input.drain(..self.cursor_pos);
        self.cursor_pos = 0;
    }

    fn move_left(&mut self) {
        if self.cursor_pos > 0 {
            self.cursor_pos = prev_char_boundary(&self.input, self.cursor_pos);
        }
    }

    fn move_right(&mut self) {
        if self.cursor_pos < self.input.len() {
            self.cursor_pos = next_char_boundary(&self.input, self.cursor_pos);
        }
    }

    fn move_word_forward(&mut self) {
        let bytes = self.input.as_bytes();
        let mut i = self.cursor_pos;
        while i < bytes.len() && !bytes[i].is_ascii_whitespace() {
            i += 1;
        }
        while i < bytes.len() && bytes[i].is_ascii_whitespace() {
            i += 1;
        }
        self.cursor_pos = i.min(self.input.len());
        if self.mode == VimMode::Normal && !self.input.is_empty() {
            self.cursor_pos = self
                .cursor_pos
                .min(prev_char_boundary_or_zero(&self.input, self.input.len()));
        }
    }

    fn move_word_back(&mut self) {
        if self.cursor_pos == 0 {
            return;
        }
        let bytes = self.input.as_bytes();
        let mut i = self.cursor_pos;
        i = prev_char_boundary(&self.input, i);
        while i > 0 && bytes.get(i).is_some_and(|b| b.is_ascii_whitespace()) {
            i = prev_char_boundary(&self.input, i);
        }
        while i > 0
            && bytes
                .get(prev_char_boundary(&self.input, i))
                .is_some_and(|b| !b.is_ascii_whitespace())
        {
            i = prev_char_boundary(&self.input, i);
        }
        self.cursor_pos = i;
    }

    fn move_word_end(&mut self) {
        if self.cursor_pos >= self.input.len() {
            return;
        }
        let bytes = self.input.as_bytes();
        let mut i = next_char_boundary(&self.input, self.cursor_pos);
        while i < bytes.len() && bytes[i].is_ascii_whitespace() {
            i = next_char_boundary(&self.input, i);
        }
        while i < bytes.len()
            && bytes
                .get(next_char_boundary(&self.input, i).min(bytes.len()))
                .is_some_and(|b| !b.is_ascii_whitespace())
        {
            i = next_char_boundary(&self.input, i);
        }
        self.cursor_pos = i.min(self.input.len());
    }

    fn move_home(&mut self) {
        self.cursor_pos = 0;
    }

    fn move_end(&mut self) {
        self.cursor_pos = self.input.len();
    }

    fn move_end_normal(&mut self) {
        if self.input.is_empty() {
            return;
        }
        self.cursor_pos = prev_char_boundary_or_zero(&self.input, self.input.len());
    }

    fn enter_insert(&mut self) {
        self.mode = VimMode::Insert;
    }

    fn enter_insert_after(&mut self) {
        self.mode = VimMode::Insert;
        if self.cursor_pos < self.input.len() {
            self.cursor_pos = next_char_boundary(&self.input, self.cursor_pos);
        }
    }

    fn enter_insert_start(&mut self) {
        self.mode = VimMode::Insert;
        self.cursor_pos = 0;
    }

    fn enter_insert_end(&mut self) {
        self.mode = VimMode::Insert;
        self.cursor_pos = self.input.len();
    }

    fn enter_normal(&mut self) {
        self.mode = VimMode::Normal;
        self.clamp_cursor();
    }

    fn clamp_cursor(&mut self) {
        if self.cursor_pos > self.input.len() {
            self.cursor_pos = self.input.len();
        }
        if self.mode == VimMode::Normal
            && !self.input.is_empty()
            && self.cursor_pos >= self.input.len()
        {
            self.cursor_pos = prev_char_boundary_or_zero(&self.input, self.input.len());
        }
    }
}

fn prev_char_boundary(s: &str, pos: usize) -> usize {
    let mut i = pos.saturating_sub(1);
    while i > 0 && !s.is_char_boundary(i) {
        i -= 1;
    }
    i
}

fn prev_char_boundary_or_zero(s: &str, pos: usize) -> usize {
    if pos == 0 {
        return 0;
    }
    prev_char_boundary(s, pos)
}

fn next_char_boundary(s: &str, pos: usize) -> usize {
    let mut i = pos + 1;
    while i < s.len() && !s.is_char_boundary(i) {
        i += 1;
    }
    i.min(s.len())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::NONE)
    }

    fn ctrl(c: char) -> KeyEvent {
        KeyEvent::new(KeyCode::Char(c), KeyModifiers::CONTROL)
    }

    #[test]
    fn insert_and_escape_to_normal() {
        let mut e = VimEditor::new();
        assert_eq!(e.mode, VimMode::Insert);
        e.handle_key(key(KeyCode::Char('h')));
        e.handle_key(key(KeyCode::Char('i')));
        assert_eq!(e.input, "hi");
        assert_eq!(e.cursor_pos, 2);

        e.handle_key(key(KeyCode::Esc));
        assert_eq!(e.mode, VimMode::Normal);
        assert_eq!(e.cursor_pos, 1);
    }

    #[test]
    fn normal_h_l_movement() {
        let mut e = VimEditor::new();
        e.input = "abc".to_string();
        e.cursor_pos = 1;
        e.mode = VimMode::Normal;

        e.handle_key(key(KeyCode::Char('l')));
        assert_eq!(e.cursor_pos, 2);

        e.handle_key(key(KeyCode::Char('h')));
        assert_eq!(e.cursor_pos, 1);
    }

    #[test]
    fn normal_0_dollar() {
        let mut e = VimEditor::new();
        e.input = "hello".to_string();
        e.cursor_pos = 2;
        e.mode = VimMode::Normal;

        e.handle_key(key(KeyCode::Char('$')));
        assert_eq!(e.cursor_pos, 4);

        e.handle_key(key(KeyCode::Char('0')));
        assert_eq!(e.cursor_pos, 0);
    }

    #[test]
    fn normal_x_deletes_char() {
        let mut e = VimEditor::new();
        e.input = "abc".to_string();
        e.cursor_pos = 1;
        e.mode = VimMode::Normal;

        e.handle_key(key(KeyCode::Char('x')));
        assert_eq!(e.input, "ac");
        assert_eq!(e.cursor_pos, 1);
    }

    #[test]
    fn normal_dd_clears_line() {
        let mut e = VimEditor::new();
        e.input = "hello world".to_string();
        e.cursor_pos = 3;
        e.mode = VimMode::Normal;

        e.handle_key(key(KeyCode::Char('d')));
        e.handle_key(key(KeyCode::Char('d')));
        assert_eq!(e.input, "");
        assert_eq!(e.cursor_pos, 0);
    }

    #[test]
    fn normal_i_enters_insert() {
        let mut e = VimEditor::new();
        e.input = "abc".to_string();
        e.cursor_pos = 1;
        e.mode = VimMode::Normal;

        e.handle_key(key(KeyCode::Char('i')));
        assert_eq!(e.mode, VimMode::Insert);
        assert_eq!(e.cursor_pos, 1);
    }

    #[test]
    fn normal_a_enters_insert_after() {
        let mut e = VimEditor::new();
        e.input = "abc".to_string();
        e.cursor_pos = 1;
        e.mode = VimMode::Normal;

        e.handle_key(key(KeyCode::Char('a')));
        assert_eq!(e.mode, VimMode::Insert);
        assert_eq!(e.cursor_pos, 2);
    }

    #[test]
    fn char_limit_enforced() {
        let mut e = VimEditor::with_limit(3);
        e.handle_key(key(KeyCode::Char('a')));
        e.handle_key(key(KeyCode::Char('b')));
        e.handle_key(key(KeyCode::Char('c')));
        e.handle_key(key(KeyCode::Char('d')));
        assert_eq!(e.input, "abc");
    }

    #[test]
    fn submit_from_insert() {
        let mut e = VimEditor::new();
        e.handle_key(key(KeyCode::Char('h')));
        assert_eq!(e.handle_key(key(KeyCode::Enter)), EditorResult::Submit);
    }

    #[test]
    fn exit_from_normal() {
        let mut e = VimEditor::new();
        e.mode = VimMode::Normal;
        assert_eq!(e.handle_key(key(KeyCode::Esc)), EditorResult::ExitNormal);
    }

    #[test]
    fn ctrl_w_deletes_word() {
        let mut e = VimEditor::new();
        e.input = "hello world".to_string();
        e.cursor_pos = 11;

        e.handle_key(ctrl('w'));
        assert_eq!(e.input, "hello ");
        assert_eq!(e.cursor_pos, 6);
    }

    #[test]
    fn normal_w_b_word_motion() {
        let mut e = VimEditor::new();
        e.input = "one two three".to_string();
        e.cursor_pos = 0;
        e.mode = VimMode::Normal;

        e.handle_key(key(KeyCode::Char('w')));
        assert_eq!(e.cursor_pos, 4);

        e.handle_key(key(KeyCode::Char('w')));
        assert_eq!(e.cursor_pos, 8);

        e.handle_key(key(KeyCode::Char('b')));
        assert_eq!(e.cursor_pos, 4);
    }

    #[test]
    fn d_cancels_on_non_d() {
        let mut e = VimEditor::new();
        e.input = "hello".to_string();
        e.cursor_pos = 2;
        e.mode = VimMode::Normal;

        e.handle_key(key(KeyCode::Char('d')));
        e.handle_key(key(KeyCode::Char('x')));
        assert_eq!(e.input, "hello");
    }
}
