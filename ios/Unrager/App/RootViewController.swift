import UIKit
import UnragerKit

/// The root of the app: the user's chosen tabs (up to five, ordered, edited in
/// Settings → Edit Tabs), each its own navigation stack, and the routing that
/// puts a tapped post, a notification or a deep link where the reader can see
/// it. The chrome around the tabs is the platform's: the native bar on iPhone,
/// a rail on a landscape iPad window and a floating bar on a portrait or narrow
/// one, with a second column beside the list when there is room for one.
///
/// Routing, badges, toasts and the hardware keyboard live here rather than in
/// either chrome, so both behave the same and the commands have one home.
final class RootViewController: UIViewController {
    override var childForStatusBarStyle: UIViewController? { selectedViewController }

    private var selectedTabs: [TabItem] = []
    private var stacks: [UIViewController] = []
    private var currentIndex = 0

    private var phoneChrome: PhoneTabsController?
    private var padChrome: PadTabsController?
    /// Timestamp of the last re-tap on the active Home tab; a second re-tap
    /// within the window is treated as a double-tap and toggles For You ↔
    /// Following.
    private var lastHomeReselect: TimeInterval = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = DesignSystem.Color.background
        installChrome()
        rebuildTabs()
        NotificationCenter.default.addObserver(
            self, selector: #selector(serverChanged), name: AppSettings.serverURLDidChange, object: nil)
    }

    // MARK: - Tabs

    /// Each tab's navigation stack, in bar order.
    var viewControllers: [UIViewController]? { stacks }

    /// The tab showing. Setting it is the same switch the bar makes.
    var selectedIndex: Int {
        get { currentIndex }
        set {
            guard newValue != currentIndex, stacks.indices.contains(newValue) else { return }
            currentIndex = newValue
            phoneChrome?.selectedIndex = newValue
            padChrome?.select(newValue)
            refreshWindowTitle()
        }
    }

    var selectedViewController: UIViewController? {
        stacks.indices.contains(currentIndex) ? stacks[currentIndex] : nil
    }

    /// The iPad's two-column shape reports which screens open beside the list;
    /// the phone stacks everything on top of everything.
    private var usesPadChrome: Bool { traitCollection.userInterfaceIdiom == .pad }

    private func installChrome() {
        if usesPadChrome {
            let chrome = PadTabsController()
            chrome.onSelect = { [weak self] index in self?.chromeChose(index) }
            chrome.onReselect = { [weak self] index in self?.chromeReselected(index) }
            chrome.onCompose = { [weak self] in self?.newTweetCommand() }
            addChild(chrome)
            view.addManaged(chrome.view)
            chrome.view.pinEdges(to: view)
            chrome.didMove(toParent: self)
            padChrome = chrome
        } else {
            let chrome = PhoneTabsController()
            chrome.onSelect = { [weak self] index in self?.chromeChose(index) }
            chrome.onReselect = { [weak self] index in self?.chromeReselected(index) }
            addChild(chrome)
            view.addManaged(chrome.view)
            chrome.view.pinEdges(to: view)
            chrome.didMove(toParent: self)
            phoneChrome = chrome
        }
    }

    private func installStacks() {
        if let padChrome {
            padChrome.setControllers(stacks, tabs: selectedTabs, selected: currentIndex)
        } else {
            phoneChrome?.setControllers(stacks, selected: currentIndex)
        }
    }

    /// A new server has its own filter setting: ask it, and drop timelines
    /// saved from the old one.
    @objc private func serverChanged() {
        TimelineCache.shared.clearAll()
        ProfileCache.shared.clearAll()
        SessionSync.restore()
    }

    /// Rebuilds the tab bar from `ClientSettings.tabs`, keeping the stack of
    /// every tab that survives the edit (scroll position, pushed screens) and
    /// the selected tab when it does.
    func rebuildTabs() {
        let previouslySelected = selectedTabs.indices.contains(currentIndex) ? selectedTabs[currentIndex] : nil
        let existing = Dictionary(
            uniqueKeysWithValues: zip(selectedTabs, stacks).map { ($0, $1) })
        selectedTabs = ClientSettings.tabs
        stacks = selectedTabs.map { existing[$0] ?? $0.makeViewController() }
        for case let nav as UINavigationController in stacks {
            nav.delegate = self
        }
        if let previouslySelected, let index = selectedTabs.firstIndex(of: previouslySelected) {
            currentIndex = index
        } else if !stacks.indices.contains(currentIndex) {
            currentIndex = 0
        }
        installStacks()
        AppMenu.rebuild()
        refreshWindowTitle()
    }

    private func chromeChose(_ index: Int) {
        guard stacks.indices.contains(index) else { return }
        currentIndex = index
        phoneChrome?.selectedIndex = index
        padChrome?.select(index)
        refreshWindowTitle()
    }

    private func chromeReselected(_ index: Int) {
        guard stacks.indices.contains(index), index == currentIndex else {
            lastHomeReselect = 0
            return
        }
        guard let nav = stacks[index] as? UINavigationController,
              nav.viewControllers.count == 1,
              let home = nav.viewControllers.first as? HomeViewController else {
            lastHomeReselect = 0
            return
        }
        let now = Date().timeIntervalSinceReferenceDate
        if now - lastHomeReselect < 0.45 {
            home.toggleFeedMode()
            lastHomeReselect = 0
        } else {
            lastHomeReselect = now
        }
    }

    // MARK: - Hardware keyboard and menu bar

    override var keyCommands: [UIKeyCommand]? {
        [
            command("n", title: "New Post", action: #selector(newTweetCommand)),
            command("r", title: "Refresh", action: #selector(refreshCommand)),
            command("f", title: "Search", action: #selector(searchCommand)),
            command("\\", title: "Toggle Sidebar", action: #selector(toggleSidebarCommand)),
        ]
    }

    private func command(_ input: String, title: String, action: Selector) -> UIKeyCommand {
        let command = UIKeyCommand(title: title, action: action, input: input, modifierFlags: .command)
        command.wantsPriorityOverSystemBehavior = true
        return command
    }

    /// ⌘1…⌘5 jump straight to the tab in that slot, the order the bar shows.
    @objc func selectTabCommand(_ sender: UICommand) {
        let slot = (sender.propertyList as? Int)
            ?? (sender.propertyList as? NSNumber)?.intValue
            ?? Int((sender as? UIKeyCommand)?.input ?? "")
        guard let slot, selectedTabs.indices.contains(slot - 1) else { return }
        selectedIndex = slot - 1
    }

    @objc func newTweetCommand() {
        guard presentedViewController == nil else { return }
        let compose = ComposeViewController(mode: .new)
        present(UINavigationController.sheet(rootViewController: compose), animated: true)
    }

    @objc func refreshCommand() {
        if let nav = selectedViewController as? UINavigationController,
           let feed = nav.topViewController as? FeedViewController {
            feed.viewModel.refresh()
        }
    }

    @objc func searchCommand() {
        guard presentedViewController == nil, let index = selectedTabs.firstIndex(of: .search) else { return }
        selectedIndex = index
        let nav = stacks[index] as? UINavigationController
        nav?.popToRootViewController(animated: false)
        (nav?.viewControllers.first as? SearchViewController)?.focusSearchField()
    }

    /// Hides or shows the iPad's sidebar, the way the system sidebars toggle.
    @objc func toggleSidebarCommand() {
        padChrome?.toggleSidebar()
    }

    override func validate(_ command: UICommand) {
        switch command.action {
        case #selector(toggleSidebarCommand):
            command.attributes = padChrome != nil && layoutAllowsSidebar ? [] : .disabled
        case #selector(newTweetCommand):
            command.attributes = presentedViewController == nil ? [] : .disabled
        case #selector(refreshCommand):
            command.attributes = topFeed() == nil ? .disabled : []
        case #selector(searchCommand):
            let canSearch = presentedViewController == nil && selectedTabs.contains(.search)
            command.attributes = canSearch ? [] : .disabled
        default:
            super.validate(command)
        }
    }

    /// Whether this window has a sidebar to toggle at all.
    private var layoutAllowsSidebar: Bool {
        let size = view.bounds.size
        return size.width > size.height && size.width >= PadLayout.railWindowMinimum
    }

    private func topFeed() -> FeedViewController? {
        (selectedViewController as? UINavigationController)?.topViewController as? FeedViewController
    }

    /// Names the window for the screen on top, so the window list can tell a
    /// thread from For You. A pushed screen uses its own title; a tab root uses
    /// the name the bar shows, which follows For You / Following.
    func refreshWindowTitle() {
        padChrome?.refreshItems()
        guard let scene = view.window?.windowScene else { return }
        let nav = selectedViewController as? UINavigationController
        let pushed = (nav?.viewControllers.count ?? 0) > 1
        let screen = nav?.topViewController?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let tab = selectedViewController?.tabBarItem.title
            ?? (selectedTabs.indices.contains(currentIndex) ? selectedTabs[currentIndex].title : "Unrager")
        let name = pushed && screen?.isEmpty == false ? screen! : tab
        guard scene.title != name || scene.subtitle != "Unrager" else { return }
        scene.title = name
        scene.subtitle = "Unrager"
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
    /// still tracked, just nowhere to show it.
    func setNotificationsBadge(_ value: String?) {
        guard let index = notificationsTabIndex,
              let item = (stacks[index] as? UINavigationController)?.tabBarItem
                ?? stacks[index].tabBarItem else { return }
        item.badgeColor = DesignSystem.Color.badge
        item.badgeValue = value
        padChrome?.refreshItems()
    }

    private weak var activeToast: NotificationToast?

    /// Drops an in-app Liquid Glass toast for freshly-arrived notifications while
    /// the app is foregrounded, on the window so it shows above an open sheet. A
    /// single item shows who-did-what + the snippet; a batch coalesces into a
    /// count. Tapping deep-links into the activity.
    func showNotificationToast(_ notifications: [XNotification]) {
        guard let first = notifications.first else { return }
        activeToast?.dismiss()
        let content = notifications.count > 1
            ? NotificationPresentation.toastSummary(count: notifications.count)
            : NotificationPresentation.toastContent(for: first)
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
            (self.stacks[index] as? UINavigationController)?.popToRootViewController(animated: false)
        }
    }

    /// Pushes a view controller onto the Notifications tab's stack — used to
    /// deep-link a tapped banner or toast — or, without that tab, onto the
    /// stack in front, leaving what the user was reading underneath.
    func openInNotificationsStack(_ controller: UIViewController) {
        afterClosingSheets { [weak self] in
            guard let self else { return }
            guard let index = self.notificationsTabIndex else {
                (self.selectedViewController as? UINavigationController)?
                    .pushViewController(controller, animated: true)
                return
            }
            self.selectedIndex = index
            guard let nav = self.stacks[index] as? UINavigationController else { return }
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

extension RootViewController: UINavigationControllerDelegate {
    func navigationController(
        _ navigationController: UINavigationController, didShow viewController: UIViewController, animated: Bool
    ) {
        refreshWindowTitle()
        padChrome?.refreshBoard()
    }
}

extension UIViewController {
    /// Tells the window list this screen is what's on top, and gives the iPad's
    /// chrome the tab titles it shows.
    func noteScreenForWindow() {
        var current: UIViewController? = self
        while let controller = current {
            if let root = controller as? RootViewController {
                root.refreshWindowTitle()
                return
            }
            current = controller.parent ?? controller.presentingViewController
        }
    }
}

extension UINavigationController {
    /// A sheet on a phone; a centred card on iPad, where a full-height sheet
    /// would only stretch a short piece of writing across the window.
    static func sheet(rootViewController: UIViewController) -> UINavigationController {
        let nav = UINavigationController(rootViewController: rootViewController)
        if UIDevice.current.userInterfaceIdiom == .pad {
            nav.modalPresentationStyle = .formSheet
            nav.preferredContentSize = CGSize(width: 620, height: 440)
        }
        return nav
    }
}
