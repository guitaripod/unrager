import AppKit
import UnragerKit
import UserNotifications

/// The macOS notification hub. Owns the foreground `NotificationPoller`, drives
/// the Dock-tile (and sidebar) unread badge, and — when the user opts in — posts
/// local banners for new activity via `UNUserNotificationCenter`.
///
/// NO PUSH SERVER: there is no APNs. Delivery is the foreground poller, so
/// banners are reliable only while the app is running and never arrive when it's
/// quit. The unread badge is always tracked; banners are opt-in. macOS has no
/// `BGAppRefreshTask` equivalent here — the poller simply pauses on resign and
/// resumes on activate.
@MainActor
final class NotificationCenterService: NSObject {
    static let shared = NotificationCenterService()

    /// Reports the current unread count so the window can badge its sidebar row.
    var onUnreadCount: ((Int) -> Void)?
    /// Routes a tapped banner; the window controller opens the thread/profile.
    var onOpenTweet: ((String) -> Void)?
    var onOpenProfile: ((String) -> Void)?

    private let poller = NotificationPoller(api: AppEnvironment.shared.api)
    private var unreadCount = 0
    private var observersInstalled = false

    private override init() {
        super.init()
        poller.onUnreadCount = { [weak self] count in self?.setUnreadCount(count) }
        poller.onNewNotifications = { [weak self] new in self?.deliver(new) }
    }

    // MARK: - Wiring

    /// Registers the notification delegate, installs lifecycle observers, and
    /// starts the poller. Called once from `applicationDidFinishLaunching`.
    func start() {
        UNUserNotificationCenter.current().delegate = self
        installLifecycleObserversIfNeeded()
        setUnreadCount(0)
        poller.start()
    }

    private func installLifecycleObserversIfNeeded() {
        guard !observersInstalled else { return }
        observersInstalled = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(appBecameActive),
                           name: NSApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(appResignedActive),
                           name: NSApplication.didResignActiveNotification, object: nil)
    }

    @objc private func appBecameActive() {
        poller.resetDiffBaseline()
        poller.start()
    }

    @objc private func appResignedActive() {
        poller.pause()
    }

    // MARK: - Badge

    private func setUnreadCount(_ count: Int) {
        unreadCount = count
        NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
        onUnreadCount?(count)
    }

    /// Marks all fetched activity seen — up to the newest the poller has pulled,
    /// the authoritative head of feed, rather than whatever page a view happened
    /// to load — and clears the badge. Called when the Notifications source is
    /// viewed.
    func markNotificationsSeen() {
        poller.markCurrentSeen()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    // MARK: - Permission

    /// Requests alert/sound/badge authorization — triggered by the Settings
    /// master toggle, never unprompted. Returns whether banners can be shown.
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

    /// Posts banners for new activity, honoring the master + per-type toggles, and
    /// coalescing into a summary when several arrive at once.
    private func deliver(_ notifications: [XNotification]) {
        guard NotificationPrefs.bannersEnabled, !notifications.isEmpty else { return }
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
            let copy = NotificationsViewController.bannerCopy(for: notif)
            content.title = copy.title
            content.body = copy.body
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

    private func handleTap(tweetID: String?, handle: String?) {
        NSApp.activate(ignoringOtherApps: true)
        if let tweetID {
            onOpenTweet?(tweetID)
        } else if let handle {
            onOpenProfile?(handle)
        }
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
