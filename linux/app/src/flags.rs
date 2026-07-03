//! Session-scoped country-flag resolution for tweet authors, the GTK peer of
//! the TUI's `about_store`/`about_fetch` pair. `GET /api/about/{rest_id}`
//! answers with the server-derived flag emoji and "based in" country; this
//! module lazily resolves each unique author as cards are built, coalesces
//! concurrent interest in the same author into one request, runs requests
//! strictly one at a time (the server single-flights upstream anyway), caches
//! `resolved`/`none` answers for the app session, and retries `deferred`
//! answers no sooner than 60 seconds later.

use gtk::glib;
use std::cell::RefCell;
use std::collections::{HashMap, HashSet, VecDeque};
use std::rc::Rc;
use std::sync::Arc;
use std::time::Duration;
use unrager_gtk_core::ApiClient;
use unrager_gtk_core::model::{AboutStatus, AboutView};

const RETRY_DELAY: Duration = Duration::from_secs(60);

/// The session-cached answer for one author: the flag emoji and the raw
/// country name, both absent when the user has no about-profile or no
/// country set.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct AboutInfo {
    pub flag: Option<String>,
    pub based_in: Option<String>,
}

impl AboutInfo {
    fn from_view(view: AboutView) -> Self {
        Self {
            flag: view.flag,
            based_in: view.profile.and_then(|p| p.account_based_in),
        }
    }
}

type Waiter = Box<dyn Fn(&AboutInfo)>;

#[derive(Debug, Clone, PartialEq)]
struct Job {
    rest_id: String,
    screen_name: String,
}

enum Outcome {
    Settled(AboutInfo),
    Deferred,
}

/// Resolves author flags against the API, owned by [`crate::shared::Ctx`].
/// Clones share one cache and one request pipeline; everything runs on the
/// main GTK thread except the HTTP call itself.
#[derive(Clone)]
pub struct FlagResolver {
    api: Arc<ApiClient>,
    state: Rc<RefCell<ResolverState>>,
}

impl FlagResolver {
    pub fn new(api: Arc<ApiClient>) -> Self {
        Self {
            api,
            state: Rc::new(RefCell::new(ResolverState::default())),
        }
    }

    /// Requests the author's flag info. `waiter` fires exactly once with the
    /// session-cached or freshly fetched answer — synchronously on a cache
    /// hit, later on the main loop otherwise. It is never called for an
    /// author whose fetch stays deferred, so hold only weak widget
    /// references inside it.
    pub fn resolve(&self, rest_id: &str, screen_name: &str, waiter: impl Fn(&AboutInfo) + 'static) {
        let cached = self.state.borrow().lookup(rest_id);
        if let Some(info) = cached {
            waiter(&info);
            return;
        }
        self.state
            .borrow_mut()
            .enqueue(rest_id, screen_name, Box::new(waiter));
        self.pump();
    }

    fn pump(&self) {
        let Some(job) = self.state.borrow_mut().next_job() else {
            return;
        };
        let api = self.api.clone();
        let request = job.clone();
        let (tx, rx) = tokio::sync::oneshot::channel::<Outcome>();
        relm4::spawn(async move {
            let outcome = match api.about(&request.rest_id, &request.screen_name).await {
                Ok(view) if view.status != AboutStatus::Deferred => {
                    Outcome::Settled(AboutInfo::from_view(view))
                }
                Ok(_) => Outcome::Deferred,
                Err(error) => {
                    tracing::debug!(target: "flags", "about fetch failed for @{}: {error}", request.screen_name);
                    Outcome::Deferred
                }
            };
            let _ = tx.send(outcome);
        });
        let resolver = self.clone();
        glib::spawn_future_local(async move {
            let outcome = rx.await.unwrap_or(Outcome::Deferred);
            resolver.complete(job, outcome);
        });
    }

    fn complete(&self, job: Job, outcome: Outcome) {
        match outcome {
            Outcome::Settled(info) => {
                let (info, waiters) = self.state.borrow_mut().settle(&job.rest_id, info);
                for waiter in waiters {
                    waiter(&info);
                }
            }
            Outcome::Deferred => {
                self.state.borrow_mut().defer(&job.rest_id);
                let resolver = self.clone();
                glib::timeout_add_local_once(RETRY_DELAY, move || {
                    if resolver.state.borrow_mut().retry_due(job) {
                        resolver.pump();
                    }
                });
            }
        }
        self.pump();
    }
}

/// The pure bookkeeping behind [`FlagResolver`]: cache, per-author waiter
/// lists, the FIFO of jobs to run, and the single-flight latch. Split from
/// the IO driver so the coalescing/sequencing/backoff rules are unit-testable
/// without a GTK main loop.
#[derive(Default)]
struct ResolverState {
    cache: HashMap<String, Rc<AboutInfo>>,
    waiters: HashMap<String, Vec<Waiter>>,
    queue: VecDeque<Job>,
    tracked: HashSet<String>,
    in_flight: bool,
}

impl ResolverState {
    fn lookup(&self, rest_id: &str) -> Option<Rc<AboutInfo>> {
        self.cache.get(rest_id).cloned()
    }

    /// Registers interest in an author. Queues a job only when the author is
    /// not already queued, in flight, or waiting out a deferral.
    fn enqueue(&mut self, rest_id: &str, screen_name: &str, waiter: Waiter) {
        self.waiters
            .entry(rest_id.to_string())
            .or_default()
            .push(waiter);
        if self.tracked.insert(rest_id.to_string()) {
            self.queue.push_back(Job {
                rest_id: rest_id.to_string(),
                screen_name: screen_name.to_string(),
            });
        }
    }

    /// Hands out the next job unless one is already in flight.
    fn next_job(&mut self) -> Option<Job> {
        if self.in_flight {
            return None;
        }
        let job = self.queue.pop_front()?;
        self.in_flight = true;
        Some(job)
    }

    /// Records a `resolved`/`none` answer and releases the author's waiters
    /// for the driver to invoke outside the borrow.
    fn settle(&mut self, rest_id: &str, info: AboutInfo) -> (Rc<AboutInfo>, Vec<Waiter>) {
        self.in_flight = false;
        self.tracked.remove(rest_id);
        let info = Rc::new(info);
        self.cache.insert(rest_id.to_string(), info.clone());
        (info, self.waiters.remove(rest_id).unwrap_or_default())
    }

    /// Records a deferral: waiters stay registered and the author stays
    /// tracked so re-resolves coalesce onto the pending retry instead of
    /// hammering the server.
    fn defer(&mut self, rest_id: &str) {
        self.in_flight = false;
        debug_assert!(self.tracked.contains(rest_id));
    }

    /// A deferral's backoff elapsed: requeues the job if anyone still waits
    /// on it, otherwise forgets the author so the next resolve starts fresh.
    fn retry_due(&mut self, job: Job) -> bool {
        if self.cache.contains_key(&job.rest_id) || !self.tracked.contains(&job.rest_id) {
            return false;
        }
        if self.waiters.get(&job.rest_id).is_none_or(Vec::is_empty) {
            self.tracked.remove(&job.rest_id);
            self.waiters.remove(&job.rest_id);
            return false;
        }
        self.queue.push_back(job);
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;

    fn info(flag: &str, country: &str) -> AboutInfo {
        AboutInfo {
            flag: Some(flag.to_string()),
            based_in: Some(country.to_string()),
        }
    }

    fn counting_waiter() -> (Waiter, Rc<Cell<u32>>) {
        let calls = Rc::new(Cell::new(0));
        let seen = calls.clone();
        (Box::new(move |_| seen.set(seen.get() + 1)), calls)
    }

    #[test]
    fn one_job_per_author_no_matter_how_many_waiters() {
        let mut state = ResolverState::default();
        let (first, _) = counting_waiter();
        let (second, _) = counting_waiter();
        state.enqueue("1", "a", first);
        state.enqueue("1", "a", second);
        assert_eq!(state.queue.len(), 1);
    }

    #[test]
    fn settle_caches_and_releases_every_waiter_once() {
        let mut state = ResolverState::default();
        let (first, first_calls) = counting_waiter();
        let (second, second_calls) = counting_waiter();
        state.enqueue("1", "a", first);
        state.enqueue("1", "a", second);
        state.next_job().unwrap();

        let (settled, waiters) = state.settle("1", info("🇺🇸", "United States"));
        assert_eq!(waiters.len(), 2);
        for waiter in waiters {
            waiter(&settled);
        }
        assert_eq!(first_calls.get(), 1);
        assert_eq!(second_calls.get(), 1);
        assert_eq!(state.lookup("1").as_deref(), Some(settled.as_ref()));
        assert!(state.waiters.is_empty());
    }

    #[test]
    fn a_none_answer_is_cached_for_the_session() {
        let mut state = ResolverState::default();
        let (waiter, _) = counting_waiter();
        state.enqueue("1", "a", waiter);
        state.next_job().unwrap();
        state.settle("1", AboutInfo::default());
        assert_eq!(state.lookup("1").as_deref(), Some(&AboutInfo::default()));
        assert!(state.queue.is_empty());
    }

    #[test]
    fn jobs_run_strictly_one_at_a_time() {
        let mut state = ResolverState::default();
        let (first, _) = counting_waiter();
        let (second, _) = counting_waiter();
        state.enqueue("1", "a", first);
        state.enqueue("2", "b", second);

        let job = state.next_job().unwrap();
        assert_eq!(job.rest_id, "1");
        assert!(state.next_job().is_none(), "second job waits for the first");

        state.settle("1", AboutInfo::default());
        assert_eq!(state.next_job().unwrap().rest_id, "2");
    }

    #[test]
    fn deferred_keeps_waiters_and_coalesces_new_interest_onto_the_retry() {
        let mut state = ResolverState::default();
        let (first, first_calls) = counting_waiter();
        state.enqueue("1", "a", first);
        let job = state.next_job().unwrap();
        state.defer("1");

        assert!(state.lookup("1").is_none(), "deferred is never cached");
        let (late, _) = counting_waiter();
        state.enqueue("1", "a", late);
        assert!(
            state.queue.is_empty(),
            "new interest waits for the pending retry"
        );

        assert!(state.retry_due(job));
        let rerun = state.next_job().unwrap();
        assert_eq!(rerun.rest_id, "1");
        let (settled, waiters) = state.settle("1", info("🇫🇮", "Finland"));
        assert_eq!(waiters.len(), 2);
        for waiter in waiters {
            waiter(&settled);
        }
        assert_eq!(first_calls.get(), 1);
    }

    #[test]
    fn retry_is_dropped_once_the_author_is_settled() {
        let mut state = ResolverState::default();
        let (waiter, _) = counting_waiter();
        state.enqueue("1", "a", waiter);
        let job = state.next_job().unwrap();
        state.settle("1", info("🇯🇵", "Japan"));
        assert!(!state.retry_due(job));
        assert!(state.queue.is_empty());
    }

    #[test]
    fn about_info_derives_from_the_wire_view() {
        let resolved = AboutView::resolved(
            unrager_gtk_core::model::AboutProfile {
                rest_id: "1".to_string(),
                handle: "a".to_string(),
                name: "A".to_string(),
                account_based_in: Some("Finland".to_string()),
                location_accurate: None,
                source: None,
                username_changes: None,
                affiliate_username: None,
                created_at: None,
                is_blue_verified: false,
                verified: false,
                verified_since: None,
            },
            Some("FI".to_string()),
            Some("🇫🇮".to_string()),
        );
        assert_eq!(AboutInfo::from_view(resolved), info("🇫🇮", "Finland"));
        assert_eq!(
            AboutInfo::from_view(AboutView::none()),
            AboutInfo::default()
        );
    }
}
