use crate::tui::editor::VimEditor;

const TWEET_CHAR_LIMIT: usize = 280;

#[derive(Debug)]
pub struct ReplyBar {
    pub editor: VimEditor,
}

impl Default for ReplyBar {
    fn default() -> Self {
        Self::new()
    }
}

impl ReplyBar {
    pub fn new() -> Self {
        Self {
            editor: VimEditor::with_limit(TWEET_CHAR_LIMIT),
        }
    }
}

#[derive(Debug)]
pub struct TweetComposeBar {
    pub editor: VimEditor,
}

impl Default for TweetComposeBar {
    fn default() -> Self {
        Self::new()
    }
}

impl TweetComposeBar {
    pub fn new() -> Self {
        Self {
            editor: VimEditor::with_limit(TWEET_CHAR_LIMIT),
        }
    }
}
