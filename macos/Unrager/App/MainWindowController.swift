import AppKit
import Combine
import UnragerKit

/// The single document window: a sidebar split view with a glass-backed source
/// list and a navigation-stack content area, wired to a toolbar (back, title,
/// search, refresh, compose).
@MainActor
final class MainWindowController: NSWindowController {
    private let splitViewController = NSSplitViewController()
    private let sidebar = SidebarViewController()
    private let content = ContentContainerViewController()

    private var currentItem: SidebarItem = .forYou
    private var searchProduct: SourceProduct = .top
    private var originals = false

    private var backItem: NSToolbarItem?
    private var titleItem: NSToolbarItem?
    private var searchItem: NSToolbarItem?
    private var originalsItem: NSToolbarItem?
    private var productItem: NSToolbarItem?
    private let searchField = NSSearchField()
    private let titleLabel = NSTextField(labelWithString: "For You")
    private let unreadBadge = NSButton()
    private var unreadItem: NSToolbarItem?
    private var unreadCount = 0
    private let originalsButton = NSButton()
    private let productPopup = NSPopUpButton()
    private let progressIndicator = NSProgressIndicator()
    private var feedCancellables: [AnyCancellable] = []
    private var fontScaleObserver: AnyCancellable?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Unrager"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 760, height: 520)
        self.init(window: window)
        configure()
        if !window.setFrameUsingName("UnragerMainWindow") {
            window.setContentSize(NSSize(width: 1180, height: 820))
            window.center()
        }
        if window.frame.width < window.minSize.width || window.frame.height < window.minSize.height {
            window.setContentSize(NSSize(width: 1180, height: 820))
            window.center()
        }
        window.setFrameAutosaveName("UnragerMainWindow")
    }

    /// Suppresses session patches while the session is being restored at launch,
    /// so applying the server's state doesn't immediately patch it back.
    private var restoringSession = false

    private func configure() {
        configureSplitView()
        configureToolbar()
        sidebar.delegate = self
        content.onStackChange = { [weak self] in self?.updateToolbar() }
        window?.contentViewController = splitViewController
        AppSettings.migrateAppearanceIfNeeded()
        applyAppearance(AppSettings.appearance)
        observeFontScale()
        AppEnvironment.shared.prefetchWhoami()
        select(.forYou)
        restoreSession()
        handleDebugLaunch()
    }

    /// Re-renders the always-visible chrome (toolbar title, sidebar) and the
    /// current content stack when the user changes their text size in Settings,
    /// so the scale applies without relaunching. Source switches rebuild VCs
    /// fresh, so only what's on screen needs the live nudge.
    private func observeFontScale() {
        fontScaleObserver = NotificationCenter.default.publisher(for: AppSettings.fontScaleDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyFontScale() }
    }

    private func applyFontScale() {
        titleLabel.font = DesignSystem.Typography.system(15, weight: .semibold)
        sidebar.restyle()
        for controller in content.stack { (controller as? Restylable)?.restyle() }
    }

    // MARK: - Session persistence

    /// Restores the last source / feed-mode / filter state from the server so
    /// the app cold-starts where the user (or the TUI) left off, sharing the
    /// single source of truth. Skipped under a DEBUG screenshot deep-link.
    private func restoreSession() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["UNRAGER_SCREEN"] != nil { return }
        #endif
        Task { [weak self] in
            guard let state = try? await AppEnvironment.shared.api.session() else { return }
            guard let self else { return }
            self.applyRestored(state)
        }
    }

    private func applyRestored(_ state: SessionState) {
        restoringSession = true
        defer { restoringSession = false }
        AppSettings.filterEnabled = state.filterEnabled
        originals = state.feedMode == .originals
        guard let source = state.currentSource, !content.canGoBack else {
            updateToolbar()
            return
        }
        switch source {
        case let .home(following):
            select(following ? .following : .forYou)
        case let .search(query, product):
            searchProduct = product
            select(.search)
            if !query.isEmpty, let feed = content.stack.first as? FeedViewController {
                searchField.stringValue = query
                feed.viewModel.updateSource(.search(query: query, product: product))
            }
        case .mentions:
            select(.mentions)
        case let .bookmarks(query):
            select(.bookmarks)
            if !query.isEmpty, let feed = content.stack.first as? FeedViewController {
                searchField.stringValue = query
                feed.viewModel.updateSource(.bookmarks(query: query))
            }
        case let .user(handle):
            openProfile(handle: handle)
        }
        updateToolbar()
    }

    /// Persists the current source / feed-mode / filter state to the server so
    /// the next launch (and the TUI) sees the same state.
    private func persistSession() {
        guard !restoringSession else { return }
        let patch = SessionPatch(
            currentSource: currentSourceKind(),
            feedMode: originals ? .originals : .all,
            filterEnabled: AppSettings.filterEnabled)
        Task { try? await AppEnvironment.shared.api.patchSession(patch) }
    }

    /// The `SourceKind` the server should record for the current root source.
    private func currentSourceKind() -> SourceKind? {
        switch currentItem {
        case .forYou: return .home(following: false)
        case .following: return .home(following: true)
        case .search:
            let query = (content.stack.first as? FeedViewController)
                .flatMap { if case let .search(q, _) = $0.viewModel.source { return q } else { return nil } } ?? ""
            return .search(query: query, product: searchProduct)
        case .mentions: return .mentions(target: nil)
        case .bookmarks:
            let query = (content.stack.first as? FeedViewController)
                .flatMap { if case let .bookmarks(q) = $0.viewModel.source { return q } else { return nil } } ?? ""
            return .bookmarks(query: query)
        case .notifications, .settings: return nil
        }
    }

    /// DEBUG-only deep links for screenshot QA, driven by environment variables
    /// (`UNRAGER_SCREEN` = thread|profile|compose|brief|ask|likers|search|
    /// notifications|settings|rubric|viewer|videoviewer, plus `UNRAGER_ARG`).
    private func handleDebugLaunch() {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        guard let screen = env["UNRAGER_SCREEN"] else { return }
        let arg = env["UNRAGER_ARG"] ?? ""
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            switch screen {
            case "thread": self.openThread(id: arg.isEmpty ? "2067859973229412359" : arg)
            case "threadinstant":
                let id = arg.isEmpty ? "2067859973229412359" : arg
                Task {
                    if let tweet = try? await AppEnvironment.shared.api.tweet(id: id) {
                        self.openThread(for: tweet)
                    } else {
                        self.openThread(id: id)
                    }
                }
            case "profile": self.openProfile(handle: arg.isEmpty ? "thdxr" : arg)
            case "compose": self.compose(replyingTo: nil)
            case "brief": self.presentStream(title: "Brief on @\(arg)") {
                AppEnvironment.shared.api.briefStream(handle: arg.isEmpty ? "thdxr" : arg)
            }
            case "ask": self.presentStream(title: "Explain") {
                AppEnvironment.shared.api.askStream(tweetID: arg.isEmpty ? "2067859973229412359" : arg, preset: .explain)
            }
            case "likers":
                let controller = LikersViewController(tweetID: arg.isEmpty ? "2067859973229412359" : arg, navigator: self)
                self.content.push(controller)
            case "search":
                self.select(.search)
                if !arg.isEmpty, let feed = self.content.stack.first as? FeedViewController {
                    self.searchField.stringValue = arg
                    feed.viewModel.updateSource(.search(query: arg, product: self.searchProduct))
                }
            case "viewer":
                if let window = self.window {
                    let id = arg.isEmpty ? "2067628940215062910" : arg
                    MediaViewerWindowController.presentPhotos(
                        tweetID: id, photoIndices: [0, 1], startIndex: 0, over: window)
                }
            case "videoviewer":
                if let window = self.window {
                    let id = arg.isEmpty ? "2067319270195990670" : arg
                    MediaViewerWindowController.presentVideo(
                        tweetID: id, mediaIndex: 0, fallbackURL: nil, loops: false, over: window)
                }
            case "notifications": self.select(.notifications)
            case "settings": self.select(.settings)
            case "rubric":
                self.select(.settings)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.content.topViewController?.presentAsSheet(FilterSettingsViewController())
                }
            default: break
            }
        }
        #endif
    }

    private func configureSplitView() {
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 280
        sidebarItem.canCollapse = true
        if #available(macOS 26.0, *) {
            sidebarItem.allowsFullHeightLayout = true
        }
        let contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = 480
        contentItem.holdingPriority = .defaultLow
        sidebarItem.holdingPriority = .init(260)
        splitViewController.addSplitViewItem(sidebarItem)
        splitViewController.addSplitViewItem(contentItem)
    }

    // MARK: - Toolbar

    private func configureToolbar() {
        let toolbar = NSToolbar(identifier: "UnragerToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        searchField.placeholderString = "Search X"
        searchField.target = self
        searchField.action = #selector(performSearch)
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = true
        titleLabel.font = DesignSystem.Typography.system(15, weight: .semibold)
        titleLabel.textColor = DesignSystem.Color.label

        unreadBadge.bezelStyle = .toolbar
        unreadBadge.target = self
        unreadBadge.action = #selector(scrollToFirstUnread)
        unreadBadge.contentTintColor = DesignSystem.Color.accent
        unreadBadge.toolTip = "Unread — click to jump to the top"
        unreadBadge.isHidden = true

        originalsButton.bezelStyle = .toolbar
        originalsButton.setButtonType(.toggle)
        originalsButton.image = DesignSystem.icon("line.3.horizontal.decrease.circle", pointSize: 14)
        originalsButton.alternateImage = DesignSystem.icon("line.3.horizontal.decrease.circle.fill", pointSize: 14)
        originalsButton.target = self
        originalsButton.action = #selector(toggleOriginalsAction)
        originalsButton.toolTip = "Originals only (hide replies / reposts / quotes)"

        productPopup.target = self
        productPopup.action = #selector(productChanged)
        productPopup.removeAllItems()
        for product in SourceProduct.allCases {
            productPopup.addItem(withTitle: product.apiValue)
        }
        productPopup.bezelStyle = .toolbar

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false

        window?.toolbar = toolbar
        window?.toolbarStyle = .unified
    }

    private func updateToolbar() {
        titleLabel.stringValue = content.currentTitle.isEmpty ? currentItem.title : content.currentTitle
        backItem?.isEnabled = content.canGoBack
        backItem?.isHidden = !content.canGoBack
        let onRoot = !content.canGoBack
        let searchVisible = (currentItem == .search || currentItem == .bookmarks) && onRoot
        searchItem?.isHidden = !searchVisible
        productItem?.isHidden = !(currentItem == .search && onRoot)
        let homeFeed = (currentItem == .forYou || currentItem == .following) && onRoot
        originalsItem?.isHidden = !homeFeed
        originalsButton.state = originals ? .on : .off
        productPopup.selectItem(at: SourceProduct.allCases.firstIndex(of: searchProduct) ?? 0)
        updateUnreadBadge()
    }

    // MARK: - Source selection

    private func select(_ item: SidebarItem) {
        currentItem = item
        sidebar.select(item)
        let root = makeRoot(for: item)
        if !(root is FeedViewController) {
            feedCancellables.removeAll()
            progressIndicator.stopAnimation(nil)
        }
        content.setRoot(root)
        updateToolbar()
        if item == .search {
            window?.makeFirstResponder(searchField)
        }
        persistSession()
    }

    private func makeRoot(for item: SidebarItem) -> NSViewController {
        switch item {
        case .forYou:
            return feed(.home(following: false, originals: originals), title: "For You")
        case .following:
            return feed(.home(following: true, originals: originals), title: "Following")
        case .search:
            searchField.placeholderString = "Search X"
            return feed(.search(query: "", product: searchProduct), title: "Search")
        case .mentions:
            return feed(.mentions, title: "Mentions")
        case .bookmarks:
            searchField.placeholderString = "Search bookmarks by keyword"
            return feed(.bookmarks(query: ""), title: "Bookmarks")
        case .notifications:
            let controller = NotificationsViewController(navigator: self)
            controller.title = "Notifications"
            return controller
        case .settings:
            let controller = SettingsViewController()
            controller.title = "Settings"
            controller.onAppearanceChange = { [weak self] mode in self?.applyAppearance(mode) }
            controller.onFilterChange = { [weak self] _ in self?.persistSession() }
            return controller
        }
    }

    private func feed(_ source: TimelineViewModel.Source, title: String) -> FeedViewController {
        let controller = FeedViewController(viewModel: TimelineViewModel(source: source))
        controller.title = title
        controller.navigator = self
        unreadCount = 0
        updateUnreadBadge()
        controller.onUnreadChange = { [weak self, weak controller] count in
            guard let self, controller === self.content.stack.first else { return }
            self.unreadCount = count
            self.updateUnreadBadge()
        }
        bindLoading(controller.viewModel)
        return controller
    }

    private func updateUnreadBadge() {
        let visible = unreadCount > 0 && !content.canGoBack
        unreadBadge.title = "\(unreadCount) unread"
        unreadBadge.isHidden = !visible
        unreadItem?.isHidden = !visible
    }

    @objc private func scrollToFirstUnread() {
        (content.stack.first as? FeedViewController)?.scrollToTop()
    }

    /// Binds a feed's loading state to the toolbar progress indicator.
    private func bindLoading(_ viewModel: TimelineViewModel) {
        feedCancellables.removeAll()
        viewModel.isLoading
            .combineLatest(viewModel.isRefreshing)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] loading, refreshing in
                if loading || refreshing {
                    self?.progressIndicator.startAnimation(nil)
                } else {
                    self?.progressIndicator.stopAnimation(nil)
                }
            }
            .store(in: &feedCancellables)
    }

    @objc private func performSearch() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        guard let feed = content.stack.first as? FeedViewController else { return }
        switch currentItem {
        case .bookmarks:
            feed.viewModel.updateSource(.bookmarks(query: query))
        default:
            feed.viewModel.updateSource(.search(query: query, product: searchProduct))
        }
        persistSession()
    }

    @objc private func toggleOriginalsAction() {
        originals.toggle()
        rerootHomeForOriginals()
        updateToolbar()
        persistSession()
    }

    private func rerootHomeForOriginals() {
        guard let feed = content.stack.first as? FeedViewController,
              !content.canGoBack else { return }
        switch currentItem {
        case .forYou:
            feed.viewModel.updateSource(.home(following: false, originals: originals))
        case .following:
            feed.viewModel.updateSource(.home(following: true, originals: originals))
        default:
            break
        }
    }

    @objc func toggleOriginals() {
        guard currentItem == .forYou || currentItem == .following, !content.canGoBack else { return }
        toggleOriginalsAction()
    }

    @objc private func productChanged() {
        searchProduct = SourceProduct.allCases[productPopup.indexOfSelectedItem]
        guard let feed = content.stack.first as? FeedViewController else { return }
        if case let .search(query, _) = feed.viewModel.source, !query.isEmpty {
            feed.viewModel.updateSource(.search(query: query, product: searchProduct))
        }
        persistSession()
    }

    // MARK: - Appearance

    private func applyAppearance(_ mode: AppearanceMode) {
        switch mode {
        case .system: window?.appearance = nil
        case .light: window?.appearance = NSAppearance(named: .aqua)
        case .dark: window?.appearance = NSAppearance(named: .darkAqua)
        }
    }

    // MARK: - Menu / shortcut actions

    @objc func refresh() {
        if let feed = content.topViewController as? FeedViewController {
            feed.refresh()
        } else if let notifications = content.topViewController as? NotificationsViewController {
            notifications.refresh()
        }
    }

    @objc func newCompose() {
        compose(replyingTo: nil)
    }

    @objc func goBack() {
        content.pop()
    }

    @objc func likeSelected() {
        (content.topViewController as? FeedViewController)?.likeSelected()
    }

    @objc func replySelected() {
        (content.topViewController as? FeedViewController)?.replySelected()
    }

    @objc func openSelectedThread() {
        (content.topViewController as? FeedViewController)?.openSelected()
    }

    @objc func askSelected() {
        guard let feed = content.topViewController as? FeedViewController,
              let tweet = feed.selectedTweet else { return }
        let api = AppEnvironment.shared.api
        presentStream(title: "Explain") { api.askStream(tweetID: tweet.restID, preset: .explain) }
    }

    @objc func translateSelected() {
        guard let feed = content.topViewController as? FeedViewController,
              let tweet = feed.selectedTweet else { return }
        let api = AppEnvironment.shared.api
        presentStream(title: "Translation") { api.translateStream(tweetID: tweet.restID) }
    }

    @objc func openMyProfile() {
        Task {
            do {
                let me = try await AppEnvironment.shared.api.whoami()
                openProfile(handle: me.handle)
            } catch {
                AppLogger.shared.warn("whoami failed: \(error)", category: .app)
            }
        }
    }

    @objc func selectForYou() { select(.forYou) }
    @objc func selectFollowing() { select(.following) }
    @objc func selectMentions() { select(.mentions) }
    @objc func selectBookmarks() { select(.bookmarks) }
    @objc func selectNotifications() { select(.notifications) }
    @objc func selectSearch() { select(.search) }
    @objc func openSettings() { select(.settings) }

    @objc func toggleSidebar() {
        splitViewController.toggleSidebar(nil)
    }

    // MARK: - Notifications

    /// Wires the notification service's deep-link routing and unread-count
    /// reporting to this window: tapped banners open the thread/profile here, and
    /// the unread count badges the sidebar's Notifications row. The Dock-tile
    /// badge is set by the service itself.
    func attachNotificationService() {
        let service = NotificationCenterService.shared
        service.onOpenTweet = { [weak self] id in self?.openThread(id: id) }
        service.onOpenProfile = { [weak self] handle in self?.openProfile(handle: handle) }
        service.onUnreadCount = { [weak self] count in self?.sidebar.setNotificationsBadge(count) }
    }
}

extension MainWindowController: SidebarDelegate {
    func sidebar(didSelect item: SidebarItem) {
        guard item != currentItem || content.canGoBack else {
            if item != currentItem { select(item) }
            return
        }
        select(item)
    }
}

extension MainWindowController: FeedNavigator {
    func openThread(for tweet: Tweet) {
        let controller = ThreadViewController(tweet: tweet, navigator: self)
        content.push(controller)
    }

    func openThread(id: String) {
        let controller = ThreadViewController(tweetID: id, navigator: self)
        content.push(controller)
    }

    func openProfile(handle: String) {
        let controller = ProfileViewController(handle: handle)
        controller.navigator = self
        content.push(controller)
    }

    func openLikers(for tweet: Tweet) {
        let controller = LikersViewController(tweetID: tweet.restID, navigator: self)
        content.push(controller)
    }

    func presentStream(title: String, makeStream: @escaping () -> AsyncThrowingStream<TokenEvent, any Error>) {
        let sheet = StreamSheetController(title: title, makeStream: makeStream)
        content.topViewController?.presentAsSheet(sheet)
    }

    func compose(replyingTo tweet: Tweet?) {
        let mode: ComposeViewController.Mode = tweet.map { .reply(to: $0) } ?? .new
        let composer = ComposeViewController(mode: mode)
        composer.onPosted = { [weak self] in self?.refresh() }
        content.topViewController?.presentAsSheet(composer)
    }

    func presentPostcard(for tweet: Tweet) {
        content.topViewController?.presentAsSheet(PostcardViewController(tweet: tweet))
    }
}

extension MainWindowController: NSToolbarDelegate {
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .backButton:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let button = NSButton(image: DesignSystem.icon("chevron.backward", pointSize: 14)!,
                                  target: self, action: #selector(goBack))
            button.bezelStyle = .toolbar
            item.view = button
            item.isEnabled = false
            backItem = item
            return item
        case .titleLabel:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = titleLabel
            titleItem = item
            return item
        case .unread:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = unreadBadge
            item.label = "Unread"
            unreadItem = item
            return item
        case .searchField:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            searchField.translatesAutoresizingMaskIntoConstraints = false
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
            item.view = searchField
            item.visibilityPriority = .high
            searchItem = item
            return item
        case .originals:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = originalsButton
            item.label = "Originals"
            originalsItem = item
            return item
        case .product:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = productPopup
            item.label = "Results"
            productItem = item
            return item
        case .loading:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = progressIndicator
            item.label = "Loading"
            return item
        case .refresh:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let button = NSButton(image: DesignSystem.icon("arrow.clockwise", pointSize: 14)!,
                                  target: self, action: #selector(refresh))
            button.bezelStyle = .toolbar
            item.view = button
            item.label = "Refresh"
            return item
        case .compose:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let button = NSButton(image: DesignSystem.icon("square.and.pencil", pointSize: 14)!,
                                  target: self, action: #selector(newCompose))
            button.bezelStyle = .toolbar
            button.contentTintColor = DesignSystem.Color.accent
            item.view = button
            item.label = "Compose"
            return item
        default:
            return nil
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .backButton, .titleLabel, .unread,
         .flexibleSpace, .loading, .originals, .product, .searchField, .refresh, .compose]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }
}

private extension NSToolbarItem.Identifier {
    static let backButton = NSToolbarItem.Identifier("back")
    static let titleLabel = NSToolbarItem.Identifier("title")
    static let unread = NSToolbarItem.Identifier("unread")
    static let searchField = NSToolbarItem.Identifier("search")
    static let originals = NSToolbarItem.Identifier("originals")
    static let product = NSToolbarItem.Identifier("product")
    static let loading = NSToolbarItem.Identifier("loading")
    static let refresh = NSToolbarItem.Identifier("refresh")
    static let compose = NSToolbarItem.Identifier("compose")
}
