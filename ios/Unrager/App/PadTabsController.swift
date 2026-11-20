import UIKit
import UnragerKit

/// The iPad's tabs: a rail down the side or a bar along the bottom, around the
/// chosen tab. The tab's own feed fills what is left — as a board of cards where
/// the window allows — and a post, a profile or a list of people opens in the
/// column beside it, the way the system's own split views do: the board gives up
/// the width, nothing dims, and both sides stay live. In a tall or narrow window
/// there is no room for a second column, so what you open takes the window and
/// the board waits behind it with its place kept.
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
    /// The detail column's stack per tab, built the first time that tab opens
    /// something in it and kept, so leaving the tab and coming back finds the
    /// post still where it was left.
    private var details: [TabItem: StatusNavigationController] = [:]

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
    /// The column a post opens into: the window's trailing column where there is
    /// room for one beside the board, the whole content area where there isn't.
    private let detailColumn = UIView()
    private let divider = HairlineView()
    private let detail = UIView()

    /// Whether the open tab's own list spreads into a board.
    private var showsBoard: Bool { tabUsesDetail }

    private var detailHasScreens: Bool {
        guard tabs.indices.contains(selectedIndex) else { return false }
        return details[tabs[selectedIndex]]?.viewControllers.isEmpty == false
    }

    /// Whether this tab has screens that open beside the list; Settings is a
    /// column of forms and reads better across the whole window.
    private var tabUsesDetail: Bool {
        tabs.indices.contains(selectedIndex) && tabs[selectedIndex].offersDetailColumn
    }

    private var chromeConstraints: [NSLayoutConstraint] = []
    /// The window width the chrome was last laid out for — the size a resize
    /// is going to, never a frame read halfway through it.
    private var layoutWidth: CGFloat = 0
    private var contentLeading: NSLayoutConstraint!
    /// The column's width where it sits beside the board — a number `PadLayout`
    /// works out from the window's size, never one read off a frame.
    private var detailWidth: NSLayoutConstraint!
    /// The column's leading edge on the content area's, where it fills the
    /// window: a constraint, so it follows every resize on its own.
    private var detailFills: NSLayoutConstraint!
    private var primaryBesideDetail: NSLayoutConstraint!
    private var primaryFullWidth: NSLayoutConstraint!

    /// How long the column change takes. A screenshot run can stretch it, so a
    /// still frame can catch the board midway.
    private static var transitionDuration: TimeInterval {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["UNRAGER_TRANSITION_SECONDS"], let value = Double(raw),
           value > 0 {
            return value
        }
        #endif
        return 0.3
    }

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
        primaryFullWidth = primary.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor)
        NSLayoutConstraint.activate([
            primary.topAnchor.constraint(equalTo: contentArea.topAnchor),
            primary.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor),
            primary.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
            primaryFullWidth,
        ])

        detailColumn.backgroundColor = DesignSystem.Color.background
        detailColumn.clipsToBounds = true
        detailColumn.isHidden = true
        view.addManaged(detailColumn)
        detailWidth = detailColumn.widthAnchor.constraint(equalToConstant: 0)
        detailFills = detailColumn.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor)
        primaryBesideDetail = primary.trailingAnchor.constraint(equalTo: detailColumn.leadingAnchor)
        NSLayoutConstraint.activate([
            detailColumn.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
            detailColumn.topAnchor.constraint(equalTo: view.topAnchor),
            detailColumn.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            detailWidth,
        ])

        detailColumn.addManaged(divider)
        NSLayoutConstraint.activate([
            divider.leadingAnchor.constraint(equalTo: detailColumn.leadingAnchor),
            divider.topAnchor.constraint(equalTo: detailColumn.topAnchor),
            divider.bottomAnchor.constraint(equalTo: detailColumn.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1 / max(1, traitCollection.displayScale)),
        ])

        detailColumn.addManaged(detail)
        detail.clipsToBounds = true
        detail.pinEdges(to: detailColumn)

        view.addManaged(dock)
        dock.isHidden = true
        dock.alpha = 0
        dock.onWayBack = { [weak self] in self?.dockWentBack() }

        let edgeSwipe = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(edgeSwiped))
        edgeSwipe.edges = .left
        edgeSwipe.delegate = self
        edgeSwipe.cancelsTouchesInView = false
        view.addGestureRecognizer(edgeSwipe)

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
        guard detailOnScreen else { return nil }
        let close = UIKeyCommand(title: layout.showsDetail ? "Close" : "Back", action: #selector(closeFromKeyboard),
                                 input: UIKeyCommand.inputEscape)
        close.wantsPriorityOverSystemBehavior = true
        return [close]
    }

    /// Escape closes the post that is open, the way it dismisses a sheet.
    @objc private func closeFromKeyboard() {
        dockWentBack()
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
        if detailOnScreen, !layout.showsDetail {
            closeDetail()
        } else {
            toggleSidebar()
        }
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
                + "primary=\(primary.frame) detail=\(detailColumn.frame) chrome=\(chrome.frame)",
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
        for (tab, nav) in details where !tabs.contains(tab) {
            nav.setViewControllers([], animated: false)
            details[tab] = nil
        }
        installRouters()
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

    /// The column's own way back: a chevron when it fills the window, where it is
    /// a pushed screen, and a close button where it sits beside the board.
    private func giveWayBack(to screen: UIViewController) {
        let wanted = layout.showsDetail ? closeItem : backItem
        let key = ObjectIdentifier(screen)
        if let current = installedWayBack[key] {
            guard current !== wanted else { return }
            let items = screen.navigationItem.leftBarButtonItems
            screen.navigationItem.leftBarButtonItems = items?.map { $0 === current ? wanted : $0 }
            if screen.navigationItem.leftBarButtonItem === current {
                screen.navigationItem.leftBarButtonItem = wanted
            }
            installedWayBack[key] = wanted
            return
        }
        guard screen.navigationItem.leftBarButtonItem == nil,
              screen.navigationItem.leftBarButtonItems?.isEmpty != false else { return }
        screen.navigationItem.leftBarButtonItem = wanted
        installedWayBack[key] = wanted
    }

    /// The screens carrying the column's own way back, so a window that changes
    /// shape can swap the close button for the chevron in place.
    private var installedWayBack: [ObjectIdentifier: UIBarButtonItem] = [:]

    /// Keeps that button honest as the window changes shape under it.
    private func refreshWayBack() {
        guard tabs.indices.contains(selectedIndex), let nav = details[tabs[selectedIndex]] else { return }
        for screen in nav.viewControllers { giveWayBack(to: screen) }
    }

    private lazy var closeItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: DesignSystem.icon("xmark", pointSize: 15, weight: .semibold),
            primaryAction: UIAction { [weak self] _ in self?.closeDetail() })
        item.accessibilityLabel = "Close"
        return item
    }()

    private lazy var backItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: DesignSystem.icon("chevron.left", pointSize: 17, weight: .semibold),
            primaryAction: UIAction { [weak self] _ in self?.closeDetail() })
        item.accessibilityLabel = "Back"
        return item
    }()

    /// Puts the board back: the column slides away and the board takes its width
    /// again, both without anything behind them moving.
    func closeDetail() {
        guard tabs.indices.contains(selectedIndex), let nav = details[tabs[selectedIndex]] else { return }
        dock.isUserInteractionEnabled = false
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.18) { self.dock.alpha = 0 }
        hideDetailColumn {
            for screen in nav.viewControllers { self.installedWayBack[ObjectIdentifier(screen)] = nil }
            nav.setViewControllers([], animated: false)
            self.detachChildren(of: self.detail)
            self.applyFloatingVisibility(animated: true)
        }
    }

    /// Tells the open tab's own feed whether to spread into a board. A pushed
    /// screen is a reading view and keeps its single column.
    /// A tab pushed or popped a screen: the board belongs to whatever feed is in
    /// front now, so ask again.
    func refreshBoard() {
        applySafeArea()
        applyBoard()
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
        switch parts[0] {
        case "tab":
            guard let tab = TabItem(rawValue: parts[1]), let index = tabs.firstIndex(of: tab) else { return }
            if index == selectedIndex, !children(of: tab).isEmpty {
                if expandedSections.contains(tab.rawValue) {
                    expandedSections.remove(tab.rawValue)
                } else {
                    expandedSections.insert(tab.rawValue)
                }
                refreshRows()
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
        let reshaped = !force && (resolved.chrome != layout.chrome
            || resolved.frame != layout.frame
            || resolved.showsDetail != layout.showsDetail)
        layout = resolved
        chrome.apply(form: TabChromeBar.Form(resolved.chrome), metrics: resolved.metrics)
        layoutChrome()
        contentLeading.constant = resolved.railWidth
        if reshaped { refreshWayBack() }
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
            chrome.widthAnchor.constraint(equalToConstant: plan.barWidth).priority(.defaultHigh),
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

    /// Whether a post is open over the board at all.
    private var detailOnScreen: Bool { tabUsesDetail && detailHasScreens }

    /// The detail stack of the tab in front, when it has one.
    private var frontDetailStack: StatusNavigationController? {
        tabs.indices.contains(selectedIndex) ? details[tabs[selectedIndex]] : nil
    }

    /// Whether the floating bar steps aside for the dock: a post that fills a
    /// window with the bar along its bottom has one row of controls, its own.
    private var barMakesWayForDock: Bool { layout.chrome == .bottom && detailOnScreen }

    /// Places the dock low in the open post, on the side the thumb reaches: the
    /// column's trailing corner beside the board, the window's outer edge (or
    /// its trailing one) where the post fills it.
    private func layoutFloatingControls() {
        NSLayoutConstraint.deactivate(dockConstraints)
        let safe = view.safeAreaLayoutGuide
        let beside = layout.showsDetail
        let inset: CGFloat = 16
        let lift = layout.chrome == .bottom ? PadLayout.barLift(for: layout.frame) : inset
        let side: PadReach.Side = beside ? .trailing : reach.primarySide
        let region: (leading: NSLayoutXAxisAnchor, trailing: NSLayoutXAxisAnchor) = beside
            ? (detailColumn.leadingAnchor, detailColumn.trailingAnchor)
            : (contentArea.leadingAnchor, contentArea.trailingAnchor)
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
    private func applyFloatingVisibility(animated: Bool = false) {
        let showsDock = detailOnScreen
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
        UIView.animate(withDuration: 0.22, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            change()
        } completion: { _ in
            self.dock.isHidden = self.dock.alpha == 0
        }
    }

    /// Fills the dock for whatever is on top of the open stack: its way back —
    /// a close beside the board, a chevron where the post fills the window or
    /// a page was opened inside it — and the screen's own actions.
    private func refreshDock() {
        guard let nav = frontDetailStack, let top = nav.topViewController else { return }
        let provider = top as? any DetailDockProviding
        provider?.onDockChange = { [weak self, weak top] in
            guard let self, let top, self.frontDetailStack?.topViewController === top else { return }
            self.refreshDock()
        }
        let wayBack: DetailDock.WayBack = layout.showsDetail && nav.viewControllers.count == 1 ? .close : .back
        dock.configure(wayBack: wayBack, actions: provider?.dockActions() ?? [])
    }

    /// The dock's way back steps back a page inside the open stack, or closes it.
    private func dockWentBack() {
        if let nav = frontDetailStack, nav.viewControllers.count > 1 {
            nav.popViewController(animated: true)
        } else {
            closeDetail()
        }
    }

    /// Where the column is: shut, beside the board at the width the window
    /// gives it, or across the whole content area. Every case is constraints
    /// from the layout alone, so a window that changes size mid-way can never
    /// leave the column at the width it had before.
    private enum DetailPlacement: Equatable {
        case closed
        case beside(CGFloat)
        case fills
    }

    private func place(_ placement: DetailPlacement) {
        detailFills.isActive = false
        detailWidth.isActive = false
        switch placement {
        case .closed:
            detailWidth.constant = 0
            detailWidth.isActive = true
            setPrimaryBesideDetail(false)
        case .beside(let width):
            detailWidth.constant = width
            detailWidth.isActive = true
            setPrimaryBesideDetail(true)
        case .fills:
            detailFills.isActive = true
            setPrimaryBesideDetail(false)
        }
    }

    /// Where an open column belongs in the current layout.
    private var openPlacement: DetailPlacement {
        layout.detailWidth.map(DetailPlacement.beside) ?? .fills
    }

    /// The board gives up the column's width only where the column sits beside
    /// it; where the column fills the window, the board keeps its place behind.
    private func setPrimaryBesideDetail(_ beside: Bool) {
        guard beside != primaryBesideDetail.isActive else { return }
        primaryFullWidth.isActive = !beside
        primaryBesideDetail.isActive = beside
    }

    /// Shows the column for a post, a profile or a list of people: the board
    /// narrows beside it where there is room, and the column slides the last few
    /// points into place the first time it appears.
    private func showDetail() {
        guard detailOnScreen else {
            hideDetailColumn(animated: false) {}
            return
        }
        let beside = layout.showsDetail
        divider.isHidden = !beside
        guard detailColumn.isHidden else {
            // Already open: a new size or a new post. The constraints carry it,
            // and a resize's own transition animates it; laying out here would
            // re-enter the pass that asked.
            place(openPlacement)
            return
        }
        detailColumn.isHidden = false
        let animating = !UIAccessibility.isReduceMotionEnabled
        guard animating else {
            place(openPlacement)
            detail.alpha = 1
            detailColumn.transform = .identity
            return
        }
        detail.alpha = 0
        detailColumn.transform = beside ? .identity : CGAffineTransform(translationX: 32, y: 0)
        if beside { view.layoutIfNeeded() }
        place(openPlacement)
        UIView.animate(withDuration: Self.transitionDuration, delay: 0,
                       usingSpringWithDamping: 0.9, initialSpringVelocity: 0.2,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.view.layoutIfNeeded()
            self.detail.alpha = 1
            self.detailColumn.transform = .identity
        }
    }

    /// The way back: the column gives its width to the board again and what it
    /// held is dropped once the move is done.
    private func hideDetailColumn(animated: Bool = true, completion: @escaping () -> Void) {
        let finish = {
            self.place(.closed)
            self.detailColumn.isHidden = true
            self.detailColumn.transform = .identity
            completion()
        }
        guard animated, !UIAccessibility.isReduceMotionEnabled, !detailColumn.isHidden else {
            // Called from a layout pass as often as from a tap, so the column is
            // collapsed by its constraints alone: laying out here would re-enter
            // the pass that asked for it.
            finish()
            return
        }
        let beside = detailWidth.isActive && detailWidth.constant > 0
        if beside { place(.closed) }
        UIView.animate(withDuration: Self.transitionDuration * 0.85, delay: 0,
                       usingSpringWithDamping: 0.95, initialSpringVelocity: 0.1,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            if beside {
                self.view.layoutIfNeeded()
                self.detail.alpha = 0
            } else {
                self.detail.alpha = 0
                self.detailColumn.transform = CGAffineTransform(translationX: 32, y: 0)
            }
        } completion: { _ in
            self.detail.alpha = 1
            finish()
        }
    }

    private func applySelection() {
        guard controllers.indices.contains(selectedIndex) else { return }
        show(controllers[selectedIndex], in: primary)
        showDetailIfAny()
        refreshDock()
        applyFloatingVisibility()
    }

    private func showDetailIfAny() {
        let nav = tabs.indices.contains(selectedIndex) ? details[tabs[selectedIndex]] : nil
        guard detailOnScreen, let nav, !nav.viewControllers.isEmpty else {
            hideDetailColumn(animated: false) {
                self.detachChildren(of: self.detail)
            }
            return
        }
        show(nav, in: detail)
        showDetail()
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
            guard let nav = controller as? UINavigationController, !details.values.contains(where: { $0 === nav })
            else { continue }
            for screen in nav.viewControllers {
                screen.view.clearBottomBar(clearance)
            }
        }
        for screen in details.values.flatMap(\.viewControllers) {
            screen.view.clearBottomBar(dockClearance)
        }
    }

    // MARK: - The detail column

    /// Screens that read better beside the list they came from than on top of
    /// it. Everything else — Settings and its pages, the hidden posts, a
    /// standalone list — keeps the tab's own stack, so the sidebar never has to
    /// open on top of itself.
    private static func opensBesideTheList(_ controller: UIViewController) -> Bool {
        controller is ThreadViewController
            || controller is ProfileViewController
            || controller is LikersViewController
            || controller is QuotesViewController
            || controller is UserListViewController
            || controller is SearchResultsViewController
    }

    private func installRouters() {
        for controller in controllers {
            guard let nav = controller as? StatusNavigationController else { continue }
            nav.detailRouter = { [weak self] pushed in
                guard let self, self.tabUsesDetail,
                      Self.opensBesideTheList(pushed) else { return false }
                self.openInDetail(pushed)
                return true
            }
        }
    }

    /// Shows `controller` in the column, replacing whatever was there. The board
    /// keeps every card where it was and gives up only the width the column needs.
    private func openInDetail(_ controller: UIViewController) {
        guard tabUsesDetail, tabs.indices.contains(selectedIndex) else { return }
        let nav = detailStack(for: tabs[selectedIndex])
        nav.setViewControllers([controller], animated: false)
        giveWayBack(to: controller)
        show(nav, in: detail)
        showDetail()
        layoutFloatingControls()
        refreshDock()
        applyFloatingVisibility(animated: true)
        applySafeArea()
    }

    private func detailStack(for tab: TabItem) -> StatusNavigationController {
        if let existing = details[tab] { return existing }
        let nav = StatusNavigationController()
        nav.delegate = self
        details[tab] = nav
        return nav
    }
}

extension PadTabsController: UIGestureRecognizerDelegate {
    /// The edge swipe answers to a closed sidebar in a window that could hold
    /// one, and goes back from a post that fills the window the way a pushed
    /// page does on the phone — never from a page pushed inside it, which its
    /// own stack takes back.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer is UIScreenEdgePanGestureRecognizer else { return true }
        if detailOnScreen, !layout.showsDetail {
            return (frontDetailStack?.viewControllers.count ?? 0) <= 1
        }
        return windowHasSidebar && !sidebarShown
    }
}

extension PadTabsController: UINavigationControllerDelegate {
    /// A page opened or closed inside the open post changes what the dock offers.
    func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController,
                              animated: Bool) {
        guard navigationController === frontDetailStack else { return }
        refreshDock()
        applySafeArea()
    }
}

extension PadLayout {
    /// How far the floating bar sits above the window's bottom edge: the room a
    /// mini has for it is a little tighter than a 13-inch window's.
    static func barLift(for frame: Frame) -> CGFloat {
        frame == .mini ? 10 : 12
    }
}
