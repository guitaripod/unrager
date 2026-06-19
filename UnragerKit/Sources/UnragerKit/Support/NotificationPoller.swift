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
/// Cost control: a single timer, a single in-flight request at a time (an
/// overlapping tick is skipped), and only the first page is fetched. Pausing
/// invalidates the timer entirely so nothing runs in the background unless the
/// host explicitly drives a one-shot `pollOnce`.
@MainActor
public final class NotificationPoller {
    /// Reports the current unread count (notifications newer than last-seen).
    public var onUnreadCount: ((Int) -> Void)?
    /// Reports notifications that appeared since the previous successful poll,
    /// newest first — the host turns these into banners (subject to prefs).
    public var onNewNotifications: (([XNotification]) -> Void)?

    private let api: APIClient
    private let cadence: TimeInterval
    private var timer: Timer?
    private var inFlight = false
    /// IDs observed on the most recent successful poll. Used to compute "what's
    /// new since last poll" without re-alerting on the whole page each tick.
    private var knownIDs: Set<String> = []
    /// True until the first successful poll establishes the baseline. The first
    /// poll seeds `knownIDs` without firing `onNewNotifications`, so the host
    /// isn't flooded with banners for the existing backlog on launch.
    private var primed = false

    public init(api: APIClient, cadence: TimeInterval = 15) {
        self.api = api
        self.cadence = cadence
    }

    /// Whether the repeating timer is currently scheduled.
    public var isRunning: Bool { timer != nil }

    /// Starts (or restarts) the repeating poll and fires one immediate tick so
    /// becoming-active feels live. No-op if already running.
    public func start() {
        guard timer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: cadence, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollOnce() }
        }
        timer.tolerance = cadence * 0.2
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

    /// Fetches one page now and reports results. Skipped if a fetch is already
    /// in flight (no overlap, no pile-up). Safe to call directly for a one-shot
    /// background poll without scheduling the timer.
    public func pollOnce() {
        guard !inFlight else { return }
        inFlight = true
        Task { [weak self] in
            await self?.poll()
        }
    }

    private func poll() async {
        defer { inFlight = false }
        let page: NotificationsPage
        do {
            page = try await api.notifications(cursor: nil)
        } catch {
            AppLogger.shared.warn("notification poll failed: \(error)", category: .api)
            return
        }
        let notifications = page.notifications
        let unread = NotificationPrefs.unreadCount(in: notifications)
        onUnreadCount?(unread)

        let pageIDs = Set(notifications.map(\.id))
        if primed {
            let fresh = notifications.filter { !knownIDs.contains($0.id) }
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
        knownIDs = pageIDs
    }
}
