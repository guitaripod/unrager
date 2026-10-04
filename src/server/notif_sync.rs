//! Keeps the shared notifications seen marker in step with X's own.
//!
//! X holds one read marker per account: x.com moves it when its Notifications
//! tab opens and draws its badge from it. The server follows it in both
//! directions. Every first page of notifications it fetches carries X's marker,
//! which moves the shared marker forward (the iPhone app and anything else
//! reading `/api/notifications/seen` clear their badges when the browser read
//! them). When a client reports that it has read everything on the first page,
//! the server tells X, so the browser's badge clears too.

use crate::parse::notification::NotificationPage;
use crate::server::state::AppState;
use crate::tui::seen::marker_millis;
use crate::tui::whisper;
use chrono::{DateTime, SecondsFormat};
use std::time::{Duration, Instant};

/// How long a first page answers `GET /api/notifications/seen` before the
/// server asks X again; the iPhone poller fetches every 15 s, so it rarely does.
pub const READ_FRESH_FOR: Duration = Duration::from_secs(20);

/// How recent the newest notification must be for a client's report to be
/// judged against it.
const PUSH_FRESH_FOR: Duration = Duration::from_secs(60);

/// What the last first page of notifications said.
#[derive(Debug, Default)]
pub struct NotificationSync {
    top_cursor: Option<String>,
    newest_ms: Option<i64>,
    x_marker_ms: Option<i64>,
    fetched_at: Option<Instant>,
}

impl NotificationSync {
    fn is_fresh(&self, within: Duration) -> bool {
        self.fetched_at.is_some_and(|at| at.elapsed() < within)
    }

    fn observe(&mut self, page: &NotificationPage) {
        self.top_cursor = page.top_cursor.clone();
        self.newest_ms = page.newest_ms();
        if let Some(marker) = page.unread_after_ms {
            self.x_marker_ms = Some(self.x_marker_ms.map_or(marker, |known| known.max(marker)));
        }
        self.fetched_at = Some(Instant::now());
    }

    /// The cursor to give X for a client that has read up to `marker_ms`, when
    /// that is everything on the first page and X doesn't already know. X can
    /// only be told "read to the top", so a client that has read part of the
    /// page keeps that to itself until it reads the rest.
    fn cursor_to_push(&self, marker_ms: i64) -> Option<&str> {
        let cursor = self.top_cursor.as_deref()?;
        let newest = self.newest_ms?;
        if marker_ms < newest || self.x_marker_ms.is_some_and(|x| x >= newest) {
            return None;
        }
        Some(cursor)
    }
}

/// An instant as the ISO 8601 marker the iPhone app parses.
fn iso_marker(ms: i64) -> Option<String> {
    DateTime::from_timestamp_millis(ms).map(|t| t.to_rfc3339_opts(SecondsFormat::Millis, true))
}

/// Takes in a first page of notifications: remembers its newest time and top
/// cursor, and moves the shared marker up to X's.
pub async fn observe(state: &AppState, page: &NotificationPage) {
    state.notification_sync.lock().await.observe(page);
    if let Some(marker) = page.unread_after_ms.and_then(iso_marker) {
        state.seen.lock().await.set_notifications_marker(&marker);
    }
}

/// Fetches a first page when the last one is older than `within`. A failure
/// leaves things as they were: the shared marker is still good, just not
/// refreshed.
pub async fn refresh_if_stale(state: &AppState, within: Duration) {
    if state.notification_sync.lock().await.is_fresh(within) {
        return;
    }
    match whisper::fetch_notifications(&state.gql, None, 20).await {
        Ok(page) => observe(state, &page).await,
        Err(e) => tracing::debug!("notification marker refresh skipped: {e}"),
    }
}

/// Passes a client's read marker on to X when it covers the whole first page.
pub async fn push_seen(state: &AppState, marker: &str) {
    refresh_if_stale(state, PUSH_FRESH_FOR).await;
    let marker_ms = marker_millis(marker);
    let mut sync = state.notification_sync.lock().await;
    let Some(cursor) = sync.cursor_to_push(marker_ms).map(str::to_owned) else {
        return;
    };
    match whisper::mark_notifications_seen(&state.gql, &cursor).await {
        Ok(()) => {
            tracing::info!("notifications marked read on X");
            sync.x_marker_ms = sync.newest_ms;
        }
        Err(e) => tracing::warn!("could not mark notifications read on X: {e}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn synced(newest: i64, x_marker: Option<i64>) -> NotificationSync {
        NotificationSync {
            top_cursor: Some("TOP".into()),
            newest_ms: Some(newest),
            x_marker_ms: x_marker,
            fetched_at: Some(Instant::now()),
        }
    }

    #[test]
    fn a_full_read_goes_to_x() {
        assert_eq!(
            synced(5_000, Some(1_000)).cursor_to_push(5_000),
            Some("TOP")
        );
        assert_eq!(synced(5_000, None).cursor_to_push(9_000), Some("TOP"));
    }

    #[test]
    fn a_partial_read_stays_local() {
        assert_eq!(synced(5_000, Some(1_000)).cursor_to_push(4_999), None);
    }

    #[test]
    fn x_is_not_told_what_it_knows() {
        assert_eq!(synced(5_000, Some(5_000)).cursor_to_push(5_000), None);
        assert_eq!(synced(5_000, Some(5_400)).cursor_to_push(5_000), None);
    }

    #[test]
    fn nothing_is_pushed_before_a_page_was_seen() {
        assert_eq!(NotificationSync::default().cursor_to_push(5_000), None);
    }

    #[test]
    fn xs_marker_only_moves_forward() {
        let mut sync = synced(5_000, Some(4_000));
        sync.observe(&NotificationPage {
            unread_after_ms: Some(3_000),
            ..Default::default()
        });
        assert_eq!(sync.x_marker_ms, Some(4_000));
        sync.observe(&NotificationPage {
            unread_after_ms: Some(6_000),
            ..Default::default()
        });
        assert_eq!(sync.x_marker_ms, Some(6_000));
    }

    #[test]
    fn markers_are_written_the_way_the_app_reads_them() {
        let marker = iso_marker(1_791_121_401_034).unwrap();
        assert_eq!(marker, "2026-10-04T13:43:21.034Z");
        assert_eq!(marker_millis(&marker), 1_791_121_401_034);
    }
}
