import UIKit
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
final class ThreadViewController: UIViewController, TweetActionHandling {
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
    /// Holds the focal at the top across async ancestor-image height changes
    /// after a notification/permalink open, until the user first drags or
    /// posts a reply.
    private var focalPin = FocalPin()
    private var selfHandle: String?
    private var cursor: String?
    private var exhausted = false
    private var loadingMore = false
    private var didRenderFocal = false
    private var threadLoaded = false
    private var repliesFailure: String?
    private var failedLoadWasReload = false
    private var replySort: ReplySort = .conversation
    /// The reply the user just posted from here, to scroll to once the
    /// reloaded thread shows it.
    private var postedReplyID: String?
    private let emptyState = EmptyStateView()
    private let loadingSkeleton = FeedSkeletonView()

    private enum Section: Int { case ancestors, focal, replies }

    private let footer = PagingFooter()
    private var cancellables = Set<AnyCancellable>()
    private var videoSettle: DispatchWorkItem?

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
        let width = self.collectionView.bounds.width
        let isFocal = id == self.focalID
        let ownTweet = self.selfHandle?.caseInsensitiveCompare(tweet.author.handle) == .orderedSame
        let indent = self.indentLevel(for: id)
        cell.configure(with: tweet, imagesEnabled: AppSettings.imagesEnabled,
                       contentWidth: max(120, width - CGFloat(min(indent, 3)) * ThreadRailView.step),
                       impliedReplyHandles: self.impliedReplyHandles(for: id),
                       focal: isFocal, indentLevel: indent,
                       stats: PostStatsPolicy.content(
                           for: tweet, expanded: self.expandedStats.contains(id), isOwn: ownTweet,
                           changed: { [weak self] in self?.reconfigure(id, animated: false) }),
                       viewerHandle: self.selfHandle ?? AppEnvironment.shared.currentHandle)
        self.applyFlag(to: cell, author: tweet.author)
        cell.onTapAuthor = { [weak self] in self?.push(ProfileViewController(handle: tweet.author.handle)) }
        if let reposter = tweet.retweetedBy {
            cell.onTapReposter = { [weak self] in self?.push(ProfileViewController(handle: reposter.handle)) }
        }
        cell.onLike = { [weak self, weak cell] in self?.toggleLike(tweet, cell: cell) }
        cell.onReply = { [weak self] in self?.reply(to: tweet) }
        cell.onToggleRetweet = { [weak self, weak cell] in self?.toggleRetweet(tweet, cell: cell) }
        cell.onQuote = { [weak self] in self?.presentQuote(tweet) }
        cell.onViewQuotes = { [weak self] in self?.openQuotes(of: tweet) }
        cell.onToggleBookmark = { [weak self, weak cell] in self?.toggleBookmark(tweet, cell: cell) }
        cell.onShare = { [weak self] in self?.shareTweet(tweet) }
        cell.onToggleStats = { [weak self] in self?.toggleStats(id) }
        if OwnPost.canDelete(tweet, viewerHandle: self.selfHandle ?? AppEnvironment.shared.currentHandle) {
            cell.onDelete = { [weak self] in self?.confirmDelete(tweet) }
        }
        if ownTweet {
            cell.enableLikers { [weak self] in self?.push(LikersViewController(tweetID: tweet.restID, tweet: tweet)) }
        }
        cell.onTapPhoto = { [weak self] index in self?.openMedia(tweet, at: index) }
        cell.onTapCard = { [weak self] url in self?.openLink(url) }
        cell.onTapQuoted = { [weak self] quoted in self?.push(ThreadViewController(tweet: quoted)) }
        cell.onTapMention = { [weak self] handle in self?.push(ProfileViewController(handle: handle)) }
        cell.onTapHashtag = { [weak self] query in
            self?.push(SearchResultsViewController(query: query, product: .top))
        }
    }

    /// Tweet ids whose stats strip the user opened.
    private var expandedStats = Set<String>()

    private func toggleStats(_ id: String) {
        if expandedStats.contains(id) {
            expandedStats.remove(id)
        } else {
            expandedStats.insert(id)
            PostStatsStore.shared.retryIfFailed(id)
        }
        reconfigure(id, animated: true)
    }

    /// Re-renders one row, easing its height if it changed.
    private func reconfigure(_ id: String, animated: Bool) {
        var snapshot = dataSource.snapshot()
        guard snapshot.itemIdentifiers.contains(id) else { return }
        snapshot.reconfigureItems([id])
        dataSource.apply(snapshot, animatingDifferences: animated)
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

        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: makeLayout())
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

        loadingSkeleton.isHidden = true
        view.addManaged(loadingSkeleton)
        NSLayoutConstraint.activate([
            loadingSkeleton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            loadingSkeleton.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            loadingSkeleton.trailingAnchor.constraint(equalTo: view.trailingAnchor),
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
        footer.attach(to: collectionView)
        footer.onRetry = { [weak self] in self?.retryReplies() }
        footer.install(on: dataSource)
        renderFocalIfAvailable()
        resolveSelfHandle()
        observeDisplayChanges()
        load()
    }

    /// A text-size change re-renders every row; Twemoji art landing re-renders
    /// the rows on screen, whose native emoji glyphs it replaces.
    private func observeDisplayChanges() {
        NotificationCenter.default.publisher(for: AppSettings.fontScaleDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.dataSource.reconfigureAllItems() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: TwemojiCache.imagesDidLoad)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.dataSource.reconfigureVisibleItems(of: self.collectionView) {
                    ($0 as? TweetCell)?.awaitsLoadedEmoji ?? true
                }
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                InlineVideoPlayback.pauseAll(in: self.collectionView)
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.settleVideoPlayback() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: OwnPost.didDelete)
            .compactMap { $0.userInfo?[OwnPost.idKey] as? String }
            .sink { [weak self] id in self?.removeDeleted(id) }
            .store(in: &cancellables)
    }

    /// Takes a deleted post out of the conversation; when it was the post the
    /// thread is about, the thread itself goes.
    private func removeDeleted(_ id: String) {
        guard id != focalID, id != tweetID else {
            leaveDeletedThread()
            return
        }
        guard replyOrder.contains(id) || ancestorOrder.contains(id) else { return }
        replyOrder.removeAll { $0 == id }
        ancestorOrder.removeAll { $0 == id }
        tweetsByID[id] = nil
        var snapshot = dataSource.snapshot()
        if snapshot.indexOfItem(id) != nil {
            snapshot.deleteItems([id])
            dataSource.apply(snapshot, animatingDifferences: true)
        }
        updateFooter()
    }

    /// Pops the thread when it is on top, or drops it from under whatever was
    /// pushed over it.
    private func leaveDeletedThread() {
        guard let navigation = navigationController else { return }
        if navigation.topViewController === self {
            navigation.popViewController(animated: true)
        } else {
            navigation.setViewControllers(navigation.viewControllers.filter { $0 !== self }, animated: false)
        }
    }

    /// The list layout, with swipe actions on every row and a status footer
    /// under the replies section only.
    private func makeLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { [weak self] sectionIndex, environment in
            var config = UICollectionLayoutListConfiguration(appearance: .plain)
            config.separatorConfiguration.bottomSeparatorInsets = .init(top: 0, leading: 72, bottom: 0, trailing: 0)
            config.backgroundColor = .clear
            config.leadingSwipeActionsConfigurationProvider = { [weak self] indexPath in
                self?.leadingSwipeActions(at: indexPath)
            }
            config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
                self?.trailingSwipeActions(at: indexPath)
            }
            let section = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
            if sectionIndex == Section.replies.rawValue {
                section.boundarySupplementaryItems = [PagingFooter.boundaryItem()]
            }
            return section
        }
    }

    private func leadingSwipeActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let id = dataSource.itemIdentifier(for: indexPath), let tweet = tweetsByID[id] else { return nil }
        let like = UIContextualAction(style: .normal, title: tweet.favorited ? "Unlike" : "Like") { [weak self] _, _, done in
            self?.toggleLike(tweet, cell: self?.collectionView.cellForItem(at: indexPath) as? TweetCell)
            done(true)
        }
        like.image = DesignSystem.icon(tweet.favorited ? "heart.slash.fill" : "heart.fill", pointSize: 18)
        like.backgroundColor = DesignSystem.Color.like
        let config = UISwipeActionsConfiguration(actions: [like])
        config.performsFirstActionWithFullSwipe = true
        return config
    }

    private func trailingSwipeActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let id = dataSource.itemIdentifier(for: indexPath), let tweet = tweetsByID[id] else { return nil }
        let reply = UIContextualAction(style: .normal, title: "Reply") { [weak self] _, _, done in
            self?.reply(to: tweet)
            done(true)
        }
        reply.image = DesignSystem.icon("arrowshape.turn.up.left.fill", pointSize: 18)
        reply.backgroundColor = DesignSystem.Color.accent
        return UISwipeActionsConfiguration(actions: [reply])
    }

    /// The replies footer: "Loading replies…" until the thread first lands or
    /// while a later page is in flight, a retry when a load failed, and "No
    /// replies yet" once a finished thread has none.
    private func updateFooter() {
        if let failure = repliesFailure {
            footer.set(.failed(failure))
        } else if !threadLoaded {
            footer.set(.loading("Loading replies…"))
        } else if loadingMore {
            footer.set(.loading("Loading more…"))
        } else if replyOrder.isEmpty {
            footer.set(.note("No replies yet"))
        } else {
            footer.set(.hidden)
        }
    }

    private func retryReplies() {
        repliesFailure = nil
        updateFooter()
        if failedLoadWasReload { load() } else { loadMore() }
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
        applyThread(ancestors: ancestorOrder, focal: focalID, reconfigureExisting: true)
    }

    /// The account whose post this row already sits under, so its reply caption
    /// names only anyone else it tags: its parent when that is shown above it
    /// (an ancestor, the focal post or a reply nested over it), the focal post
    /// for a reply to the focal in a flat sort. Nil when the parent isn't on
    /// screen, and the caption names everyone.
    private func impliedReplyHandles(for id: String) -> Set<String>? {
        guard let tweet = tweetsByID[id], let parentID = tweet.inReplyToTweetID,
              let parent = tweetsByID[parentID] else { return nil }
        let parentIsAbove: Bool
        if replySort == .conversation || !replyOrder.contains(id) {
            parentIsAbove = parentID == focalID || ancestorOrder.contains(parentID)
                || replyOrder.contains(parentID)
        } else {
            parentIsAbove = parentID == focalID
        }
        return parentIsAbove ? [parent.author.handle.lowercased()] : nil
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
    /// Shows the placeholder posts while the conversation is on its way.
    private func showLoading() {
        guard loadingSkeleton.isHidden else { return }
        loadingSkeleton.alpha = 0
        loadingSkeleton.isHidden = false
        UIView.animate(withDuration: 0.25) { self.loadingSkeleton.alpha = 1 }
    }

    private func hideLoading() {
        guard !loadingSkeleton.isHidden else { return }
        loadingSkeleton.layer.removeAllAnimations()
        loadingSkeleton.isHidden = true
    }

    private func renderFocalIfAvailable() {
        guard let focalID, tweetsByID[focalID] != nil else {
            showLoading()
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
        emptyState.isHidden = true
        repliesFailure = nil
        if !didRenderFocal { showLoading() }
        updateFooter()
        Task {
            defer { collectionView.refreshControl?.endRefreshing() }
            do {
                let thread = try await AppEnvironment.shared.api.thread(id: tweetID)
                guard let focal = thread.focal ?? knownFocal else {
                    hideLoading()
                    emptyState.isHidden = false
                    emptyState.show(symbol: "exclamationmark.triangle", title: "Couldn't load thread",
                                    subtitle: "The conversation is unavailable.", showRetry: true)
                    return
                }
                hideLoading()
                focalID = focal.restID
                replyOrder = []
                for tweet in thread.ancestors + [focal] {
                    tweetsByID[tweet.restID] = tweet
                }
                ancestorOrder = uniqued(thread.ancestors.map(\.restID)).filter { $0 != focal.restID }
                let excluded = Set(ancestorOrder + [focal.restID])
                for reply in thread.replies
                where !excluded.contains(reply.restID) && !replyOrder.contains(reply.restID)
                    && !TimelineViewModel.wasDeleted(reply.restID) {
                    tweetsByID[reply.restID] = reply
                    replyOrder.append(reply.restID)
                }
                cursor = thread.cursor
                exhausted = thread.cursor == nil
                threadLoaded = true
                applyThread(ancestors: ancestorOrder, focal: focal.restID, reconfigureExisting: true)
                updateFooter()
                DispatchQueue.main.async { [weak self] in self?.revealPostedReply() }
            } catch {
                guard !didRenderFocal else {
                    AppLogger.shared.warn("thread load failed (focal already shown): \(error)", category: .thread)
                    repliesFailure = "Couldn't load replies"
                    failedLoadWasReload = true
                    updateFooter()
                    revealPostedReply()
                    return
                }
                hideLoading()
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
    private func applyThread(ancestors: [String], focal: String, reconfigureExisting: Bool = false) {
        let anchorBefore = focalCellFrameMinusOffset()
        let alreadyShown = Set(dataSource.snapshot().itemIdentifiers)
        var snapshot = NSDiffableDataSourceSnapshot<Section, String>()
        snapshot.appendSections([.ancestors, .focal, .replies])
        snapshot.appendItems(ancestors, toSection: .ancestors)
        snapshot.appendItems([focal], toSection: .focal)
        snapshot.appendItems(displayedReplies(), toSection: .replies)
        if reconfigureExisting {
            snapshot.reconfigureItems(snapshot.itemIdentifiers.filter(alreadyShown.contains))
        }
        let shouldPinFocal = didRenderFocal && !ancestors.isEmpty
        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            guard let self else { return }
            if self.scrollToFocalOnLoad, !ancestors.isEmpty {
                self.scrollToFocalOnLoad = false
                self.focalPin.hold()
                self.scrollFocalToTop()
            } else if shouldPinFocal, let anchorBefore {
                self.pinFocal(toScreenY: anchorBefore)
            }
        }
        didRenderFocal = true
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if focalPin.isHeld { scrollFocalToTop() }
        scheduleVideoSettle()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        settleVideoPlayback()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        videoSettle?.cancel()
        InlineVideoPlayback.pauseAll(in: collectionView)
    }

    /// Lets the clips on screen start once the layout has stopped moving: the
    /// rows grow as pictures and ancestors land and the focal post is held in
    /// place, so a clip is judged only after a quiet moment, and never while
    /// the reader's finger or momentum is moving the list.
    private func scheduleVideoSettle() {
        videoSettle?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.settleVideoPlayback() }
        videoSettle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func settleVideoPlayback() {
        guard isViewLoaded, !collectionView.isDragging, !collectionView.isDecelerating else { return }
        InlineVideoPlayback.settle(in: collectionView, isShowing: view.window != nil)
    }

    /// Brings the focal tweet to the top of the viewport (used when a thread is
    /// opened by id from a notification, so ancestors sit above it off-screen).
    /// Re-applied on every layout pass while `focalPin` holds, so ancestor
    /// images loading in and growing can't leave the focal scrolled past; the
    /// user's first drag or a posted reply releases the pin.
    private func scrollFocalToTop() {
        guard let focalID, let indexPath = dataSource.indexPath(for: focalID),
              let attributes = collectionView.layoutAttributesForItem(at: indexPath) else { return }
        let topInset = collectionView.adjustedContentInset.top
        let target = max(0, attributes.frame.minY - topInset)
        setBottomInset(focalPin.bottomInset(
            focalOffset: target, viewportHeight: collectionView.bounds.height,
            contentHeight: collectionView.contentSize.height, safeAreaBottom: collectionView.safeAreaInsets.bottom))
        if abs(collectionView.contentOffset.y - target) > 0.5 {
            collectionView.setContentOffset(CGPoint(x: 0, y: target), animated: false)
        }
    }

    private func setBottomInset(_ inset: CGFloat) {
        guard abs(collectionView.contentInset.bottom - inset) > 0.5 else { return }
        collectionView.contentInset.bottom = inset
    }

    /// Lets go of the focal and takes away the room the pin added under the
    /// last reply, which would otherwise stay on as empty space below the
    /// conversation. `settling` glides the list back within its rows at once;
    /// a drag is left to bounce back on its own.
    private func releaseFocalPin(settling: Bool) {
        guard focalPin.isHeld else { return }
        focalPin.release()
        setBottomInset(0)
        guard settling else { return }
        let settled = min(collectionView.contentOffset.y, maxOffset)
        if settled < collectionView.contentOffset.y - 0.5 {
            collectionView.setContentOffset(CGPoint(x: 0, y: settled), animated: true)
        }
    }

    /// The furthest the list scrolls down: its last row resting on the bottom
    /// inset, or the top when the rows don't fill the screen.
    private var maxOffset: CGFloat {
        max(topOffset, collectionView.contentSize.height - collectionView.bounds.height
            + collectionView.adjustedContentInset.bottom)
    }

    /// The focal cell's top in the collection's content space minus the current
    /// vertical offset — i.e. its on-screen Y, captured before a diff.
    private func focalCellFrameMinusOffset() -> CGFloat? {
        guard let focalID, let indexPath = dataSource.indexPath(for: focalID),
              let attributes = collectionView.layoutAttributesForItem(at: indexPath) else { return nil }
        return attributes.frame.minY - collectionView.contentOffset.y
    }

    /// The content offset that puts the first row flush under the navigation
    /// bar — negative by the top inset, so clamping to 0 would shove content up.
    private var topOffset: CGFloat { -collectionView.adjustedContentInset.top }

    /// Keeps the focal at `screenY` across a reload, as far as the rows allow:
    /// never past the last one, which would leave empty space under it.
    private func pinFocal(toScreenY screenY: CGFloat) {
        collectionView.layoutIfNeeded()
        guard let focalID, let indexPath = dataSource.indexPath(for: focalID),
              let attributes = collectionView.layoutAttributesForItem(at: indexPath) else { return }
        let target = min(max(topOffset, attributes.frame.minY - screenY), maxOffset)
        collectionView.setContentOffset(CGPoint(x: 0, y: target), animated: false)
    }

    private func loadMore() {
        guard !loadingMore, !exhausted, repliesFailure == nil, threadLoaded, let cursor else { return }
        loadingMore = true
        updateFooter()
        Task {
            defer { loadingMore = false; updateFooter() }
            do {
                let page = try await AppEnvironment.shared.api.thread(id: tweetID, cursor: cursor)
                var added = false
                let excluded = Set(ancestorOrder + [focalID].compactMap { $0 })
                for reply in page.replies
                where !excluded.contains(reply.restID) && !replyOrder.contains(reply.restID)
                    && !TimelineViewModel.wasDeleted(reply.restID) {
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
                repliesFailure = "Couldn't load more replies"
                failedLoadWasReload = false
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
        let maxOffset = max(topOffset, collectionView.contentSize.height
            - collectionView.bounds.height + collectionView.adjustedContentInset.bottom)
        let target = min(max(topOffset, attributes.frame.minY - anchor.screenY), maxOffset)
        collectionView.setContentOffset(CGPoint(x: 0, y: target), animated: false)
    }

    private func replyToFocal() {
        guard let focalID, let focal = tweetsByID[focalID] else { return }
        reply(to: focal)
    }

    private func reply(to tweet: Tweet) {
        let compose = ComposeViewController(mode: .reply(to: tweet))
        compose.onPosted = { [weak self] posted in
            guard let self else { return }
            if posted.likedReplyTarget {
                self.confirmEngagement(id: tweet.restID) { $0.togglingLike(to: true) }
            }
            self.releaseFocalPin(settling: true)
            self.postedReplyID = posted.id
            self.load()
        }
        present(UINavigationController(rootViewController: compose), animated: true)
    }

    /// Scrolls to the reply the user just posted once the reloaded thread
    /// holds it; when X hasn't surfaced it yet, says it went through instead.
    private func revealPostedReply() {
        guard let id = postedReplyID else { return }
        postedReplyID = nil
        guard let indexPath = dataSource.indexPath(for: id) else {
            showToast("Reply posted")
            return
        }
        collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: true)
    }

    func presentQuote(_ tweet: Tweet) {
        let compose = ComposeViewController(mode: .quote(of: tweet))
        present(UINavigationController(rootViewController: compose), animated: true)
    }

    func tweetCell(for tweet: Tweet) -> TweetCell? {
        guard let indexPath = dataSource.indexPath(for: tweet.restID) else { return nil }
        return collectionView.cellForItem(at: indexPath) as? TweetCell
    }

    /// Opens tapped media full-screen — a zoomable gallery for photos, the native
    /// player for video/GIF — rather than re-navigating into the thread.
    private func openMedia(_ tweet: Tweet, at tappedIndex: Int) {
        if let video = tweet.media.enumerated().first(where: { $0.element.isVideo }) {
            let url = video.element.videoURL.flatMap(URL.init)
                ?? AppEnvironment.shared.api.mediaURL(tweetID: tweet.restID, index: video.offset)
            InlineVideoPlayback.pauseAll(in: collectionView)
            presentFullScreenVideo(url)
            return
        }
        let photoIndices = tweet.media.enumerated().compactMap { index, media -> Int? in
            if case .photo = media.kind { return index } else { return nil }
        }
        guard !photoIndices.isEmpty else {
            if tweet.restID != focalID { push(ThreadViewController(tweet: tweet)) }
            return
        }
        let start = min(max(0, tappedIndex), photoIndices.count - 1)
        presentPhotoViewer(for: tweet, photoIndices: photoIndices, startAt: start)
    }

    func toggleLike(_ tweet: Tweet, cell: TweetCell?) {
        Engagement.toggle(.like, tweet: tweet, cell: cell, host: self) { [weak self] on in
            self?.confirmEngagement(id: tweet.restID) { $0.togglingLike(to: on) }
        }
    }

    /// Optimistic repost toggle, same contract as `toggleLike`.
    func toggleRetweet(_ tweet: Tweet, cell: TweetCell?) {
        Engagement.toggle(.repost, tweet: tweet, cell: cell, host: self) { [weak self] on in
            self?.confirmEngagement(id: tweet.restID) { $0.togglingRetweet(to: on) }
        }
    }

    /// Optimistic bookmark toggle, same contract as `toggleLike`.
    func toggleBookmark(_ tweet: Tweet, cell: TweetCell?) {
        Engagement.toggle(.bookmark, tweet: tweet, cell: cell, host: self) { [weak self] on in
            self?.confirmEngagement(id: tweet.restID) { $0.togglingBookmark(to: on) }
        }
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
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        releaseFocalPin(settling: false)
        InlineVideoPlayback.pauseAll(in: collectionView)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { settleVideoPlayback() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settleVideoPlayback() }
    func scrollViewDidScrollToTop(_ scrollView: UIScrollView) { settleVideoPlayback() }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { settleVideoPlayback() }

    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        (cell as? TweetCell)?.releaseVideo()
    }

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
        return UIContextMenuConfiguration(identifier: id as NSString, previewProvider: nil) { [weak self] _ in
            self?.tweetContextMenu(tweet)
        }
    }
}
