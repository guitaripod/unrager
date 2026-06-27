import UIKit
import UnragerKit

/// Root tab bar built from the user's chosen tabs (up to five, ordered, edited
/// in Settings → Edit Tabs). Each tab is its own navigation stack; bars keep
/// default backgrounds so iOS 26 gives them Liquid Glass automatically, and the
/// bar minimizes on scroll-down.
final class RootViewController: UITabBarController {
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
    }

    /// Rebuilds the tab bar from `ClientSettings.tabs`, preserving the selected
    /// tab kind across an edit when it survives the new selection.
    func rebuildTabs() {
        let previouslySelected = selectedTabs.indices.contains(selectedIndex) ? selectedTabs[selectedIndex] : nil
        selectedTabs = ClientSettings.tabs
        viewControllers = selectedTabs.map { $0.makeViewController() }
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
        guard let index = selectedTabs.firstIndex(of: .search) else { return }
        selectedIndex = index
    }

    // MARK: - Notifications tab

    private var notificationsTabIndex: Int? {
        selectedTabs.firstIndex(of: .notifications)
    }

    /// Sets the live unread badge on the Notifications tab item (nil clears it).
    /// No-op when the Notifications tab isn't in the user's bar — the count is
    /// still tracked, just nowhere to show it.
    func setNotificationsBadge(_ value: String?) {
        guard let index = notificationsTabIndex,
              let item = (viewControllers?[index] as? UINavigationController)?.tabBarItem
                ?? viewControllers?[index].tabBarItem else { return }
        item.badgeValue = value
        // Keep the bar — and its unread badge — from minimizing away while there's
        // unread activity, so the indicator stays visible as you scroll the feed.
        // Minimize-on-scroll resumes once the badge clears.
        tabBarMinimizeBehavior = value == nil ? .onScrollDown : .never
    }

    private weak var activeToast: NotificationToast?

    /// Drops an in-app Liquid Glass toast for freshly-arrived notifications while
    /// the app is foregrounded. A single item shows who-did-what + the snippet; a
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
        toast.present(in: view)
    }

    private func handleToastTap(_ notifications: [XNotification]) {
        guard notifications.count == 1, let notif = notifications.first else {
            if let index = notificationsTabIndex { selectedIndex = index }
            return
        }
        if let tweetID = notif.targetTweetID {
            openInNotificationsStack(ThreadViewController(tweetID: tweetID))
        } else if let handle = notif.actors.first?.handle {
            openInNotificationsStack(ProfileViewController(handle: handle))
        } else if let index = notificationsTabIndex {
            selectedIndex = index
        }
    }

    /// Switches to the Notifications tab (or Home as a fallback) and pushes a
    /// view controller onto that stack — used to deep-link a tapped banner.
    func openInNotificationsStack(_ controller: UIViewController) {
        let index = notificationsTabIndex ?? 0
        selectedIndex = index
        guard let nav = viewControllers?[index] as? UINavigationController else { return }
        nav.popToRootViewController(animated: false)
        nav.pushViewController(controller, animated: true)
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
