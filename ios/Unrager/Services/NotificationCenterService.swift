import BackgroundTasks
import UIKit
import UnragerKit
import UserNotifications

/// The iOS notification hub. Owns the foreground `NotificationPoller`, drives the
/// Notifications-tab unread badge (and the app icon badge), and — when the user
/// opts in — posts local banners for new activity via `UNUserNotificationCenter`.
///
/// NO PUSH SERVER: there is no APNs. Delivery is the foreground poller plus a
/// short `BGAppRefreshTask`, so banners are reliable while the app is active,
/// best-effort in the background, and never arrive when the app is fully
/// terminated. The unread badge is always tracked; banners are opt-in.
@MainActor
final class NotificationCenterService: NSObject {
    static let shared = NotificationCenterService()

    /// The identifier registered for the best-effort background refresh. Must
    /// match the `BGTaskSchedulerPermittedIdentifiers` entry in Info.plist
    /// (see `ios/project.yml`).
    static let backgroundTaskID = "com.guitaripod.unrager.refresh"

    private let poller = NotificationPoller(
        api: AppEnvironment.shared.api,
        seenAPI: NotificationSeenAPI(baseURL: { AppSettings.serverURL }))
    private weak var root: RootViewController?
    private var unreadCount = 0
    private var observersInstalled = false
    /// A banner tap that arrived before `attach(to:)` wired the root (cold
    /// launch from a notification); replayed once the tab bar exists.
    private var pendingTap: BannerRoute?

    private override init() {
        super.init()
        poller.onUnreadCount = { [weak self] count in self?.setUnreadCount(count) }
        poller.onNewNotifications = { [weak self] new in self?.deliver(new) }
    }

    // MARK: - Wiring

    /// Registers the background-refresh handler and the notification delegate.
    /// Must run during `application(_:didFinishLaunchingWithOptions:)` —
    /// `BGTaskScheduler.register` has to be called before launch completes.
    func registerLaunchHandlers() {
        UNUserNotificationCenter.current().delegate = self
        registerBackgroundTask()
    }

    /// Wires the service to the live root tab bar and starts the poller. Called
    /// once from the scene's `willConnectTo`. Replays a banner tap that landed
    /// during cold launch, before the root existed.
    func attach(to root: RootViewController) {
        self.root = root
        installLifecycleObserversIfNeeded()
        root.setNotificationsBadge(nil)
        start()
        if let pendingTap {
            self.pendingTap = nil
            route(pendingTap)
        }
    }

    private func installLifecycleObserversIfNeeded() {
        guard !observersInstalled else { return }
        observersInstalled = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(appBecameActive),
                           name: UIApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(appResignedActive),
                           name: UIApplication.willResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(appEnteredBackground),
                           name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    // MARK: - Lifecycle

    private func start() { poller.start() }

    @objc private func appBecameActive() {
        poller.resetDiffBaseline()
        poller.start()
    }

    @objc private func appResignedActive() {
        poller.pause()
    }

    @objc private func appEnteredBackground() {
        scheduleBackgroundRefresh()
    }

    // MARK: - Badge

    /// True while the Notifications tab is the front-most view. The badge is
    /// pinned to zero the whole time it's up — the list itself is the unread
    /// surface — but the seen marker only advances for items the list actually
    /// rendered (`notificationsDisplayed`), never silently from a poll.
    private var isViewingNotifications = false

    /// The Notifications list's hook for fresh activity arriving while it is
    /// front-most: the poller's new items are handed to the list to render
    /// (which then reports them displayed), instead of being toasted over it.
    var onVisibleFresh: (([XNotification]) -> Void)?

    private func setUnreadCount(_ count: Int) {
        if isViewingNotifications {
            unreadCount = 0
            root?.setNotificationsBadge(nil)
            mirrorIconBadge(0)
            return
        }
        unreadCount = count
        root?.setNotificationsBadge(badgeText(for: count))
        mirrorIconBadge(count)
    }

    /// The tab-badge string: nil at zero; "N+" when every item on the poller's
    /// page is unread (the true count may extend past the fetched page).
    private func badgeText(for count: Int) -> String? {
        guard count > 0 else { return nil }
        let pageSize = poller.lastPage.count
        return pageSize > 0 && count >= pageSize ? "\(count)+" : "\(count)"
    }

    /// Mirrors the unread count onto the app icon (badge authorization is
    /// requested with the master toggle; the call is a no-op without it).
    private func mirrorIconBadge(_ count: Int) {
        UNUserNotificationCenter.current().setBadgeCount(count)
    }

    /// The Notifications list reports the items it actually rendered; the seen
    /// marker advances to the newest of them (and syncs to the server), so a
    /// stale poller page can't re-light the badge for rows the user just read —
    /// and a poll can never consume activity the list hasn't shown.
    func notificationsDisplayed(_ notifications: [XNotification]) {
        guard !notifications.isEmpty else { return }
        if NotificationPrefs.markSeen(in: notifications) {
            poller.pushSeenMarker()
        }
        clearDeliveredState()
    }

    /// Marks everything fetched so far as seen — the newest the poller has
    /// pulled and whatever the list displayed — and clears every badge. The
    /// explicit "Mark all read" action.
    func markAllSeen(displayed: [XNotification] = []) {
        NotificationPrefs.markSeen(in: displayed)
        poller.markCurrentSeen()
        clearDeliveredState()
    }

    private func clearDeliveredState() {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        if isViewingNotifications {
            root?.setNotificationsBadge(nil)
            mirrorIconBadge(0)
        }
    }

    /// Driven by the Notifications view as it comes forward / goes away. While
    /// visible the badge stays 0 and fresh activity flows through
    /// `onVisibleFresh`; the marker advances only via `notificationsDisplayed`.
    func setViewingNotifications(_ viewing: Bool) {
        isViewingNotifications = viewing
        if viewing {
            root?.setNotificationsBadge(nil)
            mirrorIconBadge(0)
        }
    }

    // MARK: - Permission

    /// Requests alert/sound/badge authorization. Triggered when the user enables
    /// the master toggle in Settings — never unprompted at launch. Returns whether
    /// banners can actually be shown.
    func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            AppLogger.shared.warn("notification auth error: \(error)", category: .app)
            return false
        }
    }

    // MARK: - Delivery

    /// Surfaces new activity. When the Notifications list is front-most the
    /// items feed straight into it (no toast over the surface that shows them);
    /// otherwise a foregrounded app gets an in-app Liquid Glass toast filtered
    /// through the per-kind mute toggles, and a backgrounded app falls back to
    /// system banners honoring the master + per-type toggles.
    private func deliver(_ notifications: [XNotification]) {
        guard !notifications.isEmpty else { return }

        if UIApplication.shared.applicationState == .active {
            if isViewingNotifications, let onVisibleFresh {
                onVisibleFresh(notifications)
                return
            }
            let toastable = notifications.filter { NotificationPrefs.shouldToast(rawType: $0.type) }
            if !toastable.isEmpty {
                NotificationPrefs.recordDeliveredBanners(ids: toastable.map(\.id))
                root?.showNotificationToast(toastable)
            }
            return
        }

        postBannersIfAuthorized(notifications.filter { NotificationPrefs.shouldBanner(rawType: $0.type) })
    }

    /// Records the delivered-banner ids **synchronously** — before the async
    /// authorization probe — so a second delivery path (the background
    /// seen-marker diff) computing its own `fresh` set can never re-alert the
    /// same events the moment before this batch finishes posting. The
    /// "never alerted twice" contract depends on the recording being atomic
    /// with respect to the enqueue, not deferred inside `postBanners`.
    private func postBannersIfAuthorized(_ notifications: [XNotification]) {
        guard NotificationPrefs.bannersEnabled else { return }
        let fresh = notifications.filter { !NotificationPrefs.hasDeliveredBanner(id: $0.id) }
        guard !fresh.isEmpty else { return }
        NotificationPrefs.recordDeliveredBanners(ids: fresh.map(\.id))
        Task { @MainActor in
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            let status = settings.authorizationStatus
            guard status == .authorized || status == .provisional else { return }
            self.postBanners(fresh)
        }
    }

    private func postBanners(_ allowed: [XNotification]) {
        let center = UNUserNotificationCenter.current()
        let quiet = NotificationPrefs.isQuietHours()
        if allowed.count > 3 {
            let content = UNMutableNotificationContent()
            content.title = "New activity"
            content.body = "\(allowed.count) new notifications on X."
            content.userInfo = ["kind": "summary"]
            applyDeliveryStyle(to: content, passive: quiet)
            center.add(UNNotificationRequest(identifier: "unrager.summary.\(UUID().uuidString)",
                                             content: content, trigger: nil))
            return
        }
        for notif in allowed {
            let content = UNMutableNotificationContent()
            let style = NotificationsViewController.bannerCopy(for: notif)
            content.title = style.title
            content.body = style.body
            content.userInfo = userInfo(for: notif)
            let passive = quiet || (NotificationKind.from(rawType: notif.type)?.isPassiveDelivery ?? false)
            applyDeliveryStyle(to: content, passive: passive)
            center.add(UNNotificationRequest(identifier: "unrager.\(notif.id)",
                                             content: content, trigger: nil))
        }
    }

    /// Sound + interruption level in one place: passive deliveries (quiet
    /// hours, likes/reposts) land silently in the list; active ones sound only
    /// when the user hasn't switched banner sound off.
    private func applyDeliveryStyle(to content: UNMutableNotificationContent, passive: Bool) {
        if passive {
            content.sound = nil
            content.interruptionLevel = .passive
        } else {
            content.sound = NotificationPrefs.bannerSoundEnabled ? .default : nil
            content.interruptionLevel = .active
        }
    }

    private func userInfo(for notif: XNotification) -> [String: String] {
        var info: [String: String] = ["kind": "single"]
        if let tweetID = notif.targetTweetID {
            info["tweetID"] = tweetID
        } else if let handle = notif.actors.first?.handle {
            info["handle"] = handle
        }
        return info
    }

    // MARK: - Deep linking

    private struct BannerRoute {
        let tweetID: String?
        let handle: String?
    }

    /// Routes a tapped banner: a thread or profile when the banner carried one,
    /// else (summary banners, actor-less types) the Notifications tab. Buffered
    /// until `attach(to:)` when the tap arrives during cold launch.
    private func handleTap(tweetID: String?, handle: String?) {
        let target = BannerRoute(tweetID: tweetID, handle: handle)
        guard root != nil else {
            pendingTap = target
            return
        }
        route(target)
    }

    private func route(_ target: BannerRoute) {
        guard let root else { return }
        if let tweetID = target.tweetID {
            root.openInNotificationsStack(ThreadViewController(tweetID: tweetID))
        } else if let handle = target.handle {
            root.openInNotificationsStack(ProfileViewController(handle: handle))
        } else {
            root.showNotificationsTab()
        }
    }

    // MARK: - Background refresh

    private func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.backgroundTaskID, using: nil) { [weak self] task in
            guard let refresh = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            Task { @MainActor in self?.runBackgroundRefresh(refresh) }
        }
    }

    /// Schedules a single best-effort refresh ~15 minutes out (the system decides
    /// the real cadence). Re-armed each time the app backgrounds.
    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            AppLogger.shared.warn("bg refresh submit failed: \(error)", category: .app)
        }
    }

    /// One-shot background poll: await one fetch, banner everything newer than
    /// the persisted seen marker (deduped against already-posted banners), and
    /// report task success from whether the fetch actually completed — no blind
    /// sleep, no baseline reset that would swallow the diff. Re-arms the next
    /// refresh. Deliberately minimal — a best-effort top-up, not a guarantee.
    private func runBackgroundRefresh(_ task: BGAppRefreshTask) {
        scheduleBackgroundRefresh()
        let work = Task { @MainActor in
            let fetched = await poller.poll()
            if fetched { bannerNewSinceSeenMarker() }
            task.setTaskCompleted(success: fetched)
        }
        task.expirationHandler = { work.cancel() }
    }

    /// Banners for everything on the freshly-polled page that is newer than the
    /// durable seen marker — the background counterpart of the foreground diff,
    /// which can't work across process death. Badge counts were already updated
    /// by the poll itself via `onUnreadCount`.
    private func bannerNewSinceSeenMarker() {
        guard let marker = NotificationPrefs.lastSeenTimestamp else { return }
        let unseen = poller.lastPage.filter {
            $0.timestamp > marker && NotificationPrefs.shouldBanner(rawType: $0.type)
        }
        postBannersIfAuthorized(unseen)
    }
}

extension NotificationCenterService: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        let tweetID = userInfo["tweetID"] as? String
        let handle = userInfo["handle"] as? String
        await MainActor.run { self.handleTap(tweetID: tweetID, handle: handle) }
    }
}
