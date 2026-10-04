//! The TUI's side of keeping notifications read in step with x.com.
//!
//! X holds one read marker per account. A first page of notifications carries
//! it, so what the browser has read is read here too; once every notification
//! on that page has been read in the TUI, X is told, which clears the badge in
//! the browser and on the phone. X can only be told "read up to the top", so
//! reading part of a page stays local until the rest is read.

use crate::parse::notification::NotificationPage;

#[derive(Debug, Default)]
pub struct NotificationSync {
    top_cursor: Option<String>,
    ids: Vec<String>,
    newest_ms: Option<i64>,
    x_marker_ms: Option<i64>,
}

impl NotificationSync {
    /// Takes in a first page: the ids to adopt as read because X's marker
    /// covers them, and the state later reads are judged against.
    pub fn observe(&mut self, page: &NotificationPage) -> Vec<String> {
        self.top_cursor = page.top_cursor.clone();
        self.ids = page.notifications.iter().map(|n| n.id.clone()).collect();
        self.newest_ms = page.newest_ms();
        self.x_marker_ms = page.unread_after_ms.or(self.x_marker_ms);
        let Some(marker) = page.unread_after_ms else {
            return Vec::new();
        };
        page.notifications
            .iter()
            .filter(|n| n.timestamp.timestamp_millis() <= marker)
            .map(|n| n.id.clone())
            .collect()
    }

    /// The cursor to give X when the whole first page has been read here and
    /// X doesn't know yet. Hands it out once: until the next page says what X
    /// holds, the answer is nothing.
    pub fn take_cursor_to_push(&mut self, is_read: impl Fn(&str) -> bool) -> Option<String> {
        let newest = self.newest_ms?;
        if self.x_marker_ms.is_some_and(|x| x >= newest) || !self.ids.iter().all(|id| is_read(id)) {
            return None;
        }
        let cursor = self.top_cursor.clone()?;
        self.x_marker_ms = Some(newest);
        Some(cursor)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parse::notification::RawNotification;
    use chrono::DateTime;

    fn notification(id: &str, ms: i64) -> RawNotification {
        RawNotification {
            id: id.into(),
            notification_type: "Like".into(),
            actors: Vec::new(),
            others_count: None,
            message: None,
            target_tweet_id: None,
            target_tweet_like_count: None,
            target_tweet_created_at: None,
            target_tweet_snippet: None,
            target_tweet_favorited: false,
            target_media: Vec::new(),
            timestamp: DateTime::from_timestamp_millis(ms).unwrap(),
        }
    }

    fn page(marker: Option<i64>) -> NotificationPage {
        NotificationPage {
            notifications: vec![notification("new", 3_000), notification("old", 1_000)],
            top_cursor: Some("TOP".into()),
            unread_after_ms: marker,
            ..Default::default()
        }
    }

    #[test]
    fn what_x_has_read_is_adopted() {
        let mut sync = NotificationSync::default();
        assert_eq!(sync.observe(&page(Some(2_000))), vec!["old".to_string()]);
        assert!(sync.observe(&page(None)).is_empty());
    }

    #[test]
    fn a_fully_read_page_goes_to_x_once() {
        let mut sync = NotificationSync::default();
        sync.observe(&page(Some(2_000)));
        assert_eq!(sync.take_cursor_to_push(|_| true).as_deref(), Some("TOP"));
        assert_eq!(sync.take_cursor_to_push(|_| true), None);
    }

    #[test]
    fn a_partly_read_page_stays_local() {
        let mut sync = NotificationSync::default();
        sync.observe(&page(Some(2_000)));
        assert_eq!(sync.take_cursor_to_push(|id| id == "old"), None);
    }

    #[test]
    fn a_page_x_has_read_needs_no_push() {
        let mut sync = NotificationSync::default();
        sync.observe(&page(Some(3_000)));
        assert_eq!(sync.take_cursor_to_push(|_| true), None);
    }
}
