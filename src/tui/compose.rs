use crate::model::Tweet;
use crate::tui::editor::VimEditor;

const TWEET_CHAR_LIMIT: usize = 280;

#[derive(Debug, Clone)]
pub struct ReplyTarget {
    pub url: String,
    pub rest_id: String,
    pub author_handle: String,
    pub favorited: bool,
}

impl ReplyTarget {
    pub fn from_tweet(t: &Tweet) -> Self {
        Self {
            url: t.url.clone(),
            rest_id: t.rest_id.clone(),
            author_handle: t.author.handle.clone(),
            favorited: t.favorited,
        }
    }
}

#[derive(Debug)]
pub struct ReplyBar {
    pub editor: VimEditor,
    pub target: ReplyTarget,
}

impl ReplyBar {
    pub fn new(target: ReplyTarget) -> Self {
        Self {
            editor: VimEditor::with_limit(TWEET_CHAR_LIMIT),
            target,
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
