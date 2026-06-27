import AppKit
import UnragerKit

/// Shows a conversation: ancestors above, the focal tweet, then replies. When
/// the feed already holds the tapped tweet it is passed in and rendered
/// instantly (the focal row), with ancestors streaming in above and replies
/// below under an animated diff that keeps the focal tweet's on-screen position
/// stable. Opened by id alone (notifications / likers), it shows a spinner first.
@MainActor
final class ThreadViewController: NSViewController {
    weak var navigator: (any FeedNavigator)?

    private let tweetID: String
    private let api = AppEnvironment.shared.api
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyState = EmptyStateView()
    private let loadingIndicator = NSProgressIndicator()

    private var rows: [Tweet] = []
    private var focalID: String?
    private var ownHandle: String?
    private var cursor: String?
    private var loading = false
    private var loadedOnce = false
    private var exhausted = false
    private var rowIDs = Set<String>()

    /// Creates a thread for an already-loaded tweet, rendering it instantly.
    init(tweet: Tweet, navigator: (any FeedNavigator)?) {
        self.tweetID = tweet.restID
        self.navigator = navigator
        self.rows = [tweet]
        self.focalID = tweet.restID
        self.rowIDs = [tweet.restID]
        super.init(nibName: nil, bundle: nil)
    }

    /// Creates a thread known only by id (notifications / likers taps); the focal
    /// tweet streams in with the rest of the conversation.
    init(tweetID: String, navigator: (any FeedNavigator)?) {
        self.tweetID = tweetID
        self.navigator = navigator
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
        title = "Thread"
        configureTable()
        emptyState.isHidden = true
        emptyState.onRetry = { [weak self] in self?.load() }
        view.addManaged(emptyState)
        emptyState.pinEdges(to: view)

        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .regular
        loadingIndicator.isDisplayedWhenStopped = false
        view.addManaged(loadingIndicator)
        NSLayoutConstraint.activate([
            loadingIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        ownHandle = AppEnvironment.shared.currentHandle
        if ownHandle == nil { resolveOwnHandle() }
        if rows.isEmpty { loadingIndicator.startAnimation(nil) }
        load()
    }

    private func resolveOwnHandle() {
        Task { [weak self] in
            let me = await AppEnvironment.shared.whoami()
            guard let self, let me else { return }
            self.ownHandle = me.handle
            if self.loadedOnce { self.tableView.reloadData() }
        }
    }

    private func configureTable() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tweet"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = .zero
        tableView.style = .plain
        tableView.selectionHighlightStyle = .none
        tableView.usesAutomaticRowHeights = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)
        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        view.addManaged(scrollView)
        scrollView.pinEdges(to: view)

        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    private func load() { load(reset: true) }

    private func load(reset: Bool) {
        guard !loading, reset || !exhausted else { return }
        loading = true
        if reset { cursor = nil; exhausted = false }
        emptyState.isHidden = true
        Task {
            defer { loading = false }
            do {
                let thread = try await api.thread(id: tweetID, cursor: reset ? nil : cursor)
                cursor = thread.cursor
                if thread.cursor == nil { exhausted = true }
                if reset {
                    applyResolved(thread)
                } else {
                    appendReplies(thread.replies)
                }
                loadedOnce = true
                loadingIndicator.stopAnimation(nil)
                if rows.isEmpty {
                    emptyState.show(symbol: "bubble.left.and.bubble.right", title: "No conversation")
                }
            } catch {
                loadingIndicator.stopAnimation(nil)
                if rows.isEmpty {
                    emptyState.show(symbol: "exclamationmark.triangle", title: "Couldn't load thread",
                                    subtitle: error.localizedDescription, showRetry: true)
                }
                AppLogger.shared.warn("thread load failed: \(error)", category: .thread)
            }
        }
    }

    /// Inserts the resolved conversation around the focal tweet. When the focal
    /// was rendered instantly, ancestors are prepended and the scroll offset is
    /// compensated by their height so the focal tweet does not jump.
    private func applyResolved(_ thread: ThreadView) {
        focalID = thread.focal.restID
        let ancestors = thread.ancestors
        let replies = dedupedReplies(thread.replies, excluding: Set(ancestors.map(\.restID) + [thread.focal.restID]))

        let hadInstantFocal = rows.count == 1 && rows.first?.restID == thread.focal.restID
        let newRows = ancestors + [thread.focal] + replies
        rowIDs = Set(newRows.map(\.restID))

        guard hadInstantFocal, !ancestors.isEmpty else {
            rows = newRows
            tableView.reloadData()
            return
        }

        let focalRectBefore = tableView.rect(ofRow: 0)
        let visibleBefore = scrollView.contentView.bounds.origin.y
        rows = newRows
        tableView.reloadData()
        tableView.layoutSubtreeIfNeeded()
        let focalRectAfter = tableView.rect(ofRow: ancestors.count)
        let shift = focalRectAfter.minY - focalRectBefore.minY
        let target = NSPoint(x: 0, y: visibleBefore + shift)
        scrollView.contentView.setBoundsOrigin(target)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func appendReplies(_ replies: [Tweet]) {
        let fresh = dedupedReplies(replies, excluding: rowIDs)
        guard !fresh.isEmpty else { return }
        rowIDs.formUnion(fresh.map(\.restID))
        rows.append(contentsOf: fresh)
        tableView.reloadData()
    }

    private func dedupedReplies(_ replies: [Tweet], excluding ids: Set<String>) -> [Tweet] {
        var seen = ids
        var result: [Tweet] = []
        for reply in replies where seen.insert(reply.restID).inserted {
            result.append(reply)
        }
        return result
    }

    @objc private func scrolled() {
        let visible = tableView.rows(in: scrollView.contentView.documentVisibleRect)
        guard visible.length > 0 else { return }
        let last = visible.location + visible.length - 1
        if last >= rows.count - 3 { load(reset: false) }
    }

    @objc private func rowDoubleClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < rows.count else { return }
        let tweet = rows[row]
        guard tweet.restID != focalID else { return }
        navigator?.openThread(for: tweet)
    }

    private func contentWidth() -> CGFloat {
        let total = scrollView.contentView.bounds.width
        let inset: CGFloat = 44 + DesignSystem.Spacing.l + DesignSystem.Spacing.m + DesignSystem.Spacing.l
        return max(200, total - inset)
    }

    private var focalIndex: Int? { rows.firstIndex { $0.restID == focalID } }

    /// Reply depth used for the thread's indentation: a direct reply to the focal
    /// is level 1, a reply-to-a-reply level 2, and so on, so the structure reads
    /// at a glance. Ancestors and the focal stay flush (level 0). Mirrors iOS's
    /// `ThreadViewController.indentLevel(for:)`, walking `inReplyToTweetID` within
    /// the loaded reply set.
    private func indentLevel(for tweet: Tweet, isReply: Bool) -> Int {
        guard isReply else { return 0 }
        let replyIDs = Set(focalIndex.map { rows.suffix(from: $0 + 1).map(\.restID) } ?? [])
        let byID = Dictionary(rows.map { ($0.restID, $0) }, uniquingKeysWith: { a, _ in a })
        var level = 1
        var current = tweet.inReplyToTweetID
        while let parent = current, parent != focalID, replyIDs.contains(parent), level < 5 {
            level += 1
            current = byID[parent]?.inReplyToTweetID
        }
        return level
    }
}

extension ThreadViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
}

extension ThreadViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: TweetRowView.reuseID, owner: self) as? TweetRowView
            ?? makeRow()
        let tweet = rows[row]
        let isFocal = tweet.restID == focalID
        let isReply = focalIndex.map { row > $0 } ?? false
        let isOwn = ownHandle.map { tweet.author.handle.caseInsensitiveCompare($0) == .orderedSame } ?? false
        let indent = indentLevel(for: tweet, isReply: isReply)
        cell.configure(with: tweet, imagesEnabled: AppSettings.imagesEnabled,
                       contentWidth: contentWidth() - CGFloat(min(indent, 3)) * ThreadRailView.step,
                       isReply: isReply, isFocal: isFocal, inThread: true,
                       indentLevel: indent,
                       showAnalytics: isFocal && isOwn)
        cell.onTapAuthor = { [weak self] in self?.navigator?.openProfile(handle: tweet.author.handle) }
        cell.onLike = { [weak self] in self?.toggleLike(tweet) }
        cell.onReply = { [weak self] in self?.navigator?.compose(replyingTo: tweet) }
        cell.onShowLikers = { [weak self] in self?.navigator?.openLikers(for: tweet) }
        cell.onTapQuoted = { [weak self] in
            if let quoted = tweet.quotedTweet { self?.navigator?.openThread(for: quoted) }
        }
        cell.onTapPhoto = { [weak self] index in self?.openMedia(tweet, at: index) }
        cell.onTapVideo = { [weak self] in self?.openMedia(tweet, at: 0) }
        cell.onTapPoll = { [weak self] in
            guard tweet.restID != self?.focalID else { return }
            self?.navigator?.openThread(for: tweet)
        }
        return cell
    }

    private func makeRow() -> TweetRowView {
        let row = TweetRowView()
        row.identifier = TweetRowView.reuseID
        return row
    }

    /// Opens tapped media in the full-window viewer — a zoomable photo gallery
    /// or the native player for video / GIF.
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
        guard !photoIndices.isEmpty else {
            if tweet.restID != focalID { navigator?.openThread(for: tweet) }
            return
        }
        let start = min(max(0, tappedIndex), photoIndices.count - 1)
        MediaViewerWindowController.presentPhotos(
            tweetID: tweet.restID, photoIndices: photoIndices, startIndex: start, over: window)
    }

    private func toggleLike(_ tweet: Tweet) {
        let liking = !tweet.favorited
        cell(for: tweet)?.applyOptimisticLike(liking, baseCount: tweet.likeCount)
        Task {
            do {
                _ = liking ? try await api.like(tweetID: tweet.restID)
                           : try await api.unlike(tweetID: tweet.restID)
            } catch {
                cell(for: tweet)?.applyOptimisticLike(!liking, baseCount: tweet.likeCount)
                AppLogger.shared.warn("thread like failed: \(error)", category: .thread)
            }
        }
    }

    /// The displayed row view for a tweet, or nil if it's offscreen — lets a like
    /// flip the heart in place instead of re-fetching the whole conversation.
    private func cell(for tweet: Tweet) -> TweetRowView? {
        guard let index = rows.firstIndex(where: { $0.restID == tweet.restID }) else { return nil }
        return tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? TweetRowView
    }

    private func tweetForContextMenu() -> Tweet? {
        let row = tableView.clickedRow
        guard row >= 0, row < rows.count else { return nil }
        return rows[row]
    }
}

extension ThreadViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let tweet = tweetForContextMenu() else { return }

        if tweet.likeCount > 0 {
            let likedBy = NSMenuItem(title: "Liked by…", action: #selector(likedByMenu(_:)), keyEquivalent: "")
            likedBy.target = self
            likedBy.image = DesignSystem.icon("person.2", pointSize: 14)
            likedBy.representedObject = tweet
            menu.addItem(likedBy)
        }

        let postcard = NSMenuItem(title: "Postcard…", action: #selector(postcardMenu(_:)), keyEquivalent: "")
        postcard.target = self
        postcard.image = DesignSystem.icon("photo.badge.plus", pointSize: 14)
        postcard.representedObject = tweet
        menu.addItem(postcard)

        menu.addItem(.separator())

        let open = NSMenuItem(title: "Open in X", action: #selector(openMenu(_:)), keyEquivalent: "")
        open.target = self
        open.image = DesignSystem.icon("safari", pointSize: 14)
        open.representedObject = tweet.url
        menu.addItem(open)

        let copy = NSMenuItem(title: "Copy link", action: #selector(copyMenu(_:)), keyEquivalent: "")
        copy.target = self
        copy.image = DesignSystem.icon("link", pointSize: 14)
        copy.representedObject = tweet.url
        menu.addItem(copy)
    }

    @objc private func likedByMenu(_ sender: NSMenuItem) {
        guard let tweet = sender.representedObject as? Tweet else { return }
        navigator?.openLikers(for: tweet)
    }

    @objc private func postcardMenu(_ sender: NSMenuItem) {
        guard let tweet = sender.representedObject as? Tweet else { return }
        navigator?.presentPostcard(for: tweet)
    }

    @objc private func openMenu(_ sender: NSMenuItem) {
        guard let urlString = sender.representedObject as? String, let url = URL(string: urlString) else { return }
        BrowserOpener.open(url)
    }

    @objc private func copyMenu(_ sender: NSMenuItem) {
        guard let urlString = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urlString, forType: .string)
    }
}
