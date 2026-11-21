import UIKit
import UnragerKit

/// The iPad's tabs: a rail down the side or a bar along the bottom, around the
/// chosen tab. The tab's own feed fills what is left as a board of cards, and a
/// post opens on the tab's own stack the platform's way (`PostOpening`): the
/// card zooms into the post and the post zooms back into it, closed by Back, a
/// swipe in from the edge or a pull down, with the board kept where it was.
final class PadTabsController: UIViewController {
    /// A tab was chosen from the rail or the bar.
    var onSelect: ((Int) -> Void)?
    /// The tab already showing was tapped again.
    var onReselect: ((Int) -> Void)?
    /// The rail's post button, where a sidebar has room for one, and the round
    /// one beside the floating bar.
    var onCompose: (() -> Void)?
    /// What a long press on either compose button offers: the tab in front's
    /// own choices where it has them.
    var composeMenu: (() -> [UIMenuElement])?

    private(set) var selectedIndex = 0
    private(set) var layout = PadLayout.resolve(window: CGSize(width: 1024, height: 768))

    /// The sidebar's width and whether it is open; both survive a relaunch, the
    /// way the system's own sidebars do. A width of zero means "the width this
    /// iPad gives its sidebar", so a mini and a 13-inch window each get their own
    /// until the reader drags one.
    private var sidebarWidth = PadTabsController.initialSidebarWidth
    private var sidebarShown = ClientSettings.padSidebarShown

    /// The width the sidebar opens at: the reader's own, or what a screenshot
    /// run asks for so its drags start from the same place every time.
    private static var initialSidebarWidth: CGFloat {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["UNRAGER_PAD_SIDEBAR"], let width = Double(raw) {
            return width
        }
        #endif
        return ClientSettings.padSidebarWidth
    }

    private var tabs: [TabItem] = []
    private var controllers: [UIViewController] = []

    private let chrome = TabChromeBar()
    /// Where the reader's thumbs reach in this window, read from where the
    /// window sits on the screen.
    private(set) var reach = PadReach.standard
    /// The compose button that rides with the floating bar: level with it in
    /// the corner where there is room, just above its outer end where there
    /// isn't, and against the window's outer edge when it shares the screen.
    private let composeOrb = UIButton(configuration: .unragerProminentGlass())
    private var orbConstraints: [NSLayoutConstraint] = []
    /// The way back and the open post's own actions, low and to one side.
    private let dock = DetailDock()
    private var dockConstraints: [NSLayoutConstraint] = []
    private let contentArea = UILayoutGuide()
    private let primary = UIView()

    /// Whether the open tab's own list spreads into a board; Settings is a
    /// column of forms and reads better as one.
    private var showsBoard: Bool {
        tabs.indices.contains(selectedIndex) && tabs[selectedIndex].offersBoard
    }

    private var chromeConstraints: [NSLayoutConstraint] = []
    /// The floating bar's width, and the width it has with every tab showing.
    private var barWidth: NSLayoutConstraint?
    private var fullBarWidth: CGFloat = 0
    /// Whether the floating bar has drawn in to the chosen tab, which it does
    /// as the reader scrolls on, the way the phone's tab bar does.
    private var barMinimized = false
    /// The list a drag in progress is scrolling.
    private weak var draggedList: UIScrollView?
    /// The window width the chrome was last laid out for — the size a resize
    /// is going to, never a frame read halfway through it.
    private var layoutWidth: CGFloat = 0
    private var contentLeading: NSLayoutConstraint!

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = DesignSystem.Color.background

        view.addManaged(chrome)
        chrome.onSelect = { [weak self] index in self?.choose(index) }
        chrome.onReselect = { [weak self] index in self?.onReselect?(index) }
        chrome.onCompose = { [weak self] in self?.onCompose?() }
        chrome.onToggleSidebar = { [weak self] in self?.toggleSidebar() }
        chrome.onResize = { [weak self] travel in self?.resizeSidebar(by: travel) }
        chrome.onRow = { [weak self] id in self?.chooseRow(id) }
        chrome.composeMenu = { [weak self] in self?.composeMenu?() ?? [] }
        configureComposeOrb()

        view.addLayoutGuide(contentArea)
        contentLeading = contentArea.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        NSLayoutConstraint.activate([
            contentLeading,
            contentArea.topAnchor.constraint(equalTo: view.topAnchor),
            contentArea.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentArea.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        view.addManaged(primary)
        NSLayoutConstraint.activate([
            primary.topAnchor.constraint(equalTo: contentArea.topAnchor),
            primary.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor),
            primary.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
            primary.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
        ])

        view.addManaged(dock)
        dock.isHidden = true
        dock.alpha = 0
        dock.onWayBack = { [weak self] in self?.dockWentBack() }

        let edgeSwipe = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(edgeSwiped))
        edgeSwipe.edges = .left
        edgeSwipe.delegate = self
        edgeSwipe.cancelsTouchesInView = false
        view.addGestureRecognizer(edgeSwipe)

        let scrollWatch = UIPanGestureRecognizer(target: self, action: #selector(listDragged))
        scrollWatch.delegate = self
        scrollWatch.cancelsTouchesInView = false
        scrollWatch.delaysTouchesBegan = false
        scrollWatch.delaysTouchesEnded = false
        view.addGestureRecognizer(scrollWatch)

        NotificationCenter.default.addObserver(self, selector: #selector(windowMoved),
                                               name: PadReach.windowMoved, object: nil)
        apply(resolvedLayout(for: view.bounds.size), width: view.bounds.width, force: true)
    }

    private func configureComposeOrb() {
        var config = UIButton.Configuration.unragerProminentGlass()
        config.image = DesignSystem.icon("square.and.pencil", pointSize: 20, weight: .semibold)
        composeOrb.configuration = config
        composeOrb.accessibilityLabel = "New post"
        composeOrb.accessibilityHint = "Touch and hold for more."
        composeOrb.addAction(UIAction { [weak self] _ in self?.onCompose?() }, for: .touchUpInside)
        composeOrb.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.composeMenu?() ?? [])
            },
        ])
        composeOrb.pointerStyleProvider = { button, _, _ in
            UIPointerStyle(effect: .lift(UITargetedPreview(view: button)), shape: .roundedRect(button.bounds, radius: button.bounds.height / 2))
        }
        view.addManaged(composeOrb)
    }

    /// The system moved the window without resizing it — another app took the
    /// other side of the screen, or the window was dragged — so the edge its
    /// thumb is on may have changed with no layout pass to say so.
    @objc private func windowMoved() {
        refreshReach(animated: true)
    }

    /// Reads where the thumbs are and, if that moved, puts the floating
    /// controls under them.
    private func refreshReach(animated: Bool = false) {
        let read = PadReach.reading(view)
        guard read != reach else { return }
        reach = read
        let size = view.bounds.size
        apply(resolvedLayout(for: size), width: size.width)
        layoutChrome()
        layoutFloatingControls()
        guard animated else { return }
        animateLayout()
    }

    /// The screen this window is on, which says what kind of iPad it is.
    private var screenSize: CGSize? {
        view.window?.windowScene?.screen.bounds.size
    }

    /// The chrome and columns for a window of `size`, with the sidebar as the
    /// reader left it.
    private func resolvedLayout(for size: CGSize) -> PadLayout {
        PadLayout.resolve(window: size, screen: screenSize, rail: sidebarWidth,
                          closed: !sidebarShown || railOutOfReach)
    }

    /// A wide window sharing the screen from its trailing side puts its leading
    /// edge in the middle of the screen, where no thumb rests: its tabs go to
    /// the bar along the bottom instead, hugging the edge the thumb is on.
    private var railOutOfReach: Bool { !reach.railInReach }

    // MARK: - Keyboard

    override var keyCommands: [UIKeyCommand]? {
        guard pageOnScreen else { return nil }
        let back = UIKeyCommand(title: "Back", action: #selector(backFromKeyboard), input: UIKeyCommand.inputEscape)
        back.wantsPriorityOverSystemBehavior = true
        return [back]
    }

    /// Escape steps back from the post or page that is open, the way it closes
    /// a sheet.
    @objc private func backFromKeyboard() {
        frontStack?.popViewController(animated: true)
    }

    /// A window about to change size moves its columns with the system's own
    /// animation, from the size it is going to have, rather than catching up on
    /// the next layout pass at whatever size that pass happens to read.
    override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        guard size.width > 0, size.height > 0 else { return }
        #if DEBUG
        ResizeTimer.shared.begin(size)
        #endif
        coordinator.animate { _ in
            self.apply(self.resolvedLayout(for: size), width: size.width)
            self.view.layoutIfNeeded()
        }
    }

    /// A swipe in from the leading edge brings a closed sidebar back, the way it
    /// does in the system's own apps.
    @objc private func edgeSwiped(_ gesture: UIScreenEdgePanGestureRecognizer) {
        guard gesture.state == .recognized else { return }
        Haptics.selection()
        toggleSidebar()
    }

    /// Whether this window has a rail to reveal at all.
    var windowHasSidebar: Bool {
        PadLayout.allowsRail(window: view.bounds.size) && !railOutOfReach
    }

    /// A screen's navigation item only holds what the screen has put there once
    /// its view has loaded, which happens as the window appears — so the way
    /// back to a closed sidebar is placed again here, after that.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        applySidebarButton()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        apply(resolvedLayout(for: size), width: size.width)
        refreshReach()
        // A tab's view is loaded the first time it is shown, which can be after
        // the chrome was resolved: its board and its bar clearance are settled
        // here, on every pass, so nothing waits for the next tap.
        applyBoard()
        applySafeArea()
        #if DEBUG
        if ProcessInfo.processInfo.environment["UNRAGER_LAYOUT_LOG"] != nil, size != loggedSize {
            loggedSize = size
            AppLogger.shared.info(
                "pad layout \(layout) window=\(String(describing: view.window?.bounds)) "
                + "primary=\(primary.frame) chrome=\(chrome.frame)",
                category: .app)
        }
        #endif
    }

    #if DEBUG
    private var loggedSize: CGSize = .zero
    #endif

    // MARK: - Tabs

    func setControllers(_ controllers: [UIViewController], tabs: [TabItem], selected: Int) {
        self.controllers = controllers
        self.tabs = tabs
        selectedIndex = controllers.indices.contains(selected) ? selected : 0
        if expandedSections.isEmpty, tabs.indices.contains(selectedIndex) {
            expandedSections.insert(tabs[selectedIndex].rawValue)
        }
        refreshRows()
        applySelection()
        applySidebarButton()
    }

    /// Moves the tabs to `index` — the phone's `selectedIndex`, shared with the
    /// rail and the bar, so ⌘1…⌘5 land here too.
    func select(_ index: Int) {
        guard controllers.indices.contains(index) else { return }
        setBarMinimized(false)
        selectedIndex = index
        refreshRows()
        applySelection()
        applySidebarButton()
    }

    /// Re-reads each tab's `tabBarItem` — a Home tab that names the feed it is
    /// on, and the unread count — so the chrome never disagrees with the
    /// screens behind it.
    func refreshItems() {
        refreshRows()
    }

    /// The sections the reader has folded open, by tab raw value.
    private var expandedSections = Set<String>()

    private func choose(_ index: Int) {
        guard index != selectedIndex else { return }
        onSelect?(index)
    }

    // MARK: - Sidebar

    /// Closes the sidebar, or opens it again — the button the rail carries, and
    /// ⌘\ from anywhere.
    func toggleSidebar() {
        // A closed rail gives its tabs back to the bottom bar, so the toggle has
        // to answer to the window, not to what is on screen now.
        guard windowHasSidebar else { return }
        sidebarShown.toggle()
        ClientSettings.padSidebarShown = sidebarShown
        apply(resolvedLayout(for: view.bounds.size), width: view.bounds.width)
        applySidebarButton()
        animateLayout()
    }

    /// Narrows or widens the sidebar as its grip is dragged, with the columns
    /// taking up the difference.
    private func resizeSidebar(by travel: CGFloat) {
        guard layout.chrome == .rail, sidebarShown else { return }
        let metrics = layout.metrics
        let current = layout.railWidth
        let proposed = min(max(current + travel, metrics.narrowestRail), metrics.widestRail)
        guard proposed != sidebarWidth else { return }
        sidebarWidth = proposed
        ClientSettings.padSidebarWidth = proposed
        apply(resolvedLayout(for: view.bounds.size), width: view.bounds.width)
        animateLayout()
    }

    private func animateLayout() {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        UIView.animate(withDuration: 0.28, delay: 0, usingSpringWithDamping: 0.92, initialSpringVelocity: 0.2,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.view.layoutIfNeeded()
        }
    }

    /// A closed sidebar leaves nothing to tap, so the tab's own navigation bar
    /// carries the standard way back — the way the system's sidebars do, in a
    /// window that could have one.
    private func applySidebarButton() {
        let shows = windowHasSidebar && !sidebarShown
        for (index, controller) in controllers.enumerated() {
            guard let nav = controller as? UINavigationController else { continue }
            let wanted = shows && index == selectedIndex
            for screen in nav.viewControllers {
                setSidebarButton(on: screen, shows: wanted)
            }
        }
    }

    /// Puts the way back in front of whatever the screen keeps in its leading
    /// items — the title menu on a feed, a back button on a pushed screen — and
    /// puts them back exactly as they were when the sidebar returns.
    private func setSidebarButton(on screen: UIViewController, shows: Bool) {
        let key = ObjectIdentifier(screen)
        let item = screen.navigationItem
        if shows {
            if savedLeading[key] == nil {
                savedLeading[key] = (item.leftBarButtonItems, item.leftBarButtonItem)
            }
            var items = item.leftBarButtonItems ?? []
            if let single = item.leftBarButtonItem, !items.contains(where: { $0 === single }) {
                items.insert(single, at: 0)
            }
            items.removeAll { $0 === revealButton }
            item.leftBarButtonItem = nil
            item.leftBarButtonItems = [revealButton] + items
        } else if let saved = savedLeading.removeValue(forKey: key) {
            var items = item.leftBarButtonItems ?? []
            items.removeAll { $0 === revealButton }
            if saved.items == nil, saved.single == nil {
                item.leftBarButtonItems = nil
                item.leftBarButtonItem = items.first
            } else {
                item.leftBarButtonItems = saved.items
                item.leftBarButtonItem = saved.single
            }
        }
    }

    /// Each screen's own leading items while the sidebar is closed and ours is
    /// in front of them.
    private var savedLeading: [ObjectIdentifier: (items: [UIBarButtonItem]?, single: UIBarButtonItem?)] = [:]

    /// A tab pushed or popped a screen: the board belongs to whatever feed is in
    /// front now, and the dock and the bar to whatever page is, so ask again.
    func refreshBoard() {
        applySafeArea()
        applyBoard()
        refreshDock()
        applyFloatingVisibility(animated: true)
    }

    /// A page is about to show on the tab in front: the bar makes way for the
    /// post's dock, and comes back as the post closes, with the system's own
    /// zoom or slide rather than after it — and back again if a swipe back is
    /// let go of before it lands.
    func stackWillShow(_ navigationController: UINavigationController) {
        guard navigationController === frontStack else { return }
        setBarMinimized(false)
        refreshDock()
        applyFloatingVisibility(animated: true, alongside: navigationController.transitionCoordinator)
    }

    private func applyBoard() {
        for (index, controller) in controllers.enumerated() {
            guard let nav = controller as? UINavigationController else { continue }
            for host in boardHosts(in: nav.topViewController) {
                host.setGrid(index == selectedIndex && showsBoard)
                host.setChromeCarriesCompose(true)
            }
        }
    }

    /// Every feed in the tab's front screen — a profile's own posts, and the
    /// replies list it holds under the same header, so switching tabs on a
    /// profile keeps the board. A pushed list is a reading screen and returns
    /// nothing, so nothing behind it animates.
    private func boardHosts(in controller: UIViewController?) -> [FeedViewController] {
        guard let controller else { return [] }
        var hosts: [FeedViewController] = []
        if let feed = controller as? FeedViewController { hosts.append(feed) }
        for child in controller.children { hosts.append(contentsOf: boardHosts(in: child)) }
        return hosts
    }

    private func boardHost(in controller: UIViewController?) -> FeedViewController? {
        boardHosts(in: controller).first
    }

    private lazy var revealButton: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: DesignSystem.icon("sidebar.leading", pointSize: 17),
            primaryAction: UIAction { [weak self] _ in self?.toggleSidebar() })
        item.accessibilityLabel = "Show sidebar"
        return item
    }()

    // MARK: - Rows

    /// The rail's lines: the tabs, and under the ones that have somewhere else
    /// to go, the places that normally take several taps — the feeds the title
    /// menu hides, the notification lenses, the settings pages, the posts the
    /// filter hid.
    private func refreshRows() {
        let count = chrome.tabCount
        chrome.setRows(rows())
        replaceBarIfTabsChanged(from: count)
    }

    /// The floating bar's width is made of its tabs, so a bar laid out before
    /// they arrived — every launch straight into a tall window, which drew a
    /// sliver of a bar with its names cut off — or before one was added or
    /// hidden, is placed again.
    private func replaceBarIfTabsChanged(from count: Int) {
        guard chrome.tabCount != count, layout.chrome == .bottom, isViewLoaded else { return }
        layoutChrome()
        layoutFloatingControls()
    }

    private func rows() -> [TabChromeBar.Row] {
        var rows: [TabChromeBar.Row] = []
        for (index, tab) in tabs.enumerated() {
            let item = controllers.indices.contains(index) ? controllers[index].tabBarItem : nil
            let expanded = expandedSections.contains(tab.rawValue)
            let isGroup = !children(of: tab).isEmpty
            rows.append(TabChromeBar.Row(
                id: "tab:\(tab.rawValue)",
                title: isGroup ? tab.title : (item?.title ?? tab.title),
                image: item?.image ?? DesignSystem.icon(tab.symbol),
                badge: item?.badgeValue,
                isGroup: isGroup,
                isExpanded: expanded,
                chosen: index == selectedIndex))
            if expanded {
                rows.append(contentsOf: children(of: tab))
            }
        }
        return rows
    }

    /// What lives under a tab in the rail, marked for where the reader is now.
    private func children(of tab: TabItem) -> [TabChromeBar.Row] {
        switch tab {
        case .home:
            let home = controller(for: .home) as? HomeViewController
            let current = home?.currentChoice
            return homeFeeds.map { choice in
                TabChromeBar.Row(id: "feed:\(choice.key)", title: choice.title,
                                 image: DesignSystem.icon(choice.symbol), depth: 1,
                                 chosen: current == choice)
            } + [
                TabChromeBar.Row(id: "hidden", title: "Hidden posts",
                                 image: DesignSystem.icon("eye.slash"), depth: 1),
            ]
        case .notifications:
            let current = (controller(for: .notifications) as? NotificationsViewController)?.currentCategory
            return NotificationCategory.allCases.map { category in
                TabChromeBar.Row(id: "notif:\(category.rawValue)", title: category.title,
                                 image: nil, depth: 1, chosen: current == category)
            }
        case .settings:
            return settingsPages.map { page in
                TabChromeBar.Row(id: "settings:\(page.id)", title: page.title,
                                 image: DesignSystem.icon(page.symbol), depth: 1)
            }
        default:
            return []
        }
    }

    private var homeFeeds: [HomeFeedChoice] { [.forYou, .following, .mentions, .bookmarks] }

    private var settingsPages: [(id: String, title: String, symbol: String)] {
        [("filter", "Rage filter", "line.3.horizontal.decrease.circle"),
         ("notifications", "Notifications", "bell"),
         ("tabs", "Edit tabs", "square.grid.2x2"),
         ("changelog", "What's new", "sparkles")]
    }

    private func controller(for tab: TabItem) -> UIViewController? {
        guard let index = tabs.firstIndex(of: tab), controllers.indices.contains(index) else { return nil }
        return (controllers[index] as? UINavigationController)?.viewControllers.first ?? controllers[index]
    }

    private func chooseRow(_ id: String) {
        let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        if barMinimized {
            setBarMinimized(false)
            return
        }
        switch parts[0] {
        case "tab":
            guard let tab = TabItem(rawValue: parts[1]), let index = tabs.firstIndex(of: tab) else { return }
            if index == selectedIndex {
                reselected(tab, at: index)
                return
            }
            if children(of: tab).isEmpty == false { expandedSections.insert(tab.rawValue) }
            choose(index)
        case "feed":
            guard let choice = homeFeeds.first(where: { $0.key == parts[1] }) else { return }
            selectTab(.home)
            (controller(for: .home) as? HomeViewController)?.selectFeed(choice)
            refreshRows()
        case "notif":
            guard let category = NotificationCategory(rawValue: parts[1]) else { return }
            selectTab(.notifications)
            (controller(for: .notifications) as? NotificationsViewController)?.selectCategory(category)
            refreshRows()
        case "settings":
            guard let page = settingsPages.first(where: { $0.id == parts[1] }) else { return }
            selectTab(.settings)
            let destination: UIViewController = switch page.id {
            case "filter": FilterSettingsViewController()
            case "notifications": NotificationSettingsViewController()
            case "tabs": EditTabsViewController()
            default: ChangelogViewController()
            }
            if let split = controllers.indices.contains(selectedIndex)
                ? controllers[selectedIndex] as? SettingsSplitViewController : nil {
                split.push(destination)
            } else {
                (controllers.indices.contains(selectedIndex) ? controllers[selectedIndex] as? UINavigationController : nil)?
                    .pushViewController(destination, animated: true)
            }
            refreshRows()
        case "hidden":
            selectTab(.home)
            guard let home = controller(for: .home) as? HomeViewController else { return }
            (controllers.indices.contains(selectedIndex) ? controllers[selectedIndex] as? UINavigationController : nil)?
                .pushViewController(HiddenPostsViewController(viewModel: home.viewModel), animated: true)
        default:
            break
        }
    }

    /// The tab in front was tapped again. As on the phone, that closes
    /// whatever is open over the tab's own list; on the list itself it is
    /// reported (two in a row flip Home between For You and Following), and
    /// the rail folds or unfolds the tab's section.
    private func reselected(_ tab: TabItem, at index: Int) {
        if pageOnScreen {
            frontStack?.popToRootViewController(animated: true)
            return
        }
        AppLogger.shared.debug("tab \(tab.rawValue) tapped again", category: .app)
        onReselect?(index)
        guard layout.chrome == .rail, !children(of: tab).isEmpty else { return }
        if expandedSections.contains(tab.rawValue) {
            expandedSections.remove(tab.rawValue)
        } else {
            expandedSections.insert(tab.rawValue)
        }
        refreshRows()
    }

    // MARK: - Minimising the bar

    /// Draws the floating bar in to the chosen tab, or lets it out again.
    private func setBarMinimized(_ minimized: Bool) {
        let wanted = minimized && layout.chrome == .bottom && !barMakesWayForDock
        guard wanted != barMinimized else { return }
        barMinimized = wanted
        let change = {
            self.chrome.setMinimized(wanted)
            self.barWidth?.constant = self.currentBarWidth
            self.view.layoutIfNeeded()
        }
        guard view.window != nil, !UIAccessibility.isReduceMotionEnabled else {
            change()
            return
        }
        UIView.animate(withDuration: 0.32, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0.2,
                       options: [.allowUserInteraction, .beginFromCurrentState], animations: change)
    }

    private var currentBarWidth: CGFloat {
        barMinimized ? layout.metrics.barItemWidth + 20 : fullBarWidth
    }

    /// How far a finger travels before the bar answers it.
    private static let barDragThreshold: CGFloat = 28

    /// Follows a drag on the list in front: scrolling on draws the bar in,
    /// scrolling back lets it out, and a list back at its top always shows it.
    @objc private func listDragged(_ gesture: UIPanGestureRecognizer) {
        guard layout.chrome == .bottom else { return }
        switch gesture.state {
        case .began:
            let touched = view.hitTest(gesture.location(in: view), with: nil)
            draggedList = touched.flatMap(Self.verticalList(holding:))
        case .changed:
            guard let list = draggedList else { return }
            let travel = gesture.translation(in: view)
            guard abs(travel.y) > abs(travel.x), abs(travel.y) > Self.barDragThreshold else { return }
            gesture.setTranslation(.zero, in: view)
            setBarMinimized(travel.y < 0 && !Self.isAtTop(list))
        default:
            if let list = draggedList, Self.isAtTop(list) { setBarMinimized(false) }
            draggedList = nil
        }
    }

    private static func isAtTop(_ list: UIScrollView) -> Bool {
        list.contentOffset.y <= -list.adjustedContentInset.top + 8
    }

    /// The list `view` sits in that scrolls up and down, if it has more to
    /// show than fits.
    private static func verticalList(holding view: UIView) -> UIScrollView? {
        var next: UIView? = view
        while let candidate = next {
            if let list = candidate as? UIScrollView, list.isScrollEnabled,
               list.contentSize.height > list.bounds.height {
                return list
            }
            next = candidate.superview
        }
        return nil
    }

    /// Moves the tabs to `tab` through the same path the rail uses.
    private func selectTab(_ tab: TabItem) {
        guard let index = tabs.firstIndex(of: tab), index != selectedIndex else { return }
        choose(index)
    }

    // MARK: - Placement

    /// Resolves the chrome, the board and the column for a new window size.
    private func apply(_ resolved: PadLayout, width: CGFloat, force: Bool = false) {
        let widthMoved = abs(width - layoutWidth) > 0.5
        layoutWidth = width
        guard force || resolved != layout else {
            // The bar and its compose button are placed from the width itself,
            // not only from the layout's break points.
            if widthMoved, layout.chrome == .bottom {
                layoutChrome()
                layoutFloatingControls()
            }
            return
        }
        layout = resolved
        if resolved.chrome != .bottom, barMinimized {
            barMinimized = false
            chrome.setMinimized(false)
        }
        chrome.apply(form: TabChromeBar.Form(resolved.chrome), metrics: resolved.metrics)
        layoutChrome()
        contentLeading.constant = resolved.railWidth
        applySelection()
        layoutFloatingControls()
        refreshDock()
        applyFloatingVisibility()
        applySidebarButton()
        applyBoard()
        applySafeArea()
    }

    private func layoutChrome() {
        NSLayoutConstraint.deactivate(chromeConstraints + orbConstraints)
        orbConstraints = []
        chrome.isHidden = layout.chrome == .rail && layout.railWidth == 0
        guard layout.chrome == .bottom else {
            chromeConstraints = [
                chrome.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                chrome.topAnchor.constraint(equalTo: view.topAnchor),
                chrome.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                chrome.widthAnchor.constraint(equalToConstant: layout.railWidth),
            ]
            NSLayoutConstraint.activate(chromeConstraints)
            composeOrb.isHidden = true
            view.bringSubviewToFront(chrome)
            return
        }
        let metrics = layout.metrics
        let safe = view.safeAreaLayoutGuide
        let margin = PadReach.dockMargin
        let plan = reach.dock(width: layoutWidth, tabs: chrome.tabCount,
                              itemWidth: metrics.barItemWidth, maximumBar: metrics.barWidth,
                              button: metrics.barHeight)
        #if DEBUG
        if ProcessInfo.processInfo.environment["UNRAGER_LAYOUT_LOG"] != nil {
            AppLogger.shared.info("dock plan width=\(layoutWidth) tabs=\(chrome.tabCount) plan=\(plan)", category: .app)
        }
        #endif
        chromeConstraints = [
            chrome.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -PadLayout.barLift(for: layout.frame)),
            chrome.heightAnchor.constraint(equalToConstant: metrics.barHeight),
            chromeWidth(plan.barWidth),
            chrome.leadingAnchor.constraint(greaterThanOrEqualTo: safe.leadingAnchor, constant: margin),
            chrome.trailingAnchor.constraint(lessThanOrEqualTo: safe.trailingAnchor, constant: -margin),
        ]
        orbConstraints = [
            composeOrb.widthAnchor.constraint(equalToConstant: metrics.barHeight),
            composeOrb.heightAnchor.constraint(equalToConstant: metrics.barHeight),
        ]
        let orbAtEdge = plan.composeSide == .leading
            ? composeOrb.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: margin)
            : composeOrb.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -margin)
        orbConstraints.append(orbAtEdge)
        orbConstraints.append(plan.composeBesideBar
            ? composeOrb.centerYAnchor.constraint(equalTo: chrome.centerYAnchor)
            : composeOrb.bottomAnchor.constraint(equalTo: chrome.topAnchor, constant: -PadReach.dockGap))
        switch plan.placement {
        case .centred:
            chromeConstraints.append(chrome.centerXAnchor.constraint(equalTo: safe.centerXAnchor))
        case .hugging(let side):
            let gap = PadReach.dockGap
            switch (side, plan.composeBesideBar) {
            case (.leading, true):
                chromeConstraints.append(chrome.leadingAnchor.constraint(equalTo: composeOrb.trailingAnchor, constant: gap))
            case (.trailing, true):
                chromeConstraints.append(chrome.trailingAnchor.constraint(equalTo: composeOrb.leadingAnchor, constant: -gap))
            case (.leading, false):
                chromeConstraints.append(chrome.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: margin))
            case (.trailing, false):
                chromeConstraints.append(chrome.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -margin))
            }
        }
        NSLayoutConstraint.activate(chromeConstraints + orbConstraints)
        composeOrb.isHidden = false
        view.bringSubviewToFront(chrome)
        view.bringSubviewToFront(composeOrb)
        applyFloatingVisibility()
    }

    /// The floating bar's width constraint, at `full` points with every tab
    /// showing and at one tab's width while the bar is drawn in.
    private func chromeWidth(_ full: CGFloat) -> NSLayoutConstraint {
        fullBarWidth = full
        let width = chrome.widthAnchor.constraint(equalToConstant: currentBarWidth).priority(.defaultHigh)
        barWidth = width
        return width
    }

    /// The tab in front's own stack.
    private var frontStack: UINavigationController? {
        controllers.indices.contains(selectedIndex) ? controllers[selectedIndex] as? UINavigationController : nil
    }

    /// Whether a post or a page is open over the tab's own list.
    private var pageOnScreen: Bool { (frontStack?.viewControllers.count ?? 0) > 1 }

    /// The open page's dock, where it has one: a post's reply, repost, like and
    /// share within reach of a thumb.
    private var dockProvider: (any DetailDockProviding)? {
        guard pageOnScreen else { return nil }
        return frontStack?.topViewController as? any DetailDockProviding
    }

    /// Whether the floating bar steps aside for the dock: a post with the bar
    /// along its bottom has one row of controls, its own.
    private var barMakesWayForDock: Bool { layout.chrome == .bottom && dockProvider != nil }

    /// Places the dock low in the open post, on the side the thumb reaches: the
    /// window's outer edge where it shares the screen, its trailing one where it
    /// doesn't.
    private func layoutFloatingControls() {
        NSLayoutConstraint.deactivate(dockConstraints)
        let safe = view.safeAreaLayoutGuide
        let inset: CGFloat = 16
        let lift = layout.chrome == .bottom ? PadLayout.barLift(for: layout.frame) : inset
        let side = reach.primarySide
        let region = (leading: contentArea.leadingAnchor, trailing: contentArea.trailingAnchor)
        dockConstraints = [
            dock.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -lift),
            dock.leadingAnchor.constraint(greaterThanOrEqualTo: region.leading, constant: 12),
            dock.trailingAnchor.constraint(lessThanOrEqualTo: region.trailing, constant: -12),
            side == .trailing
                ? dock.trailingAnchor.constraint(equalTo: region.trailing, constant: -inset).priority(.defaultHigh)
                : dock.leadingAnchor.constraint(equalTo: region.leading, constant: inset).priority(.defaultHigh),
        ]
        NSLayoutConstraint.activate(dockConstraints)
        dock.setHeight(layout.metrics.barHeight)
        view.bringSubviewToFront(dock)
    }

    /// Which floating controls show: the bar and its compose button, or the
    /// dock of the post that is open.
    private func applyFloatingVisibility(animated: Bool = false,
                                         alongside coordinator: (any UIViewControllerTransitionCoordinator)? = nil) {
        let showsDock = dockProvider != nil
        let barAway = barMakesWayForDock
        let change = {
            self.dock.alpha = showsDock ? 1 : 0
            if self.layout.chrome == .bottom {
                self.chrome.alpha = barAway ? 0 : 1
                self.composeOrb.alpha = barAway ? 0 : 1
            } else {
                self.chrome.alpha = 1
            }
        }
        if showsDock { dock.isHidden = false }
        chrome.isUserInteractionEnabled = !barAway
        composeOrb.isUserInteractionEnabled = !barAway
        dock.isUserInteractionEnabled = showsDock
        chrome.accessibilityElementsHidden = barAway
        composeOrb.accessibilityElementsHidden = barAway
        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            change()
            dock.isHidden = !showsDock
            return
        }
        if let coordinator {
            coordinator.animate { _ in
                change()
            } completion: { context in
                guard !context.isCancelled else {
                    self.refreshDock()
                    self.applyFloatingVisibility(animated: true)
                    return
                }
                self.dock.isHidden = self.dock.alpha == 0
            }
            return
        }
        UIView.animate(withDuration: 0.22, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            change()
        } completion: { _ in
            self.dock.isHidden = self.dock.alpha == 0
        }
    }

    /// Fills the dock for the post on top of the tab's stack: the way back, and
    /// the post's own actions.
    private func refreshDock() {
        guard let provider = dockProvider, let top = frontStack?.topViewController else { return }
        provider.onDockChange = { [weak self, weak top] in
            guard let self, let top, self.frontStack?.topViewController === top else { return }
            self.refreshDock()
        }
        dock.configure(actions: provider.dockActions())
    }

    /// The dock's way back steps back one page.
    private func dockWentBack() {
        frontStack?.popViewController(animated: true)
    }

    private func applySelection() {
        guard controllers.indices.contains(selectedIndex) else { return }
        show(controllers[selectedIndex], in: primary)
        refreshDock()
        applyFloatingVisibility()
    }

    /// Puts `controller` in `host`, taking out whatever lived there and keeping
    /// every other screen alive off screen so its scroll position survives.
    private func show(_ controller: UIViewController, in host: UIView) {
        if controller.parent === self, controller.view.superview === host { return }
        detachChildren(of: host, except: controller)
        if controller.parent !== self {
            addChild(controller)
            controller.view.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(controller.view)
            controller.view.pinEdges(to: host)
            controller.didMove(toParent: self)
        } else if controller.view.superview !== host {
            host.addSubview(controller.view)
            controller.view.pinEdges(to: host)
        }
    }

    private func detachChildren(of host: UIView, except kept: UIViewController? = nil) {
        for child in children where child !== kept && child.view.superview === host {
            child.willMove(toParent: nil)
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
    }

    /// Under a bar the screens keep their feet clear of it; beside a rail they
    /// run the full height. The bar floats over the page — no backdrop of its
    /// own beyond its glass — so every list inside a tab is given its height as a
    /// bottom inset: content scrolls under the glass, as it does under the
    /// system's bars, and its last row can always be brought clear.
    private func applySafeArea() {
        let clearance = layout.chrome == .bottom ? layout.metrics.barClearance : 0
        let lift = layout.chrome == .bottom ? PadLayout.barLift(for: layout.frame) : 16
        let dockClearance = layout.metrics.barHeight + lift + 10
        for controller in children {
            guard let nav = controller as? UINavigationController else { continue }
            for screen in nav.viewControllers {
                let docked = screen !== nav.viewControllers.first && screen is any DetailDockProviding
                screen.view.clearBottomBar(docked ? dockClearance : clearance)
            }
        }
    }

}

extension PadTabsController: UIGestureRecognizerDelegate {
    /// The edge swipe brings a closed sidebar back in a window that could hold
    /// one, and only over the tab's own list: over a post or a page the same
    /// swipe is the system's way back.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer is UIScreenEdgePanGestureRecognizer else { return true }
        return windowHasSidebar && !sidebarShown && !pageOnScreen
    }

    /// The watch on the list's drags never competes with the list, or with
    /// anything else, for the touch.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        !(gestureRecognizer is UIScreenEdgePanGestureRecognizer)
    }
}

extension PadLayout {
    /// How far the floating bar sits above the window's bottom edge: the room a
    /// mini has for it is a little tighter than a 13-inch window's.
    static func barLift(for frame: Frame) -> CGFloat {
        frame == .mini ? 10 : 12
    }
}
