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
    /// The rail's post button, where a sidebar has room for one.
    var onCompose: (() -> Void)?

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
    private var contentLeading: NSLayoutConstraint!
    private var detailWidth: NSLayoutConstraint!
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

        let edgeSwipe = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(edgeSwiped))
        edgeSwipe.edges = .left
        edgeSwipe.delegate = self
        edgeSwipe.cancelsTouchesInView = false
        view.addGestureRecognizer(edgeSwipe)

        apply(PadLayout.resolve(window: view.bounds.size, rail: sidebarWidth, closed: !sidebarShown), force: true)
    }

    /// A swipe in from the leading edge brings a closed sidebar back, the way it
    /// does in the system's own apps.
    @objc private func edgeSwiped(_ gesture: UIScreenEdgePanGestureRecognizer) {
        guard gesture.state == .recognized else { return }
        Haptics.selection()
        toggleSidebar()
    }

    /// Whether this window has a rail to reveal at all.
    private var windowHasSidebar: Bool {
        view.bounds.width > view.bounds.height && view.bounds.width >= PadLayout.railWindowMinimum
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
        apply(PadLayout.resolve(window: size, rail: sidebarWidth, closed: !sidebarShown))
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
        guard view.bounds.width > view.bounds.height,
              view.bounds.width >= PadLayout.railWindowMinimum else { return }
        sidebarShown.toggle()
        ClientSettings.padSidebarShown = sidebarShown
        apply(PadLayout.resolve(window: view.bounds.size, rail: sidebarWidth, closed: !sidebarShown))
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
        apply(PadLayout.resolve(window: view.bounds.size, rail: proposed, closed: false))
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
        let canHaveSidebar = view.bounds.width > view.bounds.height
            && view.bounds.width >= PadLayout.railWindowMinimum
        let shows = canHaveSidebar && !sidebarShown
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
        hideDetailColumn {
            for screen in nav.viewControllers { self.installedWayBack[ObjectIdentifier(screen)] = nil }
            nav.setViewControllers([], animated: false)
            self.detachChildren(of: self.detail)
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
                host.setRailCarriesPost(layout.chrome == .rail)
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
        chrome.setRows(rows())
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
    private func apply(_ resolved: PadLayout, force: Bool = false) {
        guard force || resolved != layout else { return }
        let reshaped = !force && (resolved.chrome != layout.chrome
            || resolved.frame != layout.frame
            || resolved.showsDetail != layout.showsDetail)
        layout = resolved
        chrome.apply(form: TabChromeBar.Form(resolved.chrome), metrics: resolved.metrics)
        layoutChrome()
        contentLeading.constant = resolved.railWidth
        if reshaped { refreshWayBack() }
        applySelection()
        applySidebarButton()
        applyBoard()
        applySafeArea()
    }

    private func layoutChrome() {
        NSLayoutConstraint.deactivate(chromeConstraints)
        let metrics = layout.metrics
        chrome.isHidden = layout.chrome == .rail && layout.railWidth == 0
        chromeConstraints = layout.chrome == .rail
            ? [chrome.leadingAnchor.constraint(equalTo: view.leadingAnchor),
               chrome.topAnchor.constraint(equalTo: view.topAnchor),
               chrome.bottomAnchor.constraint(equalTo: view.bottomAnchor),
               chrome.widthAnchor.constraint(equalToConstant: layout.railWidth)]
            : [chrome.centerXAnchor.constraint(equalTo: view.centerXAnchor),
               chrome.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                                              constant: -PadLayout.barLift(for: layout.frame)),
               chrome.heightAnchor.constraint(equalToConstant: metrics.barHeight),
               chrome.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -40).priority(.defaultHigh),
               chrome.widthAnchor.constraint(lessThanOrEqualToConstant: metrics.barWidth)]
        NSLayoutConstraint.activate(chromeConstraints)
        view.bringSubviewToFront(chrome)
    }

    /// Whether a post is open over the board at all.
    private var detailOnScreen: Bool { tabUsesDetail && detailHasScreens }

    /// The column's width when it is open: the room beside the board where the
    /// window has it, the whole content area where it doesn't.
    private var openDetailWidth: CGFloat {
        if layout.showsDetail { return layout.detailWidth ?? 0 }
        let width = contentArea.layoutFrame.width
        return width > 0 ? width : max(0, view.bounds.width - layout.railWidth)
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
        let appears = detailColumn.isHidden || detailWidth.constant <= 0
        detailColumn.isHidden = false
        divider.isHidden = !beside
        setPrimaryBesideDetail(beside)
        let animating = !UIAccessibility.isReduceMotionEnabled
        if appears, animating {
            detail.alpha = 0
            detailColumn.transform = beside ? .identity : CGAffineTransform(translationX: 32, y: 0)
        }
        detailWidth.constant = openDetailWidth
        guard animating else {
            detail.alpha = 1
            detailColumn.transform = .identity
            view.layoutIfNeeded()
            return
        }
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
            self.detailWidth.constant = 0
            self.detailColumn.isHidden = true
            completion()
        }
        guard animated, !UIAccessibility.isReduceMotionEnabled, !detailColumn.isHidden else {
            // Called from a layout pass as often as from a tap, so the column is
            // collapsed by its constraints alone: laying out here would re-enter
            // the pass that asked for it.
            setPrimaryBesideDetail(false)
            finish()
            return
        }
        setPrimaryBesideDetail(false)
        UIView.animate(withDuration: Self.transitionDuration * 0.85, delay: 0,
                       usingSpringWithDamping: 0.95, initialSpringVelocity: 0.1,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.detailWidth.constant = 0
            self.view.layoutIfNeeded()
            self.detail.alpha = self.layout.showsDetail ? 0 : 1
        } completion: { _ in
            self.detail.alpha = 1
            finish()
        }
    }

    private func applySelection() {
        guard controllers.indices.contains(selectedIndex) else { return }
        show(controllers[selectedIndex], in: primary)
        showDetailIfAny()
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
        for controller in children {
            guard let nav = controller as? UINavigationController else { continue }
            for screen in nav.viewControllers {
                screen.view.clearBottomBar(clearance)
            }
        }
        for screen in details.values.flatMap(\.viewControllers) {
            screen.view.clearBottomBar(clearance)
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
        applySafeArea()
    }

    private func detailStack(for tab: TabItem) -> StatusNavigationController {
        if let existing = details[tab] { return existing }
        let nav = StatusNavigationController()
        details[tab] = nav
        return nav
    }
}

extension PadTabsController: UIGestureRecognizerDelegate {
    /// The edge swipe only answers to a closed sidebar in a window that could
    /// hold one — everywhere else the screen keeps its own edge gestures, such
    /// as the way back out of a pushed page.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer is UIScreenEdgePanGestureRecognizer else { return true }
        return windowHasSidebar && !sidebarShown
    }
}

extension PadLayout {
    /// How far the floating bar sits above the window's bottom edge: the room a
    /// mini has for it is a little tighter than a 13-inch window's.
    static func barLift(for frame: Frame) -> CGFloat {
        frame == .mini ? 10 : 12
    }
}
