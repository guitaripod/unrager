import UIKit
import UnragerKit

/// Root tab bar built from the user's chosen tabs (up to five, ordered, edited
/// in Settings → Edit Tabs). Each tab is its own navigation stack; bars keep
/// default backgrounds so iOS 26 gives them Liquid Glass automatically, and the
/// bar minimizes on scroll-down.
final class RootViewController: UITabBarController {
    override var childForStatusBarStyle: UIViewController? { selectedViewController }

    private var selectedTabs: [TabItem] = []
    /// Timestamp of the last re-tap on the active Home tab; a second re-tap
    /// within the window is treated as a double-tap and toggles For You ↔
    /// Following.
    private var lastHomeReselect: TimeInterval = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
        rebuildTabs()
        tabBarMinimizeBehavior = .onScrollDown
        NotificationCenter.default.addObserver(
            self, selector: #selector(serverChanged), name: AppSettings.serverURLDidChange, object: nil)
    }

    /// A new server has its own filter setting: ask it, and drop timelines
    /// saved from the old one.
    @objc private func serverChanged() {
        TimelineCache.shared.clearAll()
        SessionSync.restore()
    }

    /// Rebuilds the tab bar from `ClientSettings.tabs`, keeping the stack of
    /// every tab that survives the edit (scroll position, pushed screens) and
    /// the selected tab when it does.
    func rebuildTabs() {
        let previouslySelected = selectedTabs.indices.contains(selectedIndex) ? selectedTabs[selectedIndex] : nil
        let existing = Dictionary(
            uniqueKeysWithValues: zip(selectedTabs, viewControllers ?? []).map { ($0, $1) })
        selectedTabs = ClientSettings.tabs
        viewControllers = selectedTabs.map { existing[$0] ?? $0.makeViewController() }
        if let previouslySelected, let index = selectedTabs.firstIndex(of: previouslySelected) {
            selectedIndex = index
        }
    }

    // MARK: - Hardware keyboard

    override var keyCommands: [UIKeyCommand]? {
        [
            command("n", title: "New Tweet", action: #selector(newTweetCommand)),
            command("r", title: "Refresh", action: #selector(refreshCommand)),
            command("f", title: "Search", action: #selector(searchCommand)),
        ]
    }

    private func command(_ input: String, title: String, action: Selector) -> UIKeyCommand {
        let command = UIKeyCommand(title: title, action: action, input: input, modifierFlags: .command)
        command.wantsPriorityOverSystemBehavior = true
        return command
    }

    @objc private func newTweetCommand() {
        guard presentedViewController == nil else { return }
        let compose = ComposeViewController(mode: .new)
        present(UINavigationController(rootViewController: compose), animated: true)
    }

    @objc private func refreshCommand() {
        if let nav = selectedViewController as? UINavigationController,
           let feed = nav.topViewController as? FeedViewController {
            feed.viewModel.refresh()
        }
    }

    @objc private func searchCommand() {
        guard presentedViewController == nil, let index = selectedTabs.firstIndex(of: .search) else { return }
        selectedIndex = index
        let nav = viewControllers?[index] as? UINavigationController
        nav?.popToRootViewController(animated: false)
        (nav?.viewControllers.first as? SearchViewController)?.focusSearchField()
    }

    // MARK: - Notifications tab

    private var notificationsTabIndex: Int? {
        selectedTabs.firstIndex(of: .notifications)
    }

    /// Whether the user's tab bar carries Notifications. Without it the unread
    /// count has no list to clear it, so it isn't tracked on the app icon.
    var hasNotificationsTab: Bool { notificationsTabIndex != nil }

    /// Sets the live unread badge on the Notifications tab item (nil clears it).
    /// No-op when the Notifications tab isn't in the user's bar — the count is
    /// still tracked, just nowhere to show it. While there is unread activity
    /// the bar stays put instead of minimizing on scroll, so the indicator is
    /// never scrolled out of sight; minimizing resumes once the badge clears.
    func setNotificationsBadge(_ value: String?) {
        guard let index = notificationsTabIndex,
              let item = (viewControllers?[index] as? UINavigationController)?.tabBarItem
                ?? viewControllers?[index].tabBarItem else { return }
        item.badgeColor = DesignSystem.Color.badge
        item.badgeValue = value
        tabBarMinimizeBehavior = value == nil ? .onScrollDown : .never
    }

    private weak var activeToast: NotificationToast?

    /// Drops an in-app Liquid Glass toast for freshly-arrived notifications while
    /// the app is foregrounded, on the window so it shows above an open sheet. A single item shows who-did-what + the snippet; a
    /// batch coalesces into a count. Tapping deep-links into the activity.
    func showNotificationToast(_ notifications: [XNotification]) {
        guard let first = notifications.first else { return }
        activeToast?.dismiss()
        let content = notifications.count > 1
            ? NotificationsViewController.toastSummary(count: notifications.count)
            : NotificationsViewController.toastContent(for: first)
        let toast = NotificationToast(badge: content.badge, title: content.title, subtitle: content.subtitle) {
            [weak self] in self?.handleToastTap(notifications)
        }
        activeToast = toast
        toast.present(in: view.window ?? view)
    }

    private func handleToastTap(_ notifications: [XNotification]) {
        guard notifications.count == 1, let notif = notifications.first else {
            showNotificationsTab()
            return
        }
        NotificationCenterService.shared.markSeen(notif)
        if let tweetID = notif.targetTweetID {
            openInNotificationsStack(ThreadViewController(tweetID: tweetID))
        } else if let handle = notif.actors.first?.handle {
            openInNotificationsStack(ProfileViewController(handle: handle))
        } else {
            showNotificationsTab()
        }
    }

    /// Switches to the Notifications tab at its root — where a tapped summary
    /// banner lands — or, without that tab, pushes the list onto the stack in
    /// front.
    func showNotificationsTab() {
        afterClosingSheets { [weak self] in
            guard let self else { return }
            guard let index = self.notificationsTabIndex else {
                (self.selectedViewController as? UINavigationController)?
                    .pushViewController(NotificationsViewController(), animated: true)
                return
            }
            self.selectedIndex = index
            (self.viewControllers?[index] as? UINavigationController)?.popToRootViewController(animated: false)
        }
    }

    /// Pushes a view controller onto the Notifications tab's stack — used to
    /// deep-link a tapped banner or toast — or, without that tab, onto the
    /// stack in front, leaving what the user was reading underneath.
    func openInNotificationsStack(_ controller: UIViewController) {
        afterClosingSheets { [weak self] in
            guard let self else { return }
            guard let index = self.notificationsTabIndex else {
                (self.selectedViewController as? UINavigationController)?.pushViewController(controller, animated: true)
                return
            }
            self.selectedIndex = index
            guard let nav = self.viewControllers?[index] as? UINavigationController else { return }
            nav.popToRootViewController(animated: false)
            nav.pushViewController(controller, animated: true)
        }
    }

    // MARK: - Routing past sheets

    /// A route held back by a sheet that can't be closed for it (a composer
    /// with a draft), run once that sheet is dismissed.
    private var pendingRoute: (() -> Void)?

    /// Runs `route` where the user can see it: at once when nothing is
    /// presented, after closing the sheets when something is, and once the
    /// sheet closes on its own when it holds unsaved work.
    private func afterClosingSheets(_ route: @escaping () -> Void) {
        guard let presented = presentedViewController else {
            pendingRoute = nil
            route()
            return
        }
        if Self.holdsUnsavedWork(presented) {
            pendingRoute = route
            return
        }
        pendingRoute = nil
        dismiss(animated: true, completion: route)
    }

    /// Whether any sheet in the chain refuses to be swiped away, which is how
    /// the composer marks a draft.
    private static func holdsUnsavedWork(_ presented: UIViewController) -> Bool {
        var controller: UIViewController? = presented
        while let current = controller {
            if current.isModalInPresentation
                || (current as? UINavigationController)?.topViewController?.isModalInPresentation == true {
                return true
            }
            controller = current.presentedViewController
        }
        return false
    }

    /// A sheet closing (its own Cancel or Post goes through here) releases a
    /// route it held back.
    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        super.dismiss(animated: flag) { [weak self] in
            completion?()
            guard let self, self.presentedViewController == nil, let route = self.pendingRoute else { return }
            self.pendingRoute = nil
            route()
        }
    }
}

extension RootViewController: UITabBarControllerDelegate {
    /// Detects a double-tap on the already-selected Home tab (two re-taps within
    /// a short window) and toggles its feed mode. Re-tapping any other tab — or
    /// the Home tab when it isn't at its root — is left to default behavior.
    func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
        guard viewController === selectedViewController,
              let nav = viewController as? UINavigationController,
              nav.viewControllers.count == 1,
              let home = nav.viewControllers.first as? HomeViewController else {
            lastHomeReselect = 0
            return true
        }
        let now = Date().timeIntervalSinceReferenceDate
        if now - lastHomeReselect < 0.45 {
            home.toggleFeedMode()
            lastHomeReselect = 0
        } else {
            lastHomeReselect = now
        }
        return true
    }
}
