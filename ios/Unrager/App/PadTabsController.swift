import UIKit
import UnragerKit

/// The iPad's tabs: a rail down the side or a bar along the bottom, around the
/// chosen tab, and — when the window is wide enough — a second column where a
/// post, a profile or a list of people opens beside the list instead of
/// covering it. A window too narrow for two columns puts those screens on the
/// tab's own stack, exactly as the phone does.
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
    private let columns = UIStackView()
    private let primary = UIView()
    private let detail = UIView()
    private let placeholder = DetailPlaceholderView()
    private let divider = HairlineView()

    /// Whether this tab has screens that open beside the list; Settings is a
    /// column of forms and reads better across the whole window.
    private var tabUsesDetail: Bool {
        tabs.indices.contains(selectedIndex) && tabs[selectedIndex].offersDetailColumn
    }

    /// Whether the second column is on screen at all.
    private var showsDetail: Bool { layout.showsDetail && tabUsesDetail }

    private var chromeConstraints: [NSLayoutConstraint] = []
    private var columnConstraints: [NSLayoutConstraint] = []
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

        view.addLayoutGuide(contentArea)
        contentLeading = contentArea.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        NSLayoutConstraint.activate([
            contentLeading,
            contentArea.topAnchor.constraint(equalTo: view.topAnchor),
            contentArea.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentArea.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        columns.axis = .horizontal
        columns.spacing = PadLayout.columnGap
        columns.distribution = .fill
        columns.addArrangedSubview(primary)
        columns.addArrangedSubview(detail)
        view.addManaged(columns)

        detail.addManaged(placeholder)
        placeholder.pinEdges(to: detail)

        view.addManaged(divider)
        NSLayoutConstraint.activate([
            divider.topAnchor.constraint(equalTo: view.topAnchor),
            divider.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
        ])

        NSLayoutConstraint.activate([
            columns.topAnchor.constraint(equalTo: view.topAnchor),
            columns.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            columns.centerXAnchor.constraint(equalTo: contentArea.centerXAnchor),
        ])
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
        chrome.setItems(chromeItems(), selected: selectedIndex)
        layoutColumns()
        applySelection()
        applySidebarButton()
    }

    /// Moves the tabs to `index` — the phone's `selectedIndex`, shared with the
    /// rail and the bar, so ⌘1…⌘5 land here too.
    func select(_ index: Int) {
        guard controllers.indices.contains(index) else { return }
        let showedDetail = showsDetail
        selectedIndex = index
        chrome.update(chromeItems(), selected: index)
        if showsDetail != showedDetail { layoutColumns() }
        applySelection()
        applySidebarButton()
    }

    /// Re-reads each tab's `tabBarItem` — a Home tab that renames itself to
    /// Following, and the unread count — so the chrome never disagrees with the
    /// screens behind it.
    func refreshItems() {
        chrome.update(chromeItems(), selected: selectedIndex)
    }

    private func choose(_ index: Int) {
        guard index != selectedIndex else { return }
        onSelect?(index)
    }

    // MARK: - Sidebar

    /// Closes the sidebar, or opens it again — the button the rail carries, and
    /// ⌘\ from anywhere.
    func toggleSidebar() {
        guard layout.chrome == .rail else { return }
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

    private lazy var revealButton: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: DesignSystem.icon("sidebar.leading", pointSize: 17),
            primaryAction: UIAction { [weak self] _ in self?.toggleSidebar() })
        item.accessibilityLabel = "Show sidebar"
        return item
    }()

    private func chromeItems() -> [TabChromeBar.Item] {
        zip(tabs, controllers).map { tab, controller in
            let item = controller.tabBarItem
            return TabChromeBar.Item(
                title: item?.title ?? tab.title,
                image: item?.image ?? DesignSystem.icon(tab.symbol),
                badge: item?.badgeValue)
        }
    }

    // MARK: - Placement

    /// Resolves the chrome, the columns and the safe area for a new window size.
    private func apply(_ resolved: PadLayout, force: Bool = false) {
        guard force || resolved != layout else { return }
        let wasShowingDetail = layout.showsDetail
        layout = resolved
        chrome.apply(form: TabChromeBar.Form(resolved.chrome))
        layoutChrome()
        layoutColumns()
        if wasShowingDetail, !resolved.showsDetail { foldDetailIntoStacks() }
        applySelection()
        applySidebarButton()
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
        view.bringSubviewToFront(divider)
        view.bringSubviewToFront(chrome)
    }

    private func layoutColumns() {
        NSLayoutConstraint.deactivate(columnConstraints)
        contentLeading.constant = layout.railWidth
        detail.isHidden = !showsDetail
        divider.isHidden = !showsDetail
        if let primaryWidth = layout.primaryWidth, let detailWidth = layout.detailWidth, showsDetail {
            columnConstraints = [
                primary.widthAnchor.constraint(equalToConstant: primaryWidth),
                detail.widthAnchor.constraint(equalToConstant: detailWidth),
            ]
        } else {
            columnConstraints = [primary.widthAnchor.constraint(equalTo: contentArea.widthAnchor)]
        }
        NSLayoutConstraint.activate(columnConstraints)
    }

    /// Under a bar the screens keep their feet clear of it; beside a rail they
    /// run the full height.
    private func applySafeArea() {
        let bottom = layout.chrome == .bottom ? TabChromeBar.bottomClearance : 0
        for controller in children {
            controller.additionalSafeAreaInsets.bottom = bottom
        }
    }

    // MARK: - Columns

    private func applySelection() {
        guard controllers.indices.contains(selectedIndex) else { return }
        show(controllers[selectedIndex], in: primary)
        showDetailIfAny()
        applySafeArea()
        applySidebarButton()
    }

    private func showDetailIfAny() {
        let nav = tabs.indices.contains(selectedIndex) ? details[tabs[selectedIndex]] : nil
        guard showsDetail, let nav, !nav.viewControllers.isEmpty else {
            detachChildren(of: detail)
            placeholder.isHidden = false
            return
        }
        show(nav, in: detail)
        placeholder.isHidden = true
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
                guard let self, self.showsDetail,
                      Self.opensBesideTheList(pushed) else { return false }
                self.openInDetail(pushed)
                return true
            }
        }
    }

    /// Shows `controller` in this tab's detail column, replacing whatever it was
    /// showing: the column follows the list, it doesn't build a history of its
    /// own. Pushes made from inside it still stack there.
    private func openInDetail(_ controller: UIViewController) {
        guard showsDetail, tabs.indices.contains(selectedIndex) else { return }
        let nav = detailStack(for: tabs[selectedIndex])
        let arrives = nav.view.superview !== detail
        nav.setViewControllers([controller], animated: false)
        show(nav, in: detail)
        placeholder.isHidden = true
        guard arrives, !UIAccessibility.isReduceMotionEnabled else { return }
        nav.view.alpha = 0
        nav.view.transform = CGAffineTransform(translationX: 12, y: 0)
        UIView.animate(withDuration: 0.28, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0.2,
                       options: [.allowUserInteraction]) {
            nav.view.alpha = 1
            nav.view.transform = .identity
        }
    }

    private func detailStack(for tab: TabItem) -> StatusNavigationController {
        if let existing = details[tab] { return existing }
        let nav = StatusNavigationController()
        details[tab] = nav
        return nav
    }

    /// A window that lost its second column gives every detail screen back to
    /// the tab it belongs to, so nothing the reader opened is lost: the thread
    /// they were reading becomes the screen in front.
    private func foldDetailIntoStacks() {
        for (tab, nav) in details {
            let screens = nav.viewControllers
            guard !screens.isEmpty else { continue }
            nav.setViewControllers([], animated: false)
            guard let stack = stack(for: tab) as? UINavigationController else { continue }
            stack.setViewControllers(stack.viewControllers + screens, animated: false)
        }
        detachChildren(of: detail)
        placeholder.isHidden = false
    }

    private func stack(for tab: TabItem) -> UIViewController? {
        zip(tabs, controllers).first { $0.0 == tab }?.1
    }
}

/// What the detail column says before the first post is opened in it: a quiet
/// glyph and one line, never an empty pane.
private final class DetailPlaceholderView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        let glyph = UIImageView(image: DesignSystem.icon("rectangle.split.2x1", pointSize: 34, weight: .light))
        glyph.tintColor = DesignSystem.Color.tertiaryLabel
        glyph.contentMode = .scaleAspectFit
        let title = UILabel()
        title.text = "Nothing open"
        title.font = DesignSystem.Typography.name()
        title.textColor = DesignSystem.Color.secondaryLabel
        title.textAlignment = .center
        let subtitle = UILabel()
        subtitle.text = "A post you tap opens here,\nbeside the list."
        subtitle.font = DesignSystem.Typography.metric()
        subtitle.textColor = DesignSystem.Color.tertiaryLabel
        subtitle.textAlignment = .center
        subtitle.numberOfLines = 0
        let stack = UIStackView(arrangedSubviews: [glyph, title, subtitle])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = DesignSystem.Spacing.s
        stack.setCustomSpacing(DesignSystem.Spacing.m, after: glyph)
        addManaged(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
        ])
        isAccessibilityElement = true
        accessibilityLabel = "Nothing open. A post you tap opens here, beside the list."
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

extension NSLayoutConstraint {
    /// A priority set inline, for a width that yields to a cap.
    func priority(_ priority: UILayoutPriority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
