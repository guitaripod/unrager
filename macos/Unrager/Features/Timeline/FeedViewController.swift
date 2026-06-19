import AppKit
import Combine
import UnragerKit

/// An `NSTableView` that invokes `onReturn` when Return / Enter is pressed on
/// the selection, so a feed row opens its thread by keyboard like the Mac
/// conventions expect.
final class KeyedTableView: NSTableView {
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let returnKeys: Set<UInt16> = [36, 76]
        if returnKeys.contains(event.keyCode), selectedRow >= 0 {
            onReturn?()
            return
        }
        super.keyDown(with: event)
    }
}

/// Routes feed-originated navigation up to the window controller.
@MainActor
protocol FeedNavigator: AnyObject {
    func openThread(for tweet: Tweet)
    func openThread(id: String)
    func openProfile(handle: String)
    func openLikers(for tweet: Tweet)
    func presentStream(title: String, makeStream: @escaping () -> AsyncThrowingStream<TokenEvent, any Error>)
    func compose(replyingTo tweet: Tweet?)
    func presentPostcard(for tweet: Tweet)
}

/// The reusable tweet feed: an `NSTableView` driven by a `TimelineViewModel`,
/// with infinite scroll, a header supplementary row, right-click LLM context
/// menus, and selection → thread / author → profile navigation. Mirrors the
/// iOS `FeedViewController`.
@MainActor
class FeedViewController: NSViewController {
    weak var navigator: (any FeedNavigator)?

    let viewModel: TimelineViewModel
    let tableView = KeyedTableView()
    private let scrollView = NSScrollView()
    private let emptyState = EmptyStateView()
    private let loadingIndicator = NSProgressIndicator()
    private let collectingLabel = NSTextField(labelWithString: "")
    private let collectingStack = NSStackView()
    private let collectingView = MetalCollectingView()
    private var collecting: (Int, Int)?
    let api = AppEnvironment.shared.api

    private var tweets: [Tweet] = []
    private var footerState: TimelineViewModel.FooterState = .none
    private var lastErrorText: String?
    private var cancellables = Set<AnyCancellable>()

    /// Tweet ids the server has confirmed as already-seen — those rows render
    /// dimmed. Gated on `MacSettings.seenDimming`.
    private var seenIDs = Set<String>()
    /// Ids queued to be reported via `markSeen`; flushed in batches as rows
    /// scroll into view.
    private var pendingSeen = Set<String>()
    private var seenFlushTask: Task<Void, Never>?

    /// An optional view shown as the first row (profile header).
    var headerView: NSView? { didSet { reloadHeaderRow() } }
    private var hasHeader: Bool { headerView != nil }

    /// A trailing footer row appears once a load settles into an
    /// end-of-feed / caught-up state and there is at least one tweet to anchor it.
    private var hasFooter: Bool { footerState != .none && !tweets.isEmpty }
    private var footerRowIndex: Int { tweets.count + (hasHeader ? 1 : 0) }

    init(viewModel: TimelineViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let background = BackgroundView(color: DesignSystem.Color.background)
        background.onAppearanceChange = { [weak self] in self?.tableView.reloadData() }
        view = background
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureTable()
        configureEmptyState()
        bind()
        viewModel.first()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if tableView.numberOfRows > 0 {
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<tableView.numberOfRows))
        }
    }

    private func configureTable() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tweet"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.style = .plain
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection = true
        tableView.usesAutomaticRowHeights = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.menu = makeContextMenu()
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)
        tableView.onReturn = { [weak self] in self?.openSelected() }

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = true
        scrollView.contentView.postsBoundsChangedNotifications = true

        view.addManaged(scrollView)
        scrollView.pinEdges(to: view)

        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    private func configureEmptyState() {
        emptyState.isHidden = true
        emptyState.onRetry = { [weak self] in self?.viewModel.refresh() }
        view.addManaged(emptyState)
        emptyState.pinEdges(to: view)

        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .regular
        loadingIndicator.isDisplayedWhenStopped = false

        let collectingSpinner = NSProgressIndicator()
        collectingSpinner.style = .spinning
        collectingSpinner.controlSize = .small
        collectingSpinner.startAnimation(nil)
        collectingLabel.font = DesignSystem.Typography.body()
        collectingLabel.textColor = DesignSystem.Color.secondaryLabel
        collectingStack.orientation = .horizontal
        collectingStack.alignment = .centerY
        collectingStack.spacing = DesignSystem.Spacing.s
        collectingStack.addArrangedSubview(collectingSpinner)
        collectingStack.addArrangedSubview(collectingLabel)
        collectingStack.isHidden = true

        view.addManaged(loadingIndicator)
        view.addManaged(collectingStack)
        NSLayoutConstraint.activate([
            loadingIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            collectingStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            collectingStack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        collectingView.isHidden = true
        view.addManaged(collectingView)
        collectingView.pinEdges(to: view)
    }

    private func bind() {
        viewModel.tweets
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tweets in self?.apply(tweets) }
            .store(in: &cancellables)

        viewModel.isLoading
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateChrome() }
            .store(in: &cancellables)

        viewModel.errorMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in self?.handleError(message) }
            .store(in: &cancellables)

        viewModel.collectingProgress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] progress in
                self?.collecting = progress
                self?.updateChrome()
            }
            .store(in: &cancellables)

        viewModel.footerState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self, self.footerState != state else { return }
                self.footerState = state
                self.tableView.reloadData()
            }
            .store(in: &cancellables)
    }

    /// Reports the unread count (tweets not yet server-confirmed seen) so the
    /// window can show an aggregate badge, mirroring the TUI's `N↑`. Only
    /// meaningful on feeds with seen tracking.
    var onUnreadChange: ((Int) -> Void)?

    private func apply(_ newTweets: [Tweet]) {
        let added = newTweets.filter { tweet in !tweets.contains { $0.restID == tweet.restID } }
        // Keep the viewport fixed when the network result replaces the cache
        // seed while the user has scrolled, so tweets don't jump under them.
        let scrolled = !tweets.isEmpty && !newTweets.isEmpty && scrollView.contentView.bounds.origin.y > 1
        let anchor = scrolled ? topRowAnchor() : nil
        tweets = newTweets
        if !newTweets.isEmpty { lastErrorText = nil }
        tableView.reloadData()
        if let anchor { restoreRowAnchor(anchor) }
        updateChrome()
        reconcileSeen(added.map(\.restID))
        reportUnread()
    }

    /// The id of the topmost visible row and its distance below the viewport
    /// top — the anchor for a scroll-stable reload.
    private func topRowAnchor() -> (id: String, offset: CGFloat)? {
        let visible = scrollView.contentView.bounds
        let rows = tableView.rows(in: visible)
        guard rows.location != NSNotFound, rows.location >= 0, rows.location < tweets.count else { return nil }
        let rect = tableView.rect(ofRow: rows.location)
        return (tweets[rows.location].restID, rect.minY - visible.minY)
    }

    private func restoreRowAnchor(_ anchor: (id: String, offset: CGFloat)) {
        guard let row = tweets.firstIndex(where: { $0.restID == anchor.id }) else { return }
        tableView.layoutSubtreeIfNeeded()
        let target = max(0, tableView.rect(ofRow: row).minY - anchor.offset)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: target))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Feeds where seen-dimming is meaningful: For-You hides seen tweets
    /// server-side already, so dimming only matters on Following and Mentions.
    private var supportsSeenTracking: Bool {
        switch viewModel.source {
        case .home(let following, _): return following
        case .mentions: return true
        default: return false
        }
    }

    /// On load, asks the server which freshly-fetched ids are already read so
    /// they render dimmed from the first frame (matching iOS). Checks run
    /// concurrently since the API offers no batch read-check.
    private func reconcileSeen(_ ids: [String]) {
        guard MacSettings.seenDimming, supportsSeenTracking, !ids.isEmpty else { return }
        let api = self.api
        Task { [weak self] in
            let confirmed = await withTaskGroup(of: String?.self) { group -> [String] in
                for id in ids {
                    group.addTask { ((try? await api.checkSeen(id: id)) == true) ? id : nil }
                }
                var hits: [String] = []
                for await result in group { if let result { hits.append(result) } }
                return hits
            }
            guard let self, !confirmed.isEmpty else { return }
            self.seenIDs.formUnion(confirmed)
            self.applySeenDimming()
            self.reportUnread()
        }
    }

    private func reportUnread() {
        guard supportsSeenTracking, MacSettings.seenDimming else { onUnreadChange?(0); return }
        let unread = tweets.reduce(into: 0) { count, tweet in
            if !seenIDs.contains(tweet.restID) { count += 1 }
        }
        onUnreadChange?(unread)
    }

    /// Centralizes empty/loading/error chrome: a centered spinner while a feed
    /// (or feed switch) is loading, and the illustrated empty/error state only
    /// once a load has settled — so switching feeds no longer flashes "Nothing
    /// here yet" for a frame.
    func updateChrome() {
        guard tweets.isEmpty else {
            emptyState.isHidden = true
            loadingIndicator.stopAnimation(nil)
            collectingStack.isHidden = true
            hideCollecting()
            return
        }
        if viewModel.awaitingQuery {
            loadingIndicator.stopAnimation(nil)
            collectingStack.isHidden = true
            hideCollecting()
            emptyState.show(symbol: "magnifyingglass", title: "Search X", subtitle: "Type a query to begin.")
        } else if let collecting, collectingView.isAvailable {
            emptyState.isHidden = true
            loadingIndicator.stopAnimation(nil)
            collectingStack.isHidden = true
            showCollecting(collected: collecting.0, target: collecting.1)
        } else if let collecting {
            emptyState.isHidden = true
            loadingIndicator.stopAnimation(nil)
            collectingStack.isHidden = false
            collectingLabel.stringValue = "Collecting tweets… \(collecting.0)/\(collecting.1)"
        } else if viewModel.isLoading.value || !viewModel.hasLoadedOnce {
            emptyState.isHidden = true
            collectingStack.isHidden = true
            hideCollecting()
            loadingIndicator.startAnimation(nil)
        } else if let error = lastErrorText {
            loadingIndicator.stopAnimation(nil)
            collectingStack.isHidden = true
            hideCollecting()
            emptyState.show(symbol: "exclamationmark.triangle", title: "Something went wrong",
                            subtitle: error, showRetry: true)
        } else {
            loadingIndicator.stopAnimation(nil)
            collectingStack.isHidden = true
            hideCollecting()
            emptyState.show(symbol: "tray", title: "Nothing here yet",
                            subtitle: "Pull to refresh or try again.", showRetry: true)
        }
    }

    /// Reveals the full-window Metal collecting state, driving the latest
    /// progress into the shader and starting its display link.
    private func showCollecting(collected: Int, target: Int) {
        collectingView.update(collected: collected, target: target)
        if collectingView.isHidden {
            collectingView.isHidden = false
            collectingView.start()
        }
    }

    /// Pauses and hides the Metal collecting state so it draws nothing while
    /// not visible.
    private func hideCollecting() {
        guard !collectingView.isHidden else { return }
        collectingView.isHidden = true
        collectingView.stop()
    }

    private func handleError(_ message: String) {
        lastErrorText = message
        if tweets.isEmpty { updateChrome() }
    }

    func refresh() { viewModel.refresh() }

    /// Scrolls to the top of the feed (the unread badge's jump action).
    func scrollToTop() {
        guard tableView.numberOfRows > 0 else { return }
        tableView.scrollRowToVisible(0)
    }

    /// Opens tapped media in a full-window viewer — a zoomable photo gallery, or
    /// the native player for video / GIF — instead of navigating into the thread.
    private func openMedia(_ tweet: Tweet, at tappedIndex: Int) {
        guard let window = view.window else { return }
        if let video = tweet.media.enumerated().first(where: { $0.element.isVideo }) {
            let loops = { if case .animatedGif = video.element.kind { return true } else { return false } }()
            MediaViewerWindowController.presentVideo(
                tweetID: tweet.restID, mediaIndex: video.offset,
                fallbackURL: video.element.videoURL, loops: loops, over: window)
            return
        }
        let photoIndices = tweet.media.enumerated().compactMap { index, media -> Int? in
            if case .photo = media.kind { return index } else { return nil }
        }
        guard !photoIndices.isEmpty else { navigator?.openThread(for: tweet); return }
        let start = min(max(0, tappedIndex), photoIndices.count - 1)
        MediaViewerWindowController.presentPhotos(
            tweetID: tweet.restID, photoIndices: photoIndices, startIndex: start, over: window)
    }

    private func reloadHeaderRow() {
        tableView.reloadData()
    }

    private func contentWidth() -> CGFloat {
        let total = scrollView.contentView.bounds.width
        let inset: CGFloat = 44 + DesignSystem.Spacing.l + DesignSystem.Spacing.m + DesignSystem.Spacing.l
        return max(200, total - inset)
    }

    // MARK: - Scroll

    @objc private func scrolled() {
        let visible = tableView.rows(in: scrollView.contentView.documentVisibleRect)
        guard visible.length > 0 else { return }
        let last = visible.location + visible.length - 1
        let tweetIndex = hasHeader ? last - 1 : last
        viewModel.loadMoreIfNeeded(currentIndex: tweetIndex)
        markVisibleSeen(rows: visible)
    }

    // MARK: - Read tracking

    private func markVisibleSeen(rows: NSRange) {
        guard MacSettings.seenDimming else { return }
        var fresh: [String] = []
        for row in rows.location..<(rows.location + rows.length) {
            guard let tweet = tweet(atRow: row) else { continue }
            let id = tweet.restID
            if !seenIDs.contains(id), !pendingSeen.contains(id) {
                pendingSeen.insert(id)
                fresh.append(id)
            }
        }
        guard !fresh.isEmpty else { return }
        scheduleSeenFlush()
    }

    private func scheduleSeenFlush() {
        guard seenFlushTask == nil else { return }
        seenFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            await self?.flushSeen()
        }
    }

    private func flushSeen() async {
        seenFlushTask = nil
        let batch = pendingSeen
        guard !batch.isEmpty else { return }
        pendingSeen.removeAll()
        do {
            _ = try await api.markSeen(ids: Array(batch))
            seenIDs.formUnion(batch)
            applySeenDimming()
            reportUnread()
        } catch {
            AppLogger.shared.debug("markSeen failed: \(error)", category: .timeline)
        }
    }

    /// Re-dims only the rows now known seen, without a full data reload.
    private func applySeenDimming() {
        let visible = tableView.rows(in: scrollView.contentView.documentVisibleRect)
        guard visible.length > 0 else { return }
        for row in visible.location..<(visible.location + visible.length) {
            guard let tweet = tweet(atRow: row),
                  let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? TweetRowView
            else { continue }
            cell.animator().alphaValue = seenIDs.contains(tweet.restID) ? 0.55 : 1.0
        }
    }

    // MARK: - Selection

    @objc private func rowDoubleClicked() {
        let row = tableView.clickedRow
        guard let tweet = tweet(atRow: row) else { return }
        navigator?.openThread(for: tweet)
    }

    /// The tweet under the current selection, used by keyboard commands.
    var selectedTweet: Tweet? {
        tweet(atRow: tableView.selectedRow)
    }

    /// Opens the selected tweet's thread (Return key / menu).
    func openSelected() {
        guard let tweet = selectedTweet else { return }
        navigator?.openThread(for: tweet)
    }

    /// Likes the selected tweet (menu / ⌘L).
    func likeSelected() {
        guard let tweet = selectedTweet else { return }
        toggleLike(tweet)
    }

    /// Replies to the selected tweet (menu / shortcut).
    func replySelected() {
        guard let tweet = selectedTweet else { return }
        navigator?.compose(replyingTo: tweet)
    }

    func tweet(atRow row: Int) -> Tweet? {
        let index = hasHeader ? row - 1 : row
        guard index >= 0, index < tweets.count else { return nil }
        return tweets[index]
    }

    // MARK: - Engagement

    func toggleLike(_ tweet: Tweet) {
        let liking = !tweet.favorited
        cell(for: tweet)?.applyOptimisticLike(liking, baseCount: tweet.likeCount)
        Task {
            do {
                _ = liking ? try await api.like(tweetID: tweet.restID)
                           : try await api.unlike(tweetID: tweet.restID)
            } catch {
                cell(for: tweet)?.applyOptimisticLike(!liking, baseCount: tweet.likeCount)
                AppLogger.shared.warn("like toggle failed: \(error)", category: .timeline)
            }
        }
    }

    /// Finds the currently-displayed cell for a tweet, or nil if it's offscreen.
    private func cell(for tweet: Tweet) -> TweetRowView? {
        guard let index = tweets.firstIndex(where: { $0.restID == tweet.restID }) else { return nil }
        let row = hasHeader ? index + 1 : index
        return tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? TweetRowView
    }

    // MARK: - Context menu

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    private func tweetForContextMenu() -> Tweet? {
        tweet(atRow: tableView.clickedRow)
    }
}

extension FeedViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        tweets.count + (hasHeader ? 1 : 0) + (hasFooter ? 1 : 0)
    }
}

extension FeedViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if hasHeader, row == 0 {
            return headerView
        }
        if hasFooter, row == footerRowIndex {
            return footerCell()
        }
        let cell = tableView.makeView(withIdentifier: TweetRowView.reuseID, owner: self) as? TweetRowView
            ?? makeRow()
        guard let tweet = tweet(atRow: row) else { return cell }
        let seen = MacSettings.seenDimming && seenIDs.contains(tweet.restID)
        cell.configure(with: tweet, imagesEnabled: AppSettings.imagesEnabled,
                       contentWidth: contentWidth(), seen: seen)
        cell.onTapAuthor = { [weak self] in self?.navigator?.openProfile(handle: tweet.author.handle) }
        cell.onTapQuoted = { [weak self] in
            if let quoted = tweet.quotedTweet { self?.navigator?.openThread(for: quoted) }
        }
        cell.onTapPhoto = { [weak self] index in self?.openMedia(tweet, at: index) }
        cell.onTapVideo = { [weak self] in self?.openMedia(tweet, at: 0) }
        cell.onTapPoll = { [weak self] in self?.navigator?.openThread(for: tweet) }
        cell.onLike = { [weak self] in self?.toggleLike(tweet) }
        cell.onReply = { [weak self] in self?.navigator?.compose(replyingTo: tweet) }
        return cell
    }

    private func makeRow() -> TweetRowView {
        let row = TweetRowView()
        row.identifier = TweetRowView.reuseID
        return row
    }

    /// The trailing end-of-feed / caught-up footer. The caught-up state is
    /// tappable to retry paging (an empty append left the cursor alive).
    private func footerCell() -> NSView {
        let id = NSUserInterfaceItemIdentifier("feedFooter")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? FeedFooterView ?? {
            let made = FeedFooterView()
            made.identifier = id
            made.onRetry = { [weak self] in self?.viewModel.loadMoreIfNeeded(currentIndex: (self?.tweets.count ?? 1) - 1) }
            return made
        }()
        cell.configure(state: footerState)
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if hasHeader && row == 0 { return false }
        if hasFooter && row == footerRowIndex { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("tweetRowBg")
        let view = tableView.makeView(withIdentifier: id, owner: self) as? SelectableRowView
            ?? SelectableRowView(identifier: id)
        return view
    }
}

/// The trailing feed footer: "You're all caught up" when the cursor is
/// exhausted, or a tappable "Scroll to retry" when an empty append left the
/// cursor alive. Mirrors the TUI's end-of-timeline header states.
final class FeedFooterView: NSTableCellView {
    var onRetry: (() -> Void)?
    private let label = NSTextField(labelWithString: "")
    private var isRetry = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = DesignSystem.Typography.metric()
        label.textColor = DesignSystem.Color.secondaryLabel
        label.alignment = .center
        addManaged(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.topAnchor.constraint(equalTo: topAnchor, constant: DesignSystem.Spacing.l),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -DesignSystem.Spacing.l),
        ])
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(tapped)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(state: TimelineViewModel.FooterState) {
        switch state {
        case .endOfFeed:
            isRetry = false
            label.stringValue = "You're all caught up"
            label.textColor = DesignSystem.Color.secondaryLabel
        case .caughtUp:
            isRetry = true
            label.stringValue = "Caught up · scroll or click to retry"
            label.textColor = DesignSystem.Color.accent
        case .none:
            isRetry = false
            label.stringValue = ""
        }
    }

    @objc private func tapped() { if isRetry { onRetry?() } }
}

/// A row background that paints a subtle accent tint behind the selected tweet,
/// so single-click selection reads clearly over the opaque tweet cards.
final class SelectableRowView: NSTableRowView {
    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isEmphasized: Bool {
        get { false }
        set {}
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        DesignSystem.Color.accent.withAlphaComponent(0.16).setFill()
        bounds.fill()
        DesignSystem.Color.accent.withAlphaComponent(0.9).setFill()
        NSRect(x: 0, y: 0, width: 3, height: bounds.height).fill()
    }
}

extension FeedViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let tweet = tweetForContextMenu() else { return }

        let askSub = NSMenu()
        for preset in AskPreset.allCases {
            let item = NSMenuItem(title: preset.title, action: #selector(askAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = AskInvocation(tweetID: tweet.restID, preset: preset)
            askSub.addItem(item)
        }
        let askItem = NSMenuItem(title: "Ask", action: nil, keyEquivalent: "")
        askItem.image = DesignSystem.icon("sparkles", pointSize: 14)
        askItem.submenu = askSub
        menu.addItem(askItem)

        let translate = NSMenuItem(title: "Translate", action: #selector(translateAction(_:)), keyEquivalent: "")
        translate.target = self
        translate.image = DesignSystem.icon("character.bubble", pointSize: 14)
        translate.representedObject = tweet.restID
        menu.addItem(translate)

        let like = NSMenuItem(title: tweet.favorited ? "Unlike" : "Like",
                              action: #selector(likeAction(_:)), keyEquivalent: "")
        like.target = self
        like.image = DesignSystem.icon(tweet.favorited ? "heart.slash" : "heart", pointSize: 14)
        like.representedObject = tweet
        menu.addItem(like)

        let reply = NSMenuItem(title: "Reply", action: #selector(replyAction(_:)), keyEquivalent: "")
        reply.target = self
        reply.image = DesignSystem.icon("arrowshape.turn.up.left", pointSize: 14)
        reply.representedObject = tweet
        menu.addItem(reply)

        if tweet.likeCount > 0 {
            let likedBy = NSMenuItem(title: "Liked by…", action: #selector(likedByAction(_:)), keyEquivalent: "")
            likedBy.target = self
            likedBy.image = DesignSystem.icon("person.2", pointSize: 14)
            likedBy.representedObject = tweet
            menu.addItem(likedBy)
        }

        menu.addItem(.separator())

        if let saveMedia = saveMediaItem(for: tweet) {
            menu.addItem(saveMedia)
        }

        let share = NSMenuItem(title: "Share…", action: #selector(shareAction(_:)), keyEquivalent: "")
        share.target = self
        share.image = DesignSystem.icon("square.and.arrow.up", pointSize: 14)
        share.representedObject = tweet.url
        menu.addItem(share)

        let postcard = NSMenuItem(title: "Postcard…", action: #selector(postcardAction(_:)), keyEquivalent: "")
        postcard.target = self
        postcard.image = DesignSystem.icon("photo.badge.plus", pointSize: 14)
        postcard.representedObject = tweet
        menu.addItem(postcard)

        menu.addItem(.separator())

        let open = NSMenuItem(title: "Open in X", action: #selector(openAction(_:)), keyEquivalent: "")
        open.target = self
        open.image = DesignSystem.icon("safari", pointSize: 14)
        open.representedObject = tweet.url
        menu.addItem(open)

        let copy = NSMenuItem(title: "Copy link", action: #selector(copyAction(_:)), keyEquivalent: "")
        copy.target = self
        copy.image = DesignSystem.icon("link", pointSize: 14)
        copy.representedObject = tweet.url
        menu.addItem(copy)

        let fixup = NSMenuItem(title: "Copy fixupx link", action: #selector(fixupxAction(_:)), keyEquivalent: "")
        fixup.target = self
        fixup.image = DesignSystem.icon("link.badge.plus", pointSize: 14)
        fixup.representedObject = "https://fixupx.com/\(tweet.author.handle)/status/\(tweet.restID)"
        menu.addItem(fixup)
    }

    private struct AskInvocation { let tweetID: String; let preset: AskPreset }

    @objc private func askAction(_ sender: NSMenuItem) {
        guard let invocation = sender.representedObject as? AskInvocation else { return }
        let api = api
        navigator?.presentStream(title: invocation.preset.title) {
            api.askStream(tweetID: invocation.tweetID, preset: invocation.preset)
        }
    }

    @objc private func translateAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        let api = api
        navigator?.presentStream(title: "Translation") { api.translateStream(tweetID: id) }
    }

    @objc private func likeAction(_ sender: NSMenuItem) {
        guard let tweet = sender.representedObject as? Tweet else { return }
        toggleLike(tweet)
    }

    @objc private func replyAction(_ sender: NSMenuItem) {
        guard let tweet = sender.representedObject as? Tweet else { return }
        navigator?.compose(replyingTo: tweet)
    }

    @objc private func openAction(_ sender: NSMenuItem) {
        guard let urlString = sender.representedObject as? String, let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func copyAction(_ sender: NSMenuItem) {
        guard let urlString = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urlString, forType: .string)
    }

    @objc private func fixupxAction(_ sender: NSMenuItem) {
        guard let urlString = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urlString, forType: .string)
    }

    @objc private func likedByAction(_ sender: NSMenuItem) {
        guard let tweet = sender.representedObject as? Tweet else { return }
        navigator?.openLikers(for: tweet)
    }

    @objc private func postcardAction(_ sender: NSMenuItem) {
        guard let tweet = sender.representedObject as? Tweet else { return }
        navigator?.presentPostcard(for: tweet)
    }

    @objc private func shareAction(_ sender: NSMenuItem) {
        guard let urlString = sender.representedObject as? String, let url = URL(string: urlString) else { return }
        let row = tableView.clickedRow
        let anchor = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) ?? tableView
        let picker = NSSharingServicePicker(items: [url])
        let rect = NSRect(x: anchor.bounds.midX, y: anchor.bounds.midY, width: 1, height: 1)
        picker.show(relativeTo: rect, of: anchor, preferredEdge: .minY)
    }

    /// The raw `tweet.media` offsets of saveable (photo / video / GIF)
    /// attachments. The media proxy addresses media by this flat index, across
    /// photos and videos alike.
    private struct SaveTarget { let index: Int; let isVideo: Bool }

    private func saveTargets(for tweet: Tweet) -> [SaveTarget] {
        tweet.media.enumerated().compactMap { index, media in
            switch media.kind {
            case .photo, .video, .animatedGif: return SaveTarget(index: index, isVideo: media.isVideo)
            default: return nil
            }
        }
    }

    /// One Save item for a lone attachment, or a "Save Media" submenu with
    /// "Save all (N)" plus a per-item list when a tweet carries several. Mirrors
    /// the iOS `saveMediaMenu`.
    private func saveMediaItem(for tweet: Tweet) -> NSMenuItem? {
        let targets = saveTargets(for: tweet)
        guard !targets.isEmpty else { return nil }
        if targets.count == 1 {
            let only = targets[0]
            let item = NSMenuItem(title: only.isVideo ? "Save Video…" : "Save Image…",
                                  action: #selector(saveSingleAction(_:)), keyEquivalent: "")
            item.target = self
            item.image = DesignSystem.icon("square.and.arrow.down", pointSize: 14)
            item.representedObject = SaveInvocation(tweet: tweet, targets: targets)
            return item
        }

        let submenu = NSMenu()
        let saveAll = NSMenuItem(title: "Save All (\(targets.count))",
                                 action: #selector(saveAllAction(_:)), keyEquivalent: "")
        saveAll.target = self
        saveAll.image = DesignSystem.icon("square.and.arrow.down.on.square", pointSize: 14)
        saveAll.representedObject = SaveInvocation(tweet: tweet, targets: targets)
        submenu.addItem(saveAll)
        submenu.addItem(.separator())
        for (position, target) in targets.enumerated() {
            let item = NSMenuItem(title: "\(target.isVideo ? "Video" : "Image") \(position + 1)…",
                                  action: #selector(saveSingleAction(_:)), keyEquivalent: "")
            item.target = self
            item.image = DesignSystem.icon(target.isVideo ? "arrow.down.circle" : "square.and.arrow.down", pointSize: 14)
            item.representedObject = SaveInvocation(tweet: tweet, targets: [target])
            submenu.addItem(item)
        }
        let saveMedia = NSMenuItem(title: "Save Media", action: nil, keyEquivalent: "")
        saveMedia.image = DesignSystem.icon("square.and.arrow.down", pointSize: 14)
        saveMedia.submenu = submenu
        return saveMedia
    }

    private final class SaveInvocation {
        let tweet: Tweet
        let targets: [SaveTarget]
        init(tweet: Tweet, targets: [SaveTarget]) { self.tweet = tweet; self.targets = targets }
    }

    @objc private func saveSingleAction(_ sender: NSMenuItem) {
        guard let invocation = sender.representedObject as? SaveInvocation,
              let target = invocation.targets.first else { return }
        let tweet = invocation.tweet
        let sourceURL = api.mediaURL(tweetID: tweet.restID, index: target.index)
        let suggestedExt = target.isVideo ? "mp4" : (sourceURL.pathExtension.isEmpty ? "jpg" : sourceURL.pathExtension)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(tweet.author.handle)-\(tweet.restID).\(suggestedExt)"
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: view.window ?? NSApp.keyWindow ?? NSWindow()) { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            self?.downloadMedia(from: sourceURL, to: destination)
        }
    }

    /// Saves every attachment into a user-chosen directory, named by handle, id,
    /// and ordinal — one folder prompt rather than a panel per file.
    @objc private func saveAllAction(_ sender: NSMenuItem) {
        guard let invocation = sender.representedObject as? SaveInvocation else { return }
        let tweet = invocation.tweet
        let targets = invocation.targets
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Save All"
        panel.message = "Choose a folder to save \(targets.count) attachments"
        panel.beginSheetModal(for: view.window ?? NSApp.keyWindow ?? NSWindow()) { [weak self] response in
            guard response == .OK, let directory = panel.url, let self else { return }
            for (position, target) in targets.enumerated() {
                let source = self.api.mediaURL(tweetID: tweet.restID, index: target.index)
                let ext = target.isVideo ? "mp4" : (source.pathExtension.isEmpty ? "jpg" : source.pathExtension)
                let destination = directory.appendingPathComponent(
                    "\(tweet.author.handle)-\(tweet.restID)-\(position + 1).\(ext)")
                self.downloadMedia(from: source, to: destination, reportFailure: false)
            }
        }
    }

    private func downloadMedia(from source: URL, to destination: URL, reportFailure: Bool = true) {
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: source)
                try data.write(to: destination)
                AppLogger.shared.info("saved media to \(destination.lastPathComponent)", category: .media)
            } catch {
                AppLogger.shared.warn("save media failed: \(error)", category: .media)
                guard reportFailure, let window = view.window else { return }
                let alert = NSAlert()
                alert.messageText = "Couldn't save media"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.beginSheetModal(for: window, completionHandler: nil)
            }
        }
    }
}
