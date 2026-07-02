//! The reusable timeline component backing Home / Following / User / Search /
//! Mentions / Bookmarks. Fetches a page, renders tweet cards into a `ListBox`,
//! and loads more on scroll-to-bottom.

use crate::card::{CardCallbacks, build_tweet_card};
use crate::shared::{Ctx, FetchGeneration, Route, empty_state, error_state, loading_state};
use adw::prelude::*;
use chrono::{DateTime, Duration, Utc};
use relm4::prelude::*;
use std::collections::HashSet;
use std::rc::Rc;
use std::sync::Arc;
use unrager_gtk_core::model::{FeedStatusResponse, SearchProduct, TimelinePage, Tweet};
use unrager_gtk_core::{ApiClient, ApiError, format};

#[derive(Debug, Clone)]
pub enum FeedSource {
    HomeForYou,
    Following,
    Search {
        query: String,
        product: SearchProduct,
    },
    Mentions,
    Bookmarks(String),
}

pub struct FeedInit {
    pub ctx: Ctx,
    pub source: FeedSource,
}

pub struct Feed {
    ctx: Ctx,
    source: FeedSource,
    originals: bool,
    list: gtk::ListBox,
    tweets: Vec<Tweet>,
    cursor: Option<String>,
    loading: bool,
    exhausted: bool,
    /// Bumped by every Reload so a result from an earlier fetch (e.g. a
    /// LoadMore in flight when the user toggled Originals) is recognized as
    /// stale and dropped instead of mixing modes.
    generation: FetchGeneration,
    /// A Reload arrived while a fetch was in flight; fire one fresh Reload when
    /// that fetch completes, so at most one fetch is ever in flight.
    reload_queued: bool,
    /// "updated Nm ago" for store-backed Home feeds; empty hides the label.
    freshness: String,
    /// Buffer ingest instant; re-deriving from it ticks the freshness label
    /// without re-fetching. `None` hides the label.
    freshness_anchor: Option<DateTime<Utc>>,
    /// Which rows have been displayed and which ids already reported, so a
    /// tweet is only marked seen once per component.
    seen: SeenTracker,
    /// Ids awaiting the next batched `POST /api/seen` flush.
    seen_pending: Vec<String>,
    seen_flush_scheduled: bool,
}

#[derive(Debug)]
pub enum FeedInput {
    Reload,
    /// Rebuild the cards from the already-loaded tweets without refetching —
    /// used when a display preference (e.g. media size) changes, so the feed
    /// updates instantly and doesn't reorder.
    Rebuild,
    LoadMore,
    RowActivated(i32),
    ToggleOriginals(bool),
    /// Re-derive the "updated Nm ago" label from `freshness_anchor` so it climbs
    /// live; fired by a 20s glib timer.
    TickFreshness,
    /// Rows up to this index have been displayed (scrolled into view); queue
    /// them for seen-marking on feeds that track reads.
    SeenUpTo(i32),
    /// Send the queued seen ids to the server in one batch; fired by a 1s
    /// debounce timer after the first enqueue.
    FlushSeen,
}

#[derive(Debug)]
pub enum FeedOutput {
    Open(Route),
}

#[derive(Debug)]
pub enum FeedCmd {
    Loaded {
        generation: u64,
        append: bool,
        page: Result<TimelinePage, ApiError>,
    },
    Status(Result<FeedStatusResponse, ApiError>),
}

#[relm4::component(pub)]
impl Component for Feed {
    type Init = FeedInit;
    type Input = FeedInput;
    type Output = FeedOutput;
    type CommandOutput = FeedCmd;

    view! {
        adw::ToolbarView {
            add_top_bar = &adw::HeaderBar {
                pack_start = &gtk::Button {
                    set_icon_name: "document-edit-symbolic",
                    set_tooltip_text: Some("Compose"),
                    connect_clicked[sender] => move |_| {
                        sender.output(FeedOutput::Open(Route::ComposeNew)).ok();
                    },
                },
                pack_end = &gtk::Button {
                    set_icon_name: "view-refresh-symbolic",
                    set_tooltip_text: Some("Refresh"),
                    connect_clicked => FeedInput::Reload,
                },
                #[name = "originals_toggle"]
                pack_end = &gtk::ToggleButton {
                    set_label: "Originals",
                    set_tooltip_text: Some("Hide replies, reposts and quotes"),
                    connect_toggled[sender] => move |toggle| {
                        sender.input(FeedInput::ToggleOriginals(toggle.is_active()));
                    },
                },
                pack_start = &gtk::Label {
                    add_css_class: "dim-label",
                    add_css_class: "caption",
                    set_margin_start: 4,
                    #[watch]
                    set_label: &model.freshness,
                    #[watch]
                    set_visible: !model.freshness.is_empty(),
                },
            },

            #[wrap(Some)]
            #[name = "scroller"]
            set_content = &gtk::ScrolledWindow {
                set_vexpand: true,
                set_hexpand: true,
                connect_edge_reached[sender] => move |_, pos| {
                    if pos == gtk::PositionType::Bottom {
                        sender.input(FeedInput::LoadMore);
                    }
                },

                adw::Clamp {
                    set_maximum_size: 640,
                    set_tightening_threshold: 560,

                    #[local_ref]
                    list_box -> gtk::ListBox {
                        connect_row_activated[sender] => move |_, row| {
                            sender.input(FeedInput::RowActivated(row.index()));
                        },
                    }
                }
            }
        }
    }

    fn init(
        init: Self::Init,
        root: Self::Root,
        sender: ComponentSender<Self>,
    ) -> ComponentParts<Self> {
        let list = gtk::ListBox::new();
        list.set_selection_mode(gtk::SelectionMode::None);
        list.add_css_class("feed-list");
        list.set_placeholder(Some(&loading_state()));

        let is_home = matches!(init.source, FeedSource::HomeForYou | FeedSource::Following);

        let model = Feed {
            ctx: init.ctx,
            source: init.source,
            originals: false,
            list: list.clone(),
            tweets: Vec::new(),
            cursor: None,
            loading: false,
            exhausted: false,
            generation: FetchGeneration::default(),
            reload_queued: false,
            freshness: String::new(),
            freshness_anchor: None,
            seen: SeenTracker::default(),
            seen_pending: Vec::new(),
            seen_flush_scheduled: false,
        };

        let list_box = &list;
        let widgets = view_output!();
        widgets.originals_toggle.set_visible(is_home);
        if model.tracks_seen() {
            install_seen_reporter(&widgets.scroller, &list, sender.input_sender().clone());
        }
        if is_home {
            let tick = sender.input_sender().clone();
            gtk::glib::timeout_add_seconds_local(20, move || {
                if tick.send(FeedInput::TickFreshness).is_err() {
                    gtk::glib::ControlFlow::Break
                } else {
                    gtk::glib::ControlFlow::Continue
                }
            });
        }
        sender.input(FeedInput::Reload);
        ComponentParts { model, widgets }
    }

    fn update(&mut self, message: Self::Input, sender: ComponentSender<Self>, _root: &Self::Root) {
        match message {
            FeedInput::Reload => {
                self.generation.bump();
                self.list.set_placeholder(Some(&loading_state()));
                if self.loading {
                    self.reload_queued = true;
                    return;
                }
                self.spawn_reload(&sender);
            }
            FeedInput::Rebuild => {
                clear(&self.list);
                let callbacks = self.callbacks(&sender);
                for tweet in &self.tweets {
                    self.list
                        .append(&build_tweet_card(tweet, &self.ctx, &callbacks));
                }
            }
            FeedInput::LoadMore => {
                if self.loading || self.exhausted {
                    return;
                }
                let Some(cursor) = self.cursor.clone() else {
                    return;
                };
                self.loading = true;
                let api = self.ctx.api.clone();
                let source = self.source.clone();
                let originals = self.originals;
                let generation = self.generation.current();
                sender.oneshot_command(async move {
                    FeedCmd::Loaded {
                        generation,
                        append: true,
                        page: fetch(api, source, originals, Some(cursor)).await,
                    }
                });
            }
            FeedInput::RowActivated(index) => {
                if let Some(tweet) = self.tweets.get(index as usize) {
                    sender
                        .output(FeedOutput::Open(Route::Thread(tweet.rest_id.clone())))
                        .ok();
                }
            }
            FeedInput::ToggleOriginals(on) => {
                if self.originals != on {
                    self.originals = on;
                    sender.input(FeedInput::Reload);
                }
            }
            FeedInput::TickFreshness => self.refresh_freshness_label(),
            FeedInput::SeenUpTo(index) => {
                if let Ok(last_visible) = usize::try_from(index) {
                    self.enqueue_seen(last_visible, &sender);
                }
            }
            FeedInput::FlushSeen => self.flush_seen(),
        }
    }

    fn update_cmd(
        &mut self,
        message: Self::CommandOutput,
        sender: ComponentSender<Self>,
        _root: &Self::Root,
    ) {
        match message {
            FeedCmd::Loaded {
                generation,
                append,
                page,
            } => {
                self.loading = false;
                if self.reload_queued {
                    self.reload_queued = false;
                    self.spawn_reload(&sender);
                    return;
                }
                if !self.generation.is_current(generation) {
                    return;
                }
                match page {
                    Ok(page) => {
                        if !append {
                            clear(&self.list);
                            self.tweets.clear();
                            self.seen.reset_window();
                        }
                        let callbacks = self.callbacks(&sender);
                        for tweet in &page.tweets {
                            let card = build_tweet_card(tweet, &self.ctx, &callbacks);
                            self.list.append(&card);
                            self.tweets.push(tweet.clone());
                        }
                        self.cursor = page.cursor;
                        self.exhausted = self.cursor.is_none();
                        if self.tweets.is_empty() {
                            self.list.set_placeholder(Some(&empty_state(
                                "feed-symbolic",
                                "Nothing to show",
                            )));
                        }
                        // After a fresh load of a store-backed Home feed, fetch
                        // how stale the buffer is for the "updated Nm ago" label.
                        if !append && self.variant_key().is_some() {
                            let api = self.ctx.api.clone();
                            sender.oneshot_command(async move {
                                FeedCmd::Status(api.feed_status().await)
                            });
                        }
                    }
                    Err(error) => {
                        let message = error.user_message();
                        if self.tweets.is_empty() {
                            let retry = sender.clone();
                            self.list
                                .set_placeholder(Some(&error_state(&message, move || {
                                    retry.input(FeedInput::Reload)
                                })));
                        } else {
                            sender.output(FeedOutput::Open(Route::Toast(message))).ok();
                        }
                    }
                }
            }
            FeedCmd::Status(result) => {
                self.freshness_anchor = match (&result, self.variant_key()) {
                    (Ok(status), Some(key)) => status
                        .feeds
                        .iter()
                        .find(|f| f.variant == key)
                        .filter(|f| f.age_secs >= 0)
                        .map(|f| Utc::now() - Duration::seconds(f.age_secs)),
                    _ => None,
                };
                self.refresh_freshness_label();
            }
        }
    }
}

impl Feed {
    /// Spawns the single in-flight fresh-page fetch, reading the source and
    /// Originals mode from `self` at fire time — so a Reload queued behind an
    /// in-flight fetch picks up any toggle that happened in between.
    fn spawn_reload(&mut self, sender: &ComponentSender<Self>) {
        self.loading = true;
        let api = self.ctx.api.clone();
        let source = self.source.clone();
        let originals = self.originals;
        let generation = self.generation.current();
        sender.oneshot_command(async move {
            FeedCmd::Loaded {
                generation,
                append: false,
                page: fetch(api, source, originals, None).await,
            }
        });
    }

    /// Re-derives "updated Nm ago" from the buffer's ingest instant so the label
    /// climbs live between loads; empty (hidden) when there's no anchor.
    fn refresh_freshness_label(&mut self) {
        self.freshness = match self.freshness_anchor {
            Some(anchor) => {
                let age = (Utc::now() - anchor).num_seconds().max(0);
                format::freshness_label(age).unwrap_or_default()
            }
            None => String::new(),
        };
    }

    /// The `feed.db` source key for this feed's freshness, or `None` for
    /// non-Home sources (which have no materialized buffer).
    fn variant_key(&self) -> Option<&'static str> {
        match self.source {
            FeedSource::HomeForYou => Some("home_foryou"),
            FeedSource::Following => Some("home_following"),
            _ => None,
        }
    }

    /// Whether this source supports server-side read tracking, matching the
    /// iOS client: the Following home feed and Mentions.
    fn tracks_seen(&self) -> bool {
        matches!(self.source, FeedSource::Following | FeedSource::Mentions)
    }

    /// Queues the not-yet-reported tweets among the first `last_visible + 1`
    /// rows for a batched mark-seen, honoring the "Track seen tweets" switch,
    /// and arms the debounced flush timer on the first enqueue.
    fn enqueue_seen(&mut self, last_visible: usize, sender: &ComponentSender<Self>) {
        if !self.tracks_seen() || !self.ctx.track_seen.get() {
            return;
        }
        let fresh = self
            .seen
            .newly_displayed(self.tweets.iter().map(|t| t.rest_id.as_str()), last_visible);
        if fresh.is_empty() {
            return;
        }
        self.seen_pending.extend(fresh);
        if !self.seen_flush_scheduled {
            self.seen_flush_scheduled = true;
            let flush = sender.input_sender().clone();
            gtk::glib::timeout_add_seconds_local_once(1, move || {
                let _ = flush.send(FeedInput::FlushSeen);
            });
        }
    }

    /// Reports the queued ids to `POST /api/seen` in one batch, off the main
    /// loop; failures are logged and dropped like the iOS client.
    fn flush_seen(&mut self) {
        self.seen_flush_scheduled = false;
        let batch = std::mem::take(&mut self.seen_pending);
        if batch.is_empty() {
            return;
        }
        let api = self.ctx.api.clone();
        relm4::spawn(async move {
            match api.mark_seen(&batch).await {
                Ok(_) => {
                    tracing::debug!(target: "feed", "marked {} tweets seen", batch.len());
                }
                Err(error) => {
                    tracing::warn!(target: "feed", "mark_seen failed: {error}");
                }
            }
        });
    }

    fn callbacks(&self, sender: &ComponentSender<Self>) -> CardCallbacks {
        let profile_sender = sender.clone();
        let media_sender = sender.clone();
        let toast_sender = sender.clone();
        CardCallbacks {
            open_profile: Rc::new(move |handle| {
                profile_sender
                    .output(FeedOutput::Open(Route::Profile(handle)))
                    .ok();
            }),
            open_media: Rc::new(move |tweet_id, items, start| {
                media_sender
                    .output(FeedOutput::Open(Route::Media {
                        tweet_id,
                        items,
                        start,
                    }))
                    .ok();
            }),
            toast: Rc::new(move |message| {
                toast_sender
                    .output(FeedOutput::Open(Route::Toast(message)))
                    .ok();
            }),
        }
    }
}

fn clear(list: &gtk::ListBox) {
    while let Some(child) = list.first_child() {
        list.remove(&child);
    }
}

/// Reports the last displayed row whenever the viewport scrolls or the content
/// grows (the adjustment's `changed` fires after rows are added and laid out,
/// covering the initial page that is visible without any scrolling) — the GTK
/// analog of `willDisplay` driving `enqueueSeen` on iOS.
fn install_seen_reporter(
    scroller: &gtk::ScrolledWindow,
    list: &gtk::ListBox,
    sender: relm4::Sender<FeedInput>,
) {
    let adjustment = scroller.vadjustment();
    let report = {
        let list = list.clone();
        move |adjustment: &gtk::Adjustment| {
            if let Some(last_visible) = last_displayed_index(&list, adjustment) {
                let _ = sender.send(FeedInput::SeenUpTo(last_visible));
            }
        }
    };
    adjustment.connect_value_changed(report.clone());
    adjustment.connect_changed(report);
}

/// The index of the last row at or above the viewport bottom, or `None` when it
/// can't be determined from allocated geometry. Never synthesizes "everything
/// displayed" from a failed probe: `row_at_y` (and a row's bounds) come from
/// allocation state, and the adjustment emits synchronously *before* freshly
/// appended rows are allocated (clamps during a rebuild, kinetic frame-clock
/// ticks racing a LoadMore append) — the post-allocation `changed` emission
/// delivers the authoritative index. The genuine end-of-list case resolves the
/// last row explicitly and only trusts it when its allocated bounds actually
/// end above the viewport bottom.
fn last_displayed_index(list: &gtk::ListBox, adjustment: &gtk::Adjustment) -> Option<i32> {
    const EPSILON: f64 = 1.0;
    let bottom = adjustment.value() + adjustment.page_size();
    if let Some(row) = list.row_at_y(bottom as i32) {
        return Some(row.index());
    }
    if bottom + EPSILON < adjustment.upper() {
        return None;
    }
    let row = list.last_child().and_downcast::<gtk::ListBoxRow>()?;
    let bounds = row.compute_bounds(list)?;
    let row_bottom = f64::from(bounds.y() + bounds.height());
    (bounds.height() > 0.0 && row_bottom <= bottom + EPSILON).then(|| row.index())
}

/// Tracks which rows have been displayed for seen-marking: a monotonic
/// high-water mark over row indexes (so a stale or repeated report at or below
/// the mark is dropped and each report only scans rows past it, not the whole
/// prefix) plus the set of ids already reported (so a tweet that reappears
/// after a reload isn't reported twice).
#[derive(Debug, Default)]
struct SeenTracker {
    sent: HashSet<String>,
    high_water: usize,
}

impl SeenTracker {
    /// The not-yet-reported ids among rows `high_water..=last_visible`, marking
    /// everything scanned as covered. Rows at or below the mark contribute
    /// nothing.
    fn newly_displayed<'a>(
        &mut self,
        ids: impl Iterator<Item = &'a str>,
        last_visible: usize,
    ) -> Vec<String> {
        if last_visible < self.high_water {
            return Vec::new();
        }
        let window = (last_visible - self.high_water).saturating_add(1);
        let mut fresh = Vec::new();
        for id in ids.skip(self.high_water).take(window) {
            self.high_water += 1;
            if self.sent.insert(id.to_string()) {
                fresh.push(id.to_string());
            }
        }
        fresh
    }

    /// Resets the positional mark for freshly replaced content (a reload);
    /// already-reported ids stay deduplicated.
    fn reset_window(&mut self) {
        self.high_water = 0;
    }
}

async fn fetch(
    api: Arc<ApiClient>,
    source: FeedSource,
    originals: bool,
    cursor: Option<String>,
) -> Result<TimelinePage, ApiError> {
    let cursor = cursor.as_deref();
    match source {
        FeedSource::HomeForYou => api.home(false, originals, cursor, None).await,
        FeedSource::Following => api.home(true, originals, cursor, None).await,
        FeedSource::Search { query, product } => api.search(&query, product, cursor, None).await,
        FeedSource::Mentions => api.mentions(cursor, None).await,
        FeedSource::Bookmarks(query) => api.bookmarks(&query, cursor, None).await,
    }
}

#[cfg(test)]
mod tests {
    use super::SeenTracker;

    fn ids<'a>(items: &'a [&str]) -> impl Iterator<Item = &'a str> {
        items.iter().copied()
    }

    #[test]
    fn takes_rows_up_to_and_including_the_last_visible() {
        let mut tracker = SeenTracker::default();
        let fresh = tracker.newly_displayed(ids(&["a", "b", "c", "d"]), 1);
        assert_eq!(fresh, vec!["a".to_string(), "b".to_string()]);
    }

    #[test]
    fn skips_ids_already_sent() {
        let mut tracker = SeenTracker::default();
        tracker.newly_displayed(ids(&["a", "c"]), 1);
        tracker.reset_window();
        let fresh = tracker.newly_displayed(ids(&["a", "b", "c"]), 2);
        assert_eq!(fresh, vec!["b".to_string()]);
    }

    #[test]
    fn last_visible_past_the_end_covers_everything() {
        let mut tracker = SeenTracker::default();
        let fresh = tracker.newly_displayed(ids(&["a", "b"]), usize::MAX);
        assert_eq!(fresh, vec!["a".to_string(), "b".to_string()]);
    }

    #[test]
    fn empty_feed_yields_nothing() {
        let mut tracker = SeenTracker::default();
        let fresh = tracker.newly_displayed(ids(&[]), usize::MAX);
        assert!(fresh.is_empty());
    }

    #[test]
    fn reports_at_or_below_the_high_water_mark_are_dropped() {
        let mut tracker = SeenTracker::default();
        tracker.newly_displayed(ids(&["a", "b", "c"]), 2);
        let stale = tracker.newly_displayed(ids(&["a", "b", "c"]), 1);
        assert!(stale.is_empty());
        let repeat = tracker.newly_displayed(ids(&["a", "b", "c"]), 2);
        assert!(repeat.is_empty());
    }

    #[test]
    fn scans_start_from_the_mark_not_index_zero() {
        let mut tracker = SeenTracker::default();
        tracker.newly_displayed(ids(&["a", "b", "c", "d"]), 1);
        let fresh = tracker.newly_displayed(ids(&["a", "b", "c", "d"]), 3);
        assert_eq!(fresh, vec!["c".to_string(), "d".to_string()]);
    }

    #[test]
    fn the_mark_stops_at_the_end_of_the_list_and_covers_later_appends() {
        let mut tracker = SeenTracker::default();
        tracker.newly_displayed(ids(&["a", "b"]), 5);
        let fresh = tracker.newly_displayed(ids(&["a", "b", "c", "d"]), 2);
        assert_eq!(fresh, vec!["c".to_string()]);
    }

    #[test]
    fn reset_window_rescans_positions_but_not_reported_ids() {
        let mut tracker = SeenTracker::default();
        tracker.newly_displayed(ids(&["a", "b"]), 1);
        tracker.reset_window();
        let fresh = tracker.newly_displayed(ids(&["b", "x", "a"]), 2);
        assert_eq!(fresh, vec!["x".to_string()]);
    }
}
