import UIKit
import UnragerKit

/// The iPad's tabs: a rail down the side or a bar along the bottom, around the
/// chosen tab. The tab's own feed fills whatever is left — as a board of cards
/// where the window allows — and a post, a profile or a list of people opens by
/// growing out of the card that was tapped and settling over the board, which
/// never moves: no cell reflows and nothing behind it is rebuilt.
final class PadTabsController: UIViewController {
    /// A tab was chosen from the rail or the bar.
    var onSelect: ((Int) -> Void)?
    /// The tab already showing was tapped again.
    var onReselect: ((Int) -> Void)?
    /// The rail's post button, where a sidebar has room for one.
    var onCompose: (() -> Void)?

    private(set) var selectedIndex = 0
    private(set) var layout = PadLayout(chrome: .bottom, railWidth: 0)

    /// The sidebar's width and whether it is open; both survive a relaunch, the
    /// way the system's own sidebars do.
    private var sidebarWidth = PadTabsController.initialSidebarWidth
    private var sidebarShown = ClientSettings.padSidebarShown

    /// The width the sidebar opens at: the reader's own, or what a screenshot
    /// run asks for so its drags start from the same place every time.
    private static var initialSidebarWidth: CGFloat {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["UNRAGER_PAD_SIDEBAR"], let width = Double(raw) {
            return min(max(width, PadLayout.narrowestRailWidth), PadLayout.widestRailWidth)
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
    /// The panel a post grows into: `detailSurface` carries the shadow and the
    /// frame that animates, `detail` clips the screen inside it.
    private let scrim = UIView()
    private let detailSurface = UIView()
    private let detail = UIView()

    /// Whether the open tab's own list spreads into a board. The board never
    /// folds: what a tap opens grows over it, so the reader's place in the feed
    /// survives.
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
    private var contentBottom: NSLayoutConstraint!

    /// How long the column change takes. A screenshot run can stretch it, so a
    /// still frame can catch a card in flight.
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
        contentBottom = contentArea.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        NSLayoutConstraint.activate([
            contentLeading,
            contentBottom,
            contentArea.topAnchor.constraint(equalTo: view.topAnchor),
            contentArea.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        view.addManaged(primary)
        NSLayoutConstraint.activate([
            primary.topAnchor.constraint(equalTo: contentArea.topAnchor),
            primary.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor),
            primary.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
            primary.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
        ])

        detailSurface.isHidden = true
        detailSurface.layer.shadowColor = UIColor.black.cgColor
        detailSurface.layer.shadowOpacity = 0.18
        detailSurface.layer.shadowRadius = 28
        detailSurface.layer.shadowOffset = CGSize(width: 0, height: 10)
        scrim.backgroundColor = UIColor.black.withAlphaComponent(0.18)
        scrim.alpha = 0
        scrim.isHidden = true
        scrim.translatesAutoresizingMaskIntoConstraints = true
        scrim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(scrim)
        scrim.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(scrimTapped)))

        detailSurface.backgroundColor = DesignSystem.Color.background
        detailSurface.translatesAutoresizingMaskIntoConstraints = true
        detailSurface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(detailSurface)
        detail.clipsToBounds = true
        detailSurface.addManaged(detail)
        detail.pinEdges(to: detailSurface)
        let drag = UIPanGestureRecognizer(target: self, action: #selector(panelDragged(_:)))
        drag.delegate = self
        detailSurface.addGestureRecognizer(drag)
        apply(PadLayout.resolve(window: view.bounds.size, rail: sidebarWidth, closed: !sidebarShown), force: true)
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
        applySafeArea()
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        apply(PadLayout.resolve(window: size, rail: sidebarWidth, closed: !sidebarShown))
        #if DEBUG
        if ProcessInfo.processInfo.environment["UNRAGER_LAYOUT_LOG"] != nil, size != loggedSize {
            loggedSize = size
            AppLogger.shared.info(
                "pad layout \(layout) window=\(String(describing: view.window?.bounds)) "
                + "primary=\(primary.frame) detail=\(detail.frame) chrome=\(chrome.frame)",
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
        layoutPanel()
        applySelection()
        applySidebarButton()
    }

    /// Moves the tabs to `index` — the phone's `selectedIndex`, shared with the
    /// rail and the bar, so ⌘1…⌘5 land here too.
    func select(_ index: Int) {
        guard controllers.indices.contains(index) else { return }
        selectedIndex = index
        refreshRows()
        layoutPanel()
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
        sidebarWidth = ClientSettings.padSidebarWidth
        apply(PadLayout.resolve(window: view.bounds.size, rail: sidebarWidth, closed: !sidebarShown))
        applySidebarButton()
        animateLayout()
    }

    /// Narrows or widens the sidebar as its grip is dragged, with the columns
    /// taking up the difference.
    private func resizeSidebar(by travel: CGFloat) {
        guard layout.chrome == .rail, sidebarShown else { return }
        let proposed = min(max(sidebarWidth + travel, PadLayout.narrowestRailWidth), PadLayout.widestRailWidth)
        guard proposed != sidebarWidth else { return }
        sidebarWidth = proposed
        ClientSettings.padSidebarWidth = proposed
        apply(PadLayout.resolve(window: view.bounds.size, rail: proposed, closed: false))
        applyBoard()
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
    /// carries the standard way back — the way the system's sidebars do.
    private func applySidebarButton() {
        let shows = layout.chrome == .rail && !sidebarShown
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

    /// A post opened beside the list has no back button of its own, so it gets
    /// the button that puts the board back the way it was.
    private func giveCloseButton(to screen: UIViewController) {
        guard screen.navigationItem.leftBarButtonItem == nil,
              screen.navigationItem.leftBarButtonItems?.isEmpty != false else { return }
        screen.navigationItem.leftBarButtonItem = closeItem
    }

    private lazy var closeItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: DesignSystem.icon("xmark", pointSize: 15, weight: .semibold),
            primaryAction: UIAction { [weak self] _ in self?.closeDetail() })
        item.accessibilityLabel = "Close"
        return item
    }()

    /// Shrinks the open post back into its card, or off the edge when the card
    /// has scrolled away.
    func closeDetail() {
        guard tabs.indices.contains(selectedIndex), let nav = details[tabs[selectedIndex]] else { return }
        let feed = boardHost(in: (controllers[selectedIndex] as? UINavigationController)?.topViewController)
        let card = nav.viewControllers.compactMap { ($0 as? ThreadViewController)?.tweetID }
            .last.flatMap { feed?.visibleCell(for: $0) }
        let home = card.map { $0.convert($0.bounds, to: view) } ?? panelFrame.offsetBy(dx: 40, dy: 0)
        hidePanel(towards: home) {
            nav.setViewControllers([], animated: false)
            self.detachChildren(of: self.detail)
            self.detailSurface.isHidden = true
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

    /// Resolves the chrome, the board and the panel for a new window size.
    private func apply(_ resolved: PadLayout, force: Bool = false) {
        guard force || resolved != layout else { return }
        layout = resolved
        chrome.apply(form: TabChromeBar.Form(resolved.chrome))
        layoutChrome()
        contentLeading.constant = resolved.railWidth
        contentBottom.constant = 0
        layoutPanel()
        applySelection()
        applySidebarButton()
        applyBoard()
    }

    private func layoutChrome() {
        NSLayoutConstraint.deactivate(chromeConstraints)
        chrome.isHidden = layout.chrome == .rail && layout.railWidth == 0
        chromeConstraints = layout.chrome == .rail
            ? [chrome.leadingAnchor.constraint(equalTo: view.leadingAnchor),
               chrome.topAnchor.constraint(equalTo: view.topAnchor),
               chrome.bottomAnchor.constraint(equalTo: view.bottomAnchor),
               chrome.widthAnchor.constraint(equalToConstant: layout.railWidth)]
            : [chrome.centerXAnchor.constraint(equalTo: view.centerXAnchor),
               chrome.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
               chrome.heightAnchor.constraint(equalToConstant: TabChromeBar.bottomHeight),
               chrome.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -48).priority(.defaultHigh),
               chrome.widthAnchor.constraint(lessThanOrEqualToConstant: 560)]
        NSLayoutConstraint.activate(chromeConstraints)
        view.bringSubviewToFront(detailSurface)
        view.bringSubviewToFront(chrome)
    }

    /// Whether a post is open over the board at all.
    private var detailOnScreen: Bool { tabUsesDetail && detailHasScreens }

    /// Where the open post sits: the trailing column beside a board in a wide
    /// window, inset across the window in a narrow one — always over the feed,
    /// never beside it in a way that moves the feed.
    private var panelFrame: CGRect {
        if let width = layout.detailWidth {
            return CGRect(x: view.bounds.width - width - 12, y: 12,
                          width: width, height: view.bounds.height - 24)
        }
        // Without room beside the board the panel floats over it as a card:
        // inset on every side, clear of the navigation bar and above the tab
        // bar, so the feed stays visible around it and a tap outside puts it
        // away.
        let area = contentArea.layoutFrame
        guard !area.isEmpty else { return view.bounds.insetBy(dx: 16, dy: 16) }
        let side: CGFloat = 20
        let width = min(area.width - side * 2, 680)
        let top = area.minY + view.safeAreaInsets.top + 8
        let bottomInset = view.safeAreaInsets.bottom
            + (layout.chrome == .bottom ? TabChromeBar.bottomHeight + 24 : 16)
        let bottom = area.maxY - bottomInset
        return CGRect(x: area.midX - width / 2, y: top,
                      width: width, height: max(280, bottom - top))
    }

    /// A post opens as a card over the feed, not as another screen: it keeps its
    /// margins, dims what is behind it, and can be put away by tapping outside
    /// it, dragging it down from its bar, or its own close button.
    @objc private func scrimTapped() {
        closeDetail()
    }

    @objc private func panelDragged(_ gesture: UIPanGestureRecognizer) {
        let travel = gesture.translation(in: view).y
        switch gesture.state {
        case .changed:
            let offset = max(0, travel)
            detailSurface.transform = CGAffineTransform(translationX: 0, y: offset)
            scrim.alpha = 0.22 * max(0, 1 - offset / 240)
        case .ended, .cancelled:
            let fast = gesture.velocity(in: view).y > 900
            if travel > 120 || fast {
                detailSurface.transform = .identity
                closeDetail()
            } else {
                UIView.animate(withDuration: 0.28, delay: 0, usingSpringWithDamping: 0.85,
                               initialSpringVelocity: 0.2, options: [.allowUserInteraction]) {
                    self.detailSurface.transform = .identity
                    self.scrim.alpha = 0.22
                }
            }
        default:
            break
        }
    }

    private func layoutPanel() {
        guard detailOnScreen else {
            detailSurface.isHidden = true
            return
        }
        detailSurface.isHidden = false
        detailSurface.frame = panelFrame
        detailSurface.layer.cornerRadius = 24
        detailSurface.layer.cornerCurve = .continuous
        detail.layer.cornerRadius = 24
        detail.layer.cornerCurve = .continuous
    }

    /// Under a bar the screens keep their feet clear of it; beside a rail they
    /// run the full height.
    /// The bar floats over the page — no backdrop of its own beyond its glass —
    /// so every list inside a tab is given its height as a bottom inset: content
    /// scrolls under the glass, as it does under the system's bars, and its last
    /// row can always be brought clear.
    private func applySafeArea() {
        let clearance = layout.chrome == .bottom ? TabChromeBar.bottomClearance : 0
        for controller in children {
            guard let nav = controller as? UINavigationController else { continue }
            for screen in nav.viewControllers {
                screen.view.clearBottomBar(clearance)
            }
        }
    }

    // MARK: - Columns

    private func applySelection() {
        guard controllers.indices.contains(selectedIndex) else { return }
        show(controllers[selectedIndex], in: primary)
        showDetailIfAny()
        applySafeArea()
        applySidebarButton()
        applyBoard()
    }

    private func showDetailIfAny() {
        let nav = tabs.indices.contains(selectedIndex) ? details[tabs[selectedIndex]] : nil
        guard detailOnScreen, let nav, !nav.viewControllers.isEmpty else {
            detachChildren(of: detail)
            detailSurface.isHidden = true
            scrim.isHidden = true
            return
        }
        show(nav, in: detail)
        view.bringSubviewToFront(detailSurface)
        view.bringSubviewToFront(chrome)
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

    /// Shows `controller` over the board, replacing whatever was there. It grows
    /// out of the card that was tapped and settles as a panel; the board and
    /// every card on it stay exactly where they were.
    private func openInDetail(_ controller: UIViewController) {
        guard tabUsesDetail, tabs.indices.contains(selectedIndex) else { return }
        let nav = detailStack(for: tabs[selectedIndex])
        nav.setViewControllers([controller], animated: false)
        giveCloseButton(to: controller)
        let feed = boardHost(in: (controllers[selectedIndex] as? UINavigationController)?.topViewController)
        let card = (controller as? ThreadViewController).flatMap { thread in feed?.visibleCell(for: thread.tweetID) }
        showPanel(nav, growingFrom: card)
    }

    /// Grows the panel out of `card`, or drops it in when there is no card to
    /// grow from (a deep link, a notification).
    private func showPanel(_ nav: StatusNavigationController, growingFrom card: UIView?) {
        show(nav, in: detail)
        detailSurface.isHidden = false
        scrim.isHidden = false
        scrim.frame = view.bounds
        view.bringSubviewToFront(scrim)
        view.bringSubviewToFront(detailSurface)
        view.bringSubviewToFront(chrome)
        let target = panelFrame
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        guard !reduceMotion, let card else {
            detailSurface.frame = target
            detailSurface.layer.cornerRadius = 26
            detail.alpha = 1
            scrim.alpha = 0.22
            return
        }
        let source = card.convert(card.bounds, to: view)
        detailSurface.frame = source
        detailSurface.layer.cornerRadius = 18
        detail.alpha = 0
        UIView.animate(withDuration: Self.transitionDuration, delay: 0,
                       usingSpringWithDamping: 0.86, initialSpringVelocity: 0.2,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.detailSurface.frame = target
            self.detailSurface.layer.cornerRadius = 24
        }
        UIView.animate(withDuration: Self.transitionDuration * 0.7,
                       delay: Self.transitionDuration * 0.35,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.detail.alpha = 1
            self.scrim.alpha = 0.22
        }
    }

    /// The way back: the panel shrinks into `frame` and hands over to what it
    /// was covering.
    private func hidePanel(towards frame: CGRect, completion: @escaping () -> Void) {
        guard !UIAccessibility.isReduceMotionEnabled else {
            UIView.performWithoutAnimation(completion)
            return
        }
        UIView.animate(withDuration: Self.transitionDuration * 0.9, delay: 0,
                       usingSpringWithDamping: 0.92, initialSpringVelocity: 0.1,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.detailSurface.frame = frame
            self.detailSurface.layer.cornerRadius = 18
            self.detail.alpha = 0
            self.scrim.alpha = 0
        } completion: { _ in
            self.scrim.isHidden = true
            completion()
        }
    }

    private func detailStack(for tab: TabItem) -> StatusNavigationController {
        if let existing = details[tab] { return existing }
        let nav = StatusNavigationController()
        details[tab] = nav
        return nav
    }

    private func stack(for tab: TabItem) -> UIViewController? {
        zip(tabs, controllers).first { $0.0 == tab }?.1
    }
}

extension PadTabsController: UIGestureRecognizerDelegate {
    /// The drag follows a finger on the panel's own bar; a thread's list keeps
    /// its scroll.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer is UIPanGestureRecognizer else { return true }
        return touch.location(in: detailSurface).y <= 120
    }
}

extension NSLayoutConstraint {
    /// A priority set inline, for a width that yields to a cap.
    func priority(_ priority: UILayoutPriority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
