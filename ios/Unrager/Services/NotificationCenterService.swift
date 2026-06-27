import BackgroundTasks
import UIKit
import UnragerKit
import UserNotifications

/// The iOS notification hub. Owns the foreground `NotificationPoller`, drives the
/// Notifications-tab unread badge, and — when the user opts in — posts local
/// banners for new activity via `UNUserNotificationCenter`.
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

    private let poller = NotificationPoller(api: AppEnvironment.shared.api)
    private weak var root: RootViewController?
    private var unreadCount = 0
    private var observersInstalled = false

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
    /// once from the scene's `willConnectTo`.
    func attach(to root: RootViewController) {
        self.root = root
        installLifecycleObserversIfNeeded()
        root.setNotificationsBadge(nil)
        start()
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

    private func setUnreadCount(_ count: Int) {
        unreadCount = count
        root?.setNotificationsBadge(count > 0 ? String(count) : nil)
    }

    /// Advances the last-seen marker to the newest of the supplied notifications
    /// and clears the badge. Called when the Notifications tab is actually viewed.
    func markNotificationsSeen(in notifications: [XNotification]) {
        NotificationPrefs.markSeen(in: notifications)
        setUnreadCount(0)
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
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

    /// Surfaces new activity. While the app is foregrounded this is an in-app
    /// Liquid Glass toast (no notification permission needed); backgrounded it
    /// falls back to a system banner, honoring the master + per-type toggles and
    /// coalescing into a summary when several arrive at once.
    private func deliver(_ notifications: [XNotification]) {
        guard !notifications.isEmpty else { return }

        if UIApplication.shared.applicationState == .active {
            root?.showNotificationToast(notifications)
            return
        }

        guard NotificationPrefs.bannersEnabled else { return }
        let allowed = notifications.filter { NotificationPrefs.shouldBanner(rawType: $0.type) }
        guard !allowed.isEmpty else { return }

        Task { @MainActor in
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            let status = settings.authorizationStatus
            guard status == .authorized || status == .provisional else { return }
            self.postBanners(allowed)
        }
    }

    private func postBanners(_ allowed: [XNotification]) {
        let center = UNUserNotificationCenter.current()
        if allowed.count > 3 {
            let content = UNMutableNotificationContent()
            content.title = "New activity"
            content.body = "\(allowed.count) new notifications on X."
            content.sound = .default
            content.userInfo = ["kind": "summary"]
            center.add(UNNotificationRequest(identifier: "unrager.summary.\(UUID().uuidString)",
                                             content: content, trigger: nil))
            return
        }
        for notif in allowed {
            let content = UNMutableNotificationContent()
            let style = NotificationsViewController.bannerCopy(for: notif)
            content.title = style.title
            content.body = style.body
            content.sound = .default
            content.userInfo = userInfo(for: notif)
            center.add(UNNotificationRequest(identifier: "unrager.\(notif.id)",
                                             content: content, trigger: nil))
        }
    }

    private func userInfo(for notif: XNotification) -> [String: String] {
        var info: [String: String] = [:]
        if let tweetID = notif.targetTweetID {
            info["tweetID"] = tweetID
        } else if let handle = notif.actors.first?.handle {
            info["handle"] = handle
        }
        return info
    }

    // MARK: - Deep linking

    /// Routes a tapped banner to the relevant thread or profile, switching to the
    /// Notifications tab first so the navigation lands in a sensible stack.
    private func handleTap(tweetID: String?, handle: String?) {
        guard let root else { return }
        if let tweetID {
            root.openInNotificationsStack(ThreadViewController(tweetID: tweetID))
        } else if let handle {
            root.openInNotificationsStack(ProfileViewController(handle: handle))
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

    /// One-shot background poll: fetch once, post banners for anything new, then
    /// finish promptly. Re-arms the next refresh. Deliberately minimal — this is
    /// a best-effort top-up, not a guarantee.
    private func runBackgroundRefresh(_ task: BGAppRefreshTask) {
        scheduleBackgroundRefresh()
        let work = Task { @MainActor in
            poller.resetDiffBaseline()
            poller.pollOnce()
            try? await Task.sleep(nanoseconds: 5 * NSEC_PER_SEC)
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
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
