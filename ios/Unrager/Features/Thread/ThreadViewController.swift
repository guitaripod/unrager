import UIKit
import AVKit
import Combine
import UnragerKit

/// A conversation: ancestors above the focal tweet, then replies. Reuses
/// `TweetCell`. Tapping a reply opens its own thread; the focal tweet is
/// emphasized with an absolute timestamp and (for the viewer's own tweets) a
/// post-analytics block.
///
/// When opened from the feed the focal `Tweet` is already in hand, so it renders
/// instantly — the screen never blanks. Ancestors stream in above and replies
/// below with an animated diff, and the focal tweet's on-screen position is
/// pinned when ancestors prepend so the view never jumps.
final class ThreadViewController: UIViewController {
    private let tweetID: String
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, String>!
    private var tweetsByID: [String: Tweet] = [:]
    private var replyOrder: [String] = []
    private var ancestorOrder: [String] = []
    private var focalID: String?
    /// When opened from a notification/permalink (by id), scroll to the focal
    /// tweet once the thread lands so the user starts on the post the
    /// notification is about, not the conversation root. Cleared after the
    /// first scroll. False for feed-opened threads (focal already at top).
    private var scrollToFocalOnLoad = false
    private var selfHandle: String?
    private var cursor: String?
    private var exhausted = false
    private var loadingMore = false
    private var didRenderFocal = false
    private var replySort: ReplySort = .conversation
    private let emptyState = EmptyStateView()
    private let loadingIndicator = UIActivityIndicatorView(style: .medium)

    private enum Section { case ancestors, focal, replies }

    /// Reply orderings offered by the sort control — the TUI's `s` cycle
    /// (newest / most liked / most replies / most reposts / most views) plus
    /// the server's natural conversation order as the default.
    private enum ReplySort: CaseIterable {
        case conversation, newest, likes, replies, reposts, views

        var title: String {
            switch self {
            case .conversation: return "Conversation"
            case .newest: return "Newest"
            case .likes: return "Most liked"
            case .replies: return "Most replies"
            case .reposts: return "Most reposts"
            case .views: return "Most views"
            }
        }
    }

    private lazy var registration = UICollectionView.CellRegistration<TweetCell, String> {
        [weak self] cell, _, id in
        guard let self, let tweet = self.tweetsByID[id] else { return }
        let width = self.collectionView.bounds.width - 44 - DesignSystem.Spacing.l
            - DesignSystem.Spacing.m - DesignSystem.Spacing.l
        let isFocal = id == self.focalID
        let ownTweet = self.selfHandle?.caseInsensitiveCompare(tweet.author.handle) == .orderedSame
        let indent = self.indentLevel(for: id)
        cell.configure(with: tweet, imagesEnabled: AppSettings.imagesEnabled,
                       contentWidth: max(120, width - CGFloat(min(indent, 3)) * ThreadRailView.step),
                       inReplyContext: true, focal: isFocal, ownTweet: ownTweet, indentLevel: indent)
        self.applyFlag(to: cell, author: tweet.author)
        cell.onTapAuthor = { [weak self] in self?.push(ProfileViewController(handle: tweet.author.handle)) }
        cell.onLike = { [weak self, weak cell] in self?.toggleLike(tweet, cell: cell) }
        cell.onReply = { [weak self] in self?.reply(to: tweet) }
        cell.onToggleRetweet = { [weak self, weak cell] in self?.toggleRetweet(tweet, cell: cell) }
        cell.onQuote = { [weak self] in self?.quote(tweet) }
        cell.onToggleBookmark = { [weak self, weak cell] in self?.toggleBookmark(tweet, cell: cell) }
        cell.onShare = { [weak self] in self?.share(tweet) }
        if ownTweet {
            cell.enableLikers { [weak self] in self?.push(LikersViewController(tweetID: tweet.restID)) }
        }
        cell.onTapPhoto = { [weak self] _ in self?.openMedia(tweet) }
        cell.onTapCard = { url in UIApplication.shared.open(url) }
        cell.onTapQuoted = { [weak self] in
            if let q = tweet.quotedTweet { self?.push(ThreadViewController(tweet: q)) }
        }
        cell.onTapMention = { [weak self] handle in self?.push(ProfileViewController(handle: handle)) }
        cell.onTapHashtag = { [weak self] query in
            self?.push(SearchResultsViewController(query: query, product: .top))
        }
    }

    /// Opens by id only — used from notifications / likers taps where the focal
    /// `Tweet` isn't in hand; falls back to a spinner until the thread loads.
    init(tweetID: String) {
        self.tweetID = tweetID
        super.init(nibName: nil, bundle: nil)
        scrollToFocalOnLoad = true
    }

    /// Opens from a `Tweet` already in hand (the feed) so the focal tweet renders
    /// instantly while ancestors and replies stream in.
    convenience init(tweet: Tweet) {
        self.init(tweetID: tweet.restID)
        scrollToFocalOnLoad = false
        focalID = tweet.restID
        tweetsByID[tweet.restID] = tweet
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Thread"
        view.backgroundColor = DesignSystem.Color.background

        var config = UICollectionLayoutListConfiguration(appearance: .plain)
        config.separatorConfiguration.bottomSeparatorInsets = .init(top: 0, leading: 72, bottom: 0, trailing: 0)
        config.backgroundColor = .clear
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config))
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        view.addManaged(collectionView)
        collectionView.pinEdges(to: view)
        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(pullToRefresh), for: .valueChanged)
        collectionView.refreshControl = refresh

        emptyState.isHidden = true
        emptyState.onRetry = { [weak self] in self?.load() }
        view.addManaged(emptyState)
        emptyState.pinEdges(toSafeAreaOf: view)

        loadingIndicator.hidesWhenStopped = true
        view.addManaged(loadingIndicator)
        NSLayoutConstraint.activate([
            loadingIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(
                image: DesignSystem.icon("arrowshape.turn.up.left"),
                primaryAction: UIAction { [weak self] _ in self?.replyToFocal() }),
            sortButton,
        ]

        let reg = registration
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { cv, ip, id in
            cv.dequeueConfiguredReusableCell(using: reg, for: ip, item: id)
        }
        renderFocalIfAvailable()
        resolveSelfHandle()
        load()
    }

    /// The reply sort control: an `arrow.up.arrow.down` menu mirroring the
    /// TUI's `s` cycle. Re-sorts the loaded replies locally — no refetch — and
    /// later pages slot into the chosen order as they arrive.
    private lazy var sortButton: UIBarButtonItem = {
        let item = UIBarButtonItem(image: DesignSystem.icon("arrow.up.arrow.down"), menu: sortMenu())
        item.accessibilityLabel = "Sort replies"
        return item
    }()

    private func sortMenu() -> UIMenu {
        UIMenu(title: "Sort replies", options: .singleSelection, children: ReplySort.allCases.map { sort in
            UIAction(title: sort.title, state: sort == replySort ? .on : .off) { [weak self] _ in
                self?.setReplySort(sort)
            }
        })
    }

    private func setReplySort(_ sort: ReplySort) {
        guard sort != replySort else { return }
        replySort = sort
        sortButton.menu = sortMenu()
        Haptics.selection()
        guard let focalID else { return }
        applyThread(ancestors: ancestorOrder, focal: focalID)
    }

    /// The reply ids in display order: the server's conversation order, or a
    /// deterministic local re-sort by the chosen metric (ties keep arrival
    /// order, so appending a page never shuffles equal rows).
    private func displayedReplies() -> [String] {
        guard replySort != .conversation else { return replyOrder }
        let arrival = Dictionary(uniqueKeysWithValues: replyOrder.enumerated().map { ($1, $0) })
        func metric(_ id: String) -> Double {
            guard let tweet = tweetsByID[id] else { return 0 }
            switch replySort {
            case .conversation: return 0
            case .newest: return tweet.createdAt.timeIntervalSince1970
            case .likes: return Double(tweet.likeCount)
            case .replies: return Double(tweet.replyCount)
            case .reposts: return Double(tweet.retweetCount)
            case .views: return Double(tweet.viewCount ?? 0)
            }
        }
        return replyOrder.sorted { a, b in
            let (ma, mb) = (metric(a), metric(b))
            if ma != mb { return ma > mb }
            return (arrival[a] ?? 0) < (arrival[b] ?? 0)
        }
    }

    /// Paints just the focal tweet immediately (when handed a `Tweet`), so the
    /// screen shows content before the network round-trip resolves.
    private func renderFocalIfAvailable() {
        guard let focalID, tweetsByID[focalID] != nil else {
            loadingIndicator.startAnimating()
            return
        }
        var snapshot = NSDiffableDataSourceSnapshot<Section, String>()
        snapshot.appendSections([.ancestors, .focal, .replies])
        snapshot.appendItems([focalID], toSection: .focal)
        dataSource.apply(snapshot, animatingDifferences: false)
        didRenderFocal = true
    }

    /// Resolves the signed-in handle so the analytics block only shows for the
    /// viewer's own tweets. Reconfigures the focal cell once known.
    private func resolveSelfHandle() {
        Task { [weak self] in
            guard let me = try? await AppEnvironment.shared.api.whoami() else { return }
            guard let self else { return }
            self.selfHandle = me.handle
            guard let focalID = self.focalID,
                  self.dataSource.snapshot().indexOfItem(focalID) != nil else { return }
            var snapshot = self.dataSource.snapshot()
            snapshot.reconfigureItems([focalID])
            await self.dataSource.apply(snapshot, animatingDifferences: false)
        }
    }

    @objc private func pullToRefresh() { load() }

    private func load() {
        Task {
            defer { collectionView.refreshControl?.endRefreshing() }
            do {
                let thread = try await AppEnvironment.shared.api.thread(id: tweetID)
                guard let focal = thread.focal ?? knownFocal else {
                    loadingIndicator.stopAnimating()
                    emptyState.isHidden = false
                    emptyState.show(symbol: "exclamationmark.triangle", title: "Couldn't load thread",
                                    subtitle: "The conversation is unavailable.", showRetry: true)
                    return
                }
                loadingIndicator.stopAnimating()
                focalID = focal.restID
                replyOrder = []
                for tweet in thread.ancestors + [focal] {
                    tweetsByID[tweet.restID] = tweet
                }
                ancestorOrder = uniqued(thread.ancestors.map(\.restID)).filter { $0 != focal.restID }
                let excluded = Set(ancestorOrder + [focal.restID])
                for reply in thread.replies
                where !excluded.contains(reply.restID) && !replyOrder.contains(reply.restID) {
                    tweetsByID[reply.restID] = reply
                    replyOrder.append(reply.restID)
                }
                cursor = thread.cursor
                exhausted = thread.cursor == nil
                applyThread(ancestors: ancestorOrder, focal: focal.restID)
            } catch {
                guard !didRenderFocal else {
                    AppLogger.shared.warn("thread load failed (focal already shown): \(error)", category: .thread)
                    return
                }
                loadingIndicator.stopAnimating()
                emptyState.isHidden = false
                emptyState.show(symbol: "exclamationmark.triangle", title: "Couldn't load thread",
                                subtitle: error.localizedDescription, showRetry: true)
            }
        }
    }

    /// The focal tweet already in hand (instant render from the feed, or a
    /// previous page), used when a response omits `focal` — continuation pages
    /// carry only replies and a cursor.
    private var knownFocal: Tweet? {
        focalID.flatMap { tweetsByID[$0] }
    }

    /// Drops duplicate ids while preserving order — continuation pages can
    /// repeat the focal or an ancestor, and a diffable snapshot with duplicate
    /// identifiers is a fatal inconsistency.
    private func uniqued(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    /// Reply depth used for the thread's indentation: a direct reply to the
    /// focal is level 1, a reply-to-a-reply level 2, and so on, so the structure
    /// reads at a glance. Ancestors and the focal stay flush (level 0).
    private func indentLevel(for id: String) -> Int {
        guard replyOrder.contains(id), let tweet = tweetsByID[id] else { return 0 }
        var level = 1
        var current = tweet.inReplyToTweetID
        while let parent = current, parent != focalID, replyOrder.contains(parent), level < 5 {
            level += 1
            current = tweetsByID[parent]?.inReplyToTweetID
        }
        return level
    }

    /// Applies the full thread. When ancestors are prepended above an
    /// already-visible focal tweet, the content offset is corrected after layout
    /// so the focal tweet stays put — no scroll jump.
    private func applyThread(ancestors: [String], focal: String) {
        let anchorBefore = focalCellFrameMinusOffset()
        var snapshot = NSDiffableDataSourceSnapshot<Section, String>()
        snapshot.appendSections([.ancestors, .focal, .replies])
        snapshot.appendItems(ancestors, toSection: .ancestors)
        snapshot.appendItems([focal], toSection: .focal)
        snapshot.appendItems(displayedReplies(), toSection: .replies)
        let shouldPinFocal = didRenderFocal && !ancestors.isEmpty
        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            guard let self else { return }
            if self.scrollToFocalOnLoad, !ancestors.isEmpty {
                self.scrollToFocalOnLoad = false
                self.scrollFocalToTop()
            } else if shouldPinFocal, let anchorBefore {
                self.pinFocal(toScreenY: anchorBefore)
            }
        }
        didRenderFocal = true
    }

    /// Brings the focal tweet to the top of the viewport (used when a thread is
    /// opened by id from a notification, so ancestors sit above it off-screen).
    private func scrollFocalToTop() {
        guard let focalID, let indexPath = dataSource.indexPath(for: focalID),
              let attributes = collectionView.layoutAttributesForItem(at: indexPath) else { return }
        let maxOffset = max(0, collectionView.contentSize.height - collectionView.bounds.height
            + collectionView.adjustedContentInset.bottom)
        let target = min(max(0, attributes.frame.minY - collectionView.adjustedContentInset.top), maxOffset)
        collectionView.setContentOffset(CGPoint(x: 0, y: target), animated: false)
    }

    /// The focal cell's top in the collection's content space minus the current
    /// vertical offset — i.e. its on-screen Y, captured before a diff.
    private func focalCellFrameMinusOffset() -> CGFloat? {
        guard let focalID, let indexPath = dataSource.indexPath(for: focalID),
              let attributes = collectionView.layoutAttributesForItem(at: indexPath) else { return nil }
        return attributes.frame.minY - collectionView.contentOffset.y
    }

    private func pinFocal(toScreenY screenY: CGFloat) {
        guard let focalID, let indexPath = dataSource.indexPath(for: focalID),
              let attributes = collectionView.layoutAttributesForItem(at: indexPath) else { return }
        let target = attributes.frame.minY - screenY
        collectionView.setContentOffset(CGPoint(x: 0, y: max(0, target)), animated: false)
    }

    private func loadMore() {
        guard !loadingMore, !exhausted, let cursor else { return }
        loadingMore = true
        Task {
            defer { loadingMore = false }
            do {
                let page = try await AppEnvironment.shared.api.thread(id: tweetID, cursor: cursor)
                var added = false
                let excluded = Set(ancestorOrder + [focalID].compactMap { $0 })
                for reply in page.replies
                where !excluded.contains(reply.restID) && !replyOrder.contains(reply.restID) {
                    tweetsByID[reply.restID] = reply
                    replyOrder.append(reply.restID)
                    added = true
                }
                self.cursor = page.cursor
                if page.cursor == nil || !added { exhausted = true }
                let anchor = replySort != .conversation ? visibleReplyAnchor() : nil
                var snapshot = dataSource.snapshot()
                snapshot.deleteSections([.replies])
                snapshot.appendSections([.replies])
                snapshot.appendItems(displayedReplies(), toSection: .replies)
                await dataSource.apply(snapshot, animatingDifferences: anchor == nil)
                if let anchor { restoreAnchor(anchor) }
            } catch {
                AppLogger.shared.warn("thread loadMore failed: \(error)", category: .thread)
            }
        }
    }

    /// The first cell whose bottom edge sits below the viewport top, plus its
    /// on-screen Y — a stable scroll anchor. Under a non-conversation reply sort
    /// a `loadMore` page can slot rows *above* the viewport (a highly-liked
    /// late-page reply), so without this the visible rows shove down mid-read;
    /// capturing and restoring the anchor keeps the reader's position fixed
    /// (the reason `applyThread` pins the focal on prepend).
    private func visibleReplyAnchor() -> (id: String, screenY: CGFloat)? {
        let offset = collectionView.contentOffset.y
        let visible = collectionView.indexPathsForVisibleItems.sorted()
        for indexPath in visible {
            guard let id = dataSource.itemIdentifier(for: indexPath),
                  let attributes = collectionView.layoutAttributesForItem(at: indexPath) else { continue }
            if attributes.frame.maxY > offset {
                return (id, attributes.frame.minY - offset)
            }
        }
        return nil
    }

    private func restoreAnchor(_ anchor: (id: String, screenY: CGFloat)) {
        collectionView.layoutIfNeeded()
        guard let indexPath = dataSource.indexPath(for: anchor.id),
              let attributes = collectionView.layoutAttributesForItem(at: indexPath) else { return }
        let maxOffset = max(0, collectionView.contentSize.height
            - collectionView.bounds.height + collectionView.adjustedContentInset.bottom)
        let target = min(max(0, attributes.frame.minY - anchor.screenY), maxOffset)
        collectionView.setContentOffset(CGPoint(x: 0, y: target), animated: false)
    }

    private func replyToFocal() {
        guard let focalID, let focal = tweetsByID[focalID] else { return }
        reply(to: focal)
    }

    private func reply(to tweet: Tweet) {
        let compose = ComposeViewController(mode: .reply(to: tweet))
        present(UINavigationController(rootViewController: compose), animated: true)
    }

    private func quote(_ tweet: Tweet) {
        let compose = ComposeViewController(mode: .quote(of: tweet))
        present(UINavigationController(rootViewController: compose), animated: true)
    }

    private func share(_ tweet: Tweet) {
        let items: [Any] = [URL(string: tweet.url) ?? FeedViewController.fixupxURL(tweet)]
        let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = view
        present(activity, animated: true)
    }

    /// Opens tapped media full-screen — a zoomable gallery for photos, the native
    /// player for video/GIF — rather than re-navigating into the thread.
    private func openMedia(_ tweet: Tweet) {
        if let video = tweet.media.enumerated().first(where: { $0.element.isVideo }) {
            let url = video.element.videoURL.flatMap(URL.init)
                ?? AppEnvironment.shared.api.mediaURL(tweetID: tweet.restID, index: video.offset)
            MediaAudioSession.activatePlayback()
            let player = AVPlayer(url: url)
            let controller = AVPlayerViewController()
            controller.player = player
            present(controller, animated: true) { player.play() }
            return
        }
        let photoIndices = tweet.media.enumerated().compactMap { index, media -> Int? in
            if case .photo = media.kind { return index } else { return nil }
        }
        guard !photoIndices.isEmpty else {
            if tweet.restID != focalID { push(ThreadViewController(tweet: tweet)) }
            return
        }
        present(MediaViewerViewController(tweetID: tweet.restID, photoMediaIndices: photoIndices, startIndex: 0), animated: true)
    }

    private func toggleLike(_ tweet: Tweet, cell: TweetCell?) {
        let target = !tweet.favorited
        cell?.applyLike(favorited: target, count: max(0, tweet.likeCount + (target ? 1 : -1)))
        Task {
            do {
                _ = target
                    ? try await AppEnvironment.shared.api.like(tweetID: tweet.restID)
                    : try await AppEnvironment.shared.api.unlike(tweetID: tweet.restID)
                confirmLike(id: tweet.restID, favorited: target)
            } catch {
                cell?.applyLike(favorited: tweet.favorited, count: tweet.likeCount)
                Haptics.error()
            }
        }
    }

    /// Optimistic repost toggle, same contract as `toggleLike`.
    private func toggleRetweet(_ tweet: Tweet, cell: TweetCell?) {
        let target = !tweet.retweeted
        cell?.applyRetweet(retweeted: target, count: max(0, tweet.retweetCount + (target ? 1 : -1)))
        Task {
            do {
                _ = target
                    ? try await EngageService.engage.retweet(tweetID: tweet.restID)
                    : try await EngageService.engage.unretweet(tweetID: tweet.restID)
                confirmEngagement(id: tweet.restID) { $0.togglingRetweet(to: target) }
            } catch {
                cell?.applyRetweet(retweeted: tweet.retweeted, count: tweet.retweetCount)
                Haptics.error()
            }
        }
    }

    /// Optimistic bookmark toggle, same contract as `toggleLike`.
    private func toggleBookmark(_ tweet: Tweet, cell: TweetCell?) {
        let target = !tweet.bookmarked
        cell?.applyBookmark(bookmarked: target, count: max(0, tweet.bookmarkCount + (target ? 1 : -1)))
        Task {
            do {
                _ = target
                    ? try await EngageService.engage.bookmark(tweetID: tweet.restID)
                    : try await EngageService.engage.unbookmark(tweetID: tweet.restID)
                confirmEngagement(id: tweet.restID) { $0.togglingBookmark(to: target) }
            } catch {
                cell?.applyBookmark(bookmarked: tweet.bookmarked, count: tweet.bookmarkCount)
                Haptics.error()
            }
        }
    }

    /// Writes a confirmed like/unlike back into the thread's model and
    /// reconfigures the row so its handlers capture the fresh state — otherwise
    /// a second tap re-sends "like" and any reuse repaints the stale heart.
    private func confirmLike(id: String, favorited: Bool) {
        confirmEngagement(id: id) { $0.togglingLike(to: favorited) }
    }

    /// The shared confirmed-engagement write-back: swaps in `transform`'s copy
    /// (nil = already in that state) and reconfigures the row.
    private func confirmEngagement(id: String, _ transform: (Tweet) -> Tweet?) {
        guard let updated = tweetsByID[id].flatMap(transform) else { return }
        tweetsByID[id] = updated
        var snapshot = dataSource.snapshot()
        guard snapshot.indexOfItem(id) != nil else { return }
        snapshot.reconfigureItems([id])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func push(_ vc: UIViewController) {
        navigationController?.pushViewController(vc, animated: true)
    }

    /// Decorates a thread row with the author's country flag: synchronously on
    /// a session-cache hit, otherwise lazily via a direct label update on the
    /// visible cells showing that author — never a snapshot churn.
    private func applyFlag(to cell: TweetCell, author: User) {
        let flags = AppEnvironment.shared.flags
        if let known = flags.cached(restID: author.restID) {
            cell.setFlag(known.flag)
            return
        }
        let authorID = author.restID
        flags.resolve(restID: authorID, screenName: author.handle) { [weak self] resolved in
            self?.updateVisibleFlags(authorID: authorID, flag: resolved.flag)
        }
    }

    private func updateVisibleFlags(authorID: String, flag: String?) {
        guard let flag, !flag.isEmpty else { return }
        for indexPath in collectionView.indexPathsForVisibleItems {
            guard let id = dataSource.itemIdentifier(for: indexPath),
                  let tweet = tweetsByID[id], tweet.author.restID == authorID,
                  let cell = collectionView.cellForItem(at: indexPath) as? TweetCell else { continue }
            cell.setFlag(flag)
        }
    }

    // MARK: - Ask with thread context

    /// The "Ask" submenu for a thread row: the TUI's preset prompts, each
    /// opening the conversational ask sheet seeded with the thread as context
    /// (focal + loaded replies, ancestors when the asked tweet is a reply).
    func askMenu(for tweet: Tweet) -> UIMenu {
        UIMenu(title: "Ask", image: DesignSystem.icon("sparkles"),
               children: AskConversationViewController.presets(hasReplies: !replyOrder.isEmpty).map { preset in
            UIAction(title: preset.label) { [weak self] _ in
                self?.presentAsk(about: tweet, prompt: preset.prompt)
            }
        })
    }

    private func presentAsk(about tweet: Tweet, prompt: String) {
        let sheet = AskConversationViewController(context: askContext(for: tweet), initialPrompt: prompt)
        let nav = UINavigationController(rootViewController: sheet)
        if let presentation = nav.sheetPresentationController {
            presentation.detents = [.medium(), .large()]
            presentation.selectedDetentIdentifier = .large
            presentation.prefersGrabberVisible = true
        }
        present(nav, animated: true)
    }

    /// Builds the ask context the way the TUI does: asking the focal sends its
    /// loaded replies; asking a reply sends the full ancestor chain root-first
    /// (thread ancestors, focal, intermediate replies), its same-level
    /// siblings, and its own loaded children.
    private func askContext(for tweet: Tweet) -> AskConversationViewController.Context {
        let ancestorTweets = ancestorOrder.compactMap { tweetsByID[$0] }
        let directChildren: (String) -> [Tweet] = { [self] parentID in
            replyOrder.compactMap { tweetsByID[$0] }.filter { $0.inReplyToTweetID == parentID }
        }
        guard tweet.restID != focalID else {
            return .init(tweet: tweet, ancestors: ancestorTweets, siblings: [],
                         replies: focalID.map(directChildren) ?? [])
        }
        var chain: [Tweet] = []
        var currentID = tweet.inReplyToTweetID
        var guardCount = 0
        while let id = currentID, id != focalID, guardCount < 32 {
            guardCount += 1
            guard let parent = tweetsByID[id] else { break }
            chain.append(parent)
            currentID = parent.inReplyToTweetID
        }
        var ancestors = ancestorTweets
        if let focal = knownFocal { ancestors.append(focal) }
        ancestors.append(contentsOf: chain.reversed())
        let siblings = tweet.inReplyToTweetID.map(directChildren)?
            .filter { $0.restID != tweet.restID } ?? []
        return .init(tweet: tweet, ancestors: ancestors, siblings: siblings,
                     replies: directChildren(tweet.restID))
    }
}

extension ThreadViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard let id = dataSource.itemIdentifier(for: indexPath), id != focalID,
              let tweet = tweetsByID[id] else { return }
        push(ThreadViewController(tweet: tweet))
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard let id = dataSource.itemIdentifier(for: indexPath),
              displayedReplies().suffix(4).contains(id) else { return }
        loadMore()
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard let id = dataSource.itemIdentifier(for: indexPath), let tweet = tweetsByID[id] else { return nil }
        return UIContextMenuConfiguration(identifier: id as NSString, previewProvider: nil) { _ in
            UIMenu(children: [
                self.askMenu(for: tweet),
                UIAction(title: "Liked by", image: DesignSystem.icon("heart.text.square")) { [weak self] _ in
                    self?.push(LikersViewController(tweetID: tweet.restID))
                },
                UIAction(title: "Postcard…", image: DesignSystem.icon("photo.badge.plus")) { [weak self] _ in
                    self?.present(UINavigationController(rootViewController: PostcardViewController(tweet: tweet)), animated: true)
                },
                UIAction(title: "Copy embed link", image: DesignSystem.icon("link.badge.plus")) { _ in
                    UIPasteboard.general.string = FeedViewController.fixupxURL(tweet)
                },
                UIAction(title: "Open in X", image: DesignSystem.icon("safari")) { _ in
                    if let url = URL(string: tweet.url) { UIApplication.shared.open(url) }
                },
            ])
        }
    }
}
