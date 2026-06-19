import UIKit

/// Root tab bar built from the user's chosen tabs (up to five, ordered, edited
/// in Settings → Edit Tabs). Each tab is its own navigation stack; bars keep
/// default backgrounds so iOS 26 gives them Liquid Glass automatically, and the
/// bar minimizes on scroll-down.
final class RootViewController: UITabBarController {
    private var selectedTabs: [TabItem] = []

    override func viewDidLoad() {
        super.viewDidLoad()
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
