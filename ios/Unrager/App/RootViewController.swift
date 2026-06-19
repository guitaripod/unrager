import UIKit

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
