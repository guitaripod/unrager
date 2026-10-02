import Foundation

/// A foreground poller for X activity. While running, it fetches the first page
/// of notifications every `cadence` seconds, diffs against the last poll, and
/// reports (a) the unread count relative to `NotificationPrefs`' last-seen
/// marker and (b) any notifications that are brand-new since the previous poll.
///
/// NO PUSH SERVER: there is no APNs. This is the only delivery mechanism, so it
/// is reliable only while the app is active and best-effort during a short
/// background refresh. Notifications will NOT arrive when the app is fully
/// terminated — that is expected and not a bug.
///
/// Cross-client sync: when the server supports `/api/notifications/seen`, the
/// poller adopts the server marker on every poll (reading on another device
/// clears the badge here) and `pushSeenMarker` writes the local marker back.
/// A `.notFound` from an older server disables sync for the session; local
/// UserDefaults tracking keeps working unchanged.
///
/// Cost control: a single timer, a single in-flight request at a time (an
/// overlapping tick is skipped), and only the first page is fetched. Pausing
/// invalidates the timer entirely so nothing runs in the background unless the
/// host explicitly drives a one-shot `poll()`.
@MainActor
public final class NotificationPoller {
    /// Where cross-client seen-marker sync stands, for a diagnostics screen.
    public enum SeenSyncState: Sendable, Equatable {
        /// Not tried yet with this server, or no seen API was given.
        case unknown
        /// The last exchange with `/api/notifications/seen` succeeded.
        case ok
        /// The server predates the endpoint; tracking is local only until the
        /// server address changes.
        case unsupported
        /// The last exchange failed for another reason; the next poll retries.
        case failed
    }

    /// Reports the current unread count (notifications newer than last-seen).
    public var onUnreadCount: ((Int) -> Void)?
    /// Reports notifications that appeared since the previous successful poll,
    /// newest first — the host turns these into banners (subject to prefs).
    public var onNewNotifications: (([XNotification]) -> Void)?

    private let api: APIClient
    private let seenAPI: NotificationSeenAPI?
    private let cadence: TimeInterval
    private var timer: Timer?
    private var inFlight = false
    /// IDs observed on the most recent successful poll, each with the newest
    /// timestamp seen for it. Used to compute "what's new since last poll"
    /// without re-alerting on the whole page each tick. A grouped notification
    /// keeps its id while X folds more people into it and moves its timestamp
    /// forward, so a newer timestamp under a known id is news too.
    private var knownIDs: [String: Date] = [:]
    /// True until the first successful poll establishes the baseline. The first
    /// poll seeds `knownIDs` without firing `onNewNotifications`, so the host
    /// isn't flooded with banners for the existing backlog on launch.
    private var primed = false
    /// Whether the server understands `/api/notifications/seen`, and how the
    /// last exchange went. Unknown until the first probe; a 404 latches it to
    /// `.unsupported` until the server address changes, so an old server isn't
    /// hammered with doomed requests.
    public private(set) var seenSyncState: SeenSyncState = .unknown
    /// When the last poll finished, successfully or not.
    public private(set) var lastPollAt: Date?
    /// Why the last poll failed, or nil when it succeeded.
    public private(set) var lastPollError: String?
    nonisolated(unsafe) private var serverObserver: (any NSObjectProtocol)?
    /// The newest notification (by timestamp) the poller has fetched — the
    /// authoritative "newest the app has seen", used to mark seen so the badge
    /// can't be re-lit by a head-of-feed item the viewer never loaded.
    public private(set) var latestFetched: XNotification?
    /// The full page from the most recent successful poll, for hosts that need
    /// to diff against the persisted seen marker (e.g. a background refresh).
    public private(set) var lastPage: [XNotification] = []

    public init(api: APIClient, seenAPI: NotificationSeenAPI? = nil, cadence: TimeInterval = 15) {
        self.api = api
        self.seenAPI = seenAPI
        self.cadence = cadence
        serverObserver = NotificationCenter.default.addObserver(
            forName: AppSettings.serverURLDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.serverURLChanged() }
        }
    }

    deinit {
        if let serverObserver { NotificationCenter.default.removeObserver(serverObserver) }
    }

    /// Whether the repeating timer is currently scheduled.
    public var isRunning: Bool { timer != nil }

    /// Starts (or restarts) the repeating poll and fires one immediate tick so
    /// becoming-active feels live. The timer is added in `.common` run-loop mode
    /// so it keeps firing while the user scrolls (touch tracking parks
    /// default-mode timers). No-op if already running.
    public func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: cadence, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollOnce() }
        }
        timer.tolerance = cadence * 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        AppLogger.shared.info("notification poller started · cadence=\(cadence)s", category: .api)
        pollOnce()
    }

    /// Stops the repeating poll. Any in-flight request is allowed to finish but
    /// won't reschedule. Called when the app resigns active.
    public func pause() {
        guard timer != nil else { return }
        timer?.invalidate()
        timer = nil
        AppLogger.shared.info("notification poller paused", category: .api)
    }

    /// Resets the per-poll diff baseline so the next poll re-primes without
    /// alerting on the existing backlog. Useful after a long background gap.
    public func resetDiffBaseline() {
        primed = false
        knownIDs.removeAll()
    }

    /// Forgets everything learned from the previous server: whether it
    /// supports the seen marker, the diff baseline (so the new server's
    /// backlog isn't announced as news) and the last page. Runs on its own when
    /// `AppSettings.serverURLDidChange` is posted.
    public func serverChanged() {
        seenSyncState = .unknown
        resetDiffBaseline()
        lastPage = []
        latestFetched = nil
        lastPollError = nil
        AppLogger.shared.info("notification poller reset for a new server", category: .api)
    }

    private func serverURLChanged() {
        serverChanged()
        if isRunning { pollOnce() }
    }

    /// Marks everything fetched so far as seen — up to the newest notification the
    /// poller has pulled (the authoritative head of feed) — pushes the marker to
    /// the server, and reports a cleared badge. The explicit "mark all read"
    /// action; robust against the viewer and the poller having loaded slightly
    /// different pages.
    public func markCurrentSeen() {
        NotificationPrefs.markSeen(upTo: latestFetched)
        pushSeenMarker()
        onUnreadCount?(0)
    }

    /// Marks a single notification (and everything at/older than it) seen —
    /// the "tapping a row reads it" action — then pushes the marker and
    /// reports the recomputed unread count from the last fetched page.
    public func markSeen(_ notification: XNotification) {
        guard NotificationPrefs.markSeen(timestamp: notification.timestamp, id: notification.id)
        else { return }
        pushSeenMarker()
        onUnreadCount?(NotificationPrefs.unreadCount(in: lastPage))
    }

    /// Fires a poll without awaiting it. Skipped if a fetch is already in
    /// flight (no overlap, no pile-up).
    public func pollOnce() {
        Task { [weak self] in
            await self?.poll()
        }
    }

    /// Fetches one page now, updates state, and reports results. Returns
    /// whether the fetch actually completed — a background refresh awaits this
    /// and reports task success from it instead of sleeping blind. Skipped
    /// (returning false) if a fetch is already in flight.
    @discardableResult
    public func poll() async -> Bool {
        guard !inFlight else { return false }
        inFlight = true
        defer { inFlight = false }
        let page: NotificationsPage
        do {
            page = try await api.notifications(cursor: nil)
        } catch where error.isCancellation {
            AppLogger.shared.debug("notification poll cancelled", category: .api)
            return false
        } catch {
            AppLogger.shared.warn("notification poll failed: \(error)", category: .api)
            lastPollAt = Date()
            lastPollError = error.localizedDescription
            return false
        }
        lastPollAt = Date()
        lastPollError = nil
        let notifications = page.notifications
        lastPage = notifications
        latestFetched = notifications.max { $0.timestamp < $1.timestamp }
        await adoptServerSeenMarker()
        establishBaselineIfNeeded(notifications)
        let unread = NotificationPrefs.unreadCount(in: notifications)
        onUnreadCount?(unread)

        let known = knownIDs
        knownIDs = Dictionary(notifications.map { ($0.id, $0.timestamp) }, uniquingKeysWith: max)
        if primed {
            let fresh = notifications.filter { isFresh($0, known: known) && isUnread($0) }
            if !fresh.isEmpty {
                AppLogger.shared.info(
                    "notification poll: \(fresh.count) new, \(unread) unread", category: .api)
                onNewNotifications?(fresh)
            }
        } else {
            primed = true
            AppLogger.shared.info(
                "notification poll primed: \(notifications.count) items, \(unread) unread",
                category: .api)
        }
        return true
    }

    /// Whether the previous poll didn't hold this notification, or held it at
    /// an older timestamp (a group that grew).
    private func isFresh(_ notification: XNotification, known: [String: Date]) -> Bool {
        guard let previous = known[notification.id] else { return true }
        return NotificationPrefs.isNewer(notification.timestamp, than: previous)
    }

    /// Whether a notification is newer than the seen marker. One the marker
    /// already covers — read on another device, or an old item that merely
    /// moved back onto the first page — is not news, whatever the previous poll
    /// held.
    private func isUnread(_ notification: XNotification) -> Bool {
        guard let marker = NotificationPrefs.lastSeenTimestamp else { return true }
        return NotificationPrefs.isNewer(notification.timestamp, than: marker)
    }

    /// Fresh-install semantics: with no local (or adoptable server) marker, the
    /// first successful poll baselines last-seen to the newest fetched item —
    /// no badge storm for the pre-existing backlog, but the unread clock starts
    /// immediately, so genuinely-new activity badges without requiring a tab
    /// visit first.
    private func establishBaselineIfNeeded(_ notifications: [XNotification]) {
        guard NotificationPrefs.lastSeenTimestamp == nil else { return }
        guard NotificationPrefs.markSeen(in: notifications) else { return }
        pushSeenMarker()
        AppLogger.shared.info("notification baseline established (fresh install)", category: .api)
    }

    /// Reads the server-side seen marker and advances the local one if the
    /// server's is newer (monotonic — a lagging server can't re-light cleared
    /// badges). A 404 marks the endpoint unsupported for the session.
    private func adoptServerSeenMarker() async {
        guard let seenAPI, seenSyncState != .unsupported else { return }
        do {
            let marker = try await seenAPI.fetch()
            seenSyncState = .ok
            if let timestamp = marker.timestamp,
               NotificationPrefs.markSeen(timestamp: timestamp) {
                AppLogger.shared.info("adopted server seen marker: \(timestamp)", category: .api)
            }
        } catch APIError.notFound {
            seenSyncState = .unsupported
            AppLogger.shared.info("server lacks /api/notifications/seen · local-only", category: .api)
        } catch where error.isCancellation {
            return
        } catch {
            seenSyncState = .failed
            AppLogger.shared.debug("seen marker fetch failed: \(error)", category: .api)
        }
    }

    /// Fire-and-forget write of the local seen marker to the server, so other
    /// clients of the same account clear their badges too. No-op when the
    /// server predates the endpoint.
    public func pushSeenMarker() {
        guard let seenAPI, seenSyncState != .unsupported,
              let timestamp = NotificationPrefs.lastSeenTimestamp else { return }
        Task { [weak self] in
            do {
                try await seenAPI.update(NotificationSeenMarker(timestamp: timestamp))
                self?.seenSyncState = .ok
            } catch APIError.notFound {
                self?.seenSyncState = .unsupported
            } catch where error.isCancellation {
                return
            } catch {
                self?.seenSyncState = .failed
                AppLogger.shared.debug("seen marker push failed: \(error)", category: .api)
            }
        }
    }
}
