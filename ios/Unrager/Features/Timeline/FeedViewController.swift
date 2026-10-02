import UIKit
import AVKit
import Combine
import UnragerKit

/// Generic tweet-feed screen: compositional layout + diffable data source over
/// `Tweet.ID`, prefetching, pull-to-refresh and infinite scroll. Home, Search,
/// profile timelines, bookmarks and mentions all reuse it by swapping the
/// view model's `Source`.
class FeedViewController: UIViewController, TweetActionHandling {
    let viewModel: TimelineViewModel
    private(set) var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var tweetsByID: [String: Tweet] = [:]
    private var cancellables = Set<AnyCancellable>()
    private let emptyState = EmptyStateView()
    private let loadingIndicator = UIActivityIndicatorView(style: .medium)
    private let collectingLabel = UILabel()
    private var collectingStorage: MetalCollectingView?
    /// Built only when the filter's collect-then-show phase actually runs: it
    /// owns a Metal device and compiles its shader, which feeds that never
    /// collect (profiles, search, bookmarks) have no reason to pay for.
    private var collectingView: MetalCollectingView {
        if let collectingStorage { return collectingStorage }
        let made = MetalCollectingView(frame: .zero)
        made.isHidden = true
        view.addManaged(made)
        made.pinEdges(to: view)
        view.insertSubview(made, belowSubview: collectionView)
        collectingStorage = made
        return made
    }
    private var lastErrorText: String?
    /// A subtle "updated Nm ago" pill floated over the top of Home feeds,
    /// surfacing the materialized buffer's freshness. It sits in a reserved
    /// strip above the first tweet (so it never overlaps a row at rest) and is
    /// non-interactive, so taps and scrolls pass straight through to the feed.
    /// Hidden on non-Home feeds and while the buffer is cold.
    private let freshnessPill = UIView()
    private let freshnessLabel = UILabel()
    /// The pill's top pin. Its constant is offset against `additionalSafeAreaInsets`
    /// so the pill stays in the reserved top strip rather than riding the inset down.
    private var freshnessTopConstraint: NSLayoutConstraint!
    /// Re-derives the "updated Nm ago" pill while the feed is on screen, so it
    /// climbs live instead of freezing at the value from the last load.
    private var freshnessTimer: Timer?
    /// Auto-hides the "updated Nm ago" pill a few seconds after it appears, and
    /// stays hidden (the 20s tick won't re-pop it) until the feed is entered
    /// again — it's a glance, not a permanent fixture.
    private var freshnessHideWork: DispatchWorkItem?
    private var freshnessDismissed = false
    /// Set between drag-begin and the feed coming to rest. No inline video plays
    /// while scrolling, so `AVPlayer` allocation/decode never lands on the scroll
    /// path — the source of the start-of-scroll frame spike.
    private var isScrolling = false
    /// A feed replace (e.g. the network result landing over the instant cache
    /// seed) that arrived mid-scroll; held until the scroll settles so tweets
    /// never reflow under the user's finger.
    private var pendingTweets: [Tweet]?

    /// Navigation hooks; if unset, falls back to opening the X URL in the browser.
    var openTweet: ((Tweet) -> Void)?
    var openProfile: ((String) -> Void)?

    /// Optional scrolling header (e.g. a profile header) shown above the feed.
    var headerView: UIView?
    static let headerKind = "feed-header"
    static let footerKind = "feed-footer"

    private lazy var cellRegistration = UICollectionView.CellRegistration<TweetCell, String> {
        [weak self] cell, indexPath, id in
        guard let self, let tweet = self.tweetsByID[id] else { return }
        let contentWidth = self.collectionView.bounds.width - 44 - DesignSystem.Spacing.l
            - DesignSystem.Spacing.m - DesignSystem.Spacing.l
        cell.configure(with: tweet, imagesEnabled: AppSettings.imagesEnabled,
                       contentWidth: max(120, contentWidth), seen: self.viewModel.isSeen(tweet.restID),
                       bodyLineLimit: self.expandedBodies.contains(id) ? 0 : TweetCell.feedBodyLineLimit)
        self.applyFlag(to: cell, author: tweet.author)
        cell.onTapAuthor = { [weak self] in self?.handleProfile(tweet.author.handle) }
        cell.onTapPhoto = { [weak self] index in self?.openMedia(tweet, at: index) }
        cell.onTapCard = { url in UIApplication.shared.open(url) }
        cell.onReply = { [weak self] in self?.presentReply(tweet) }
        cell.onTapQuoted = { [weak self] in
            if let quoted = tweet.quotedTweet { self?.handleSelect(quoted) }
        }
        cell.onLike = { [weak self, weak cell] in self?.toggleLike(tweet, cell: cell) }
        cell.onToggleRetweet = { [weak self, weak cell] in self?.toggleRetweet(tweet, cell: cell) }
        cell.onQuote = { [weak self] in self?.presentQuote(tweet) }
        cell.onToggleBookmark = { [weak self, weak cell] in self?.toggleBookmark(tweet, cell: cell) }
        cell.onShare = { [weak self] in self?.shareTweet(tweet) }
        cell.onTapMention = { [weak self] handle in self?.handleProfile(handle) }
        cell.onTapHashtag = { [weak self] query in self?.openHashtag(query) }
        cell.onShowMore = { [weak self] in self?.expandBody(id) }
        if self.isOwnTweet(tweet) {
            cell.enableLikers { [weak self] in
                self?.navigationController?.pushViewController(LikersViewController(tweetID: tweet.restID), animated: true)
            }
        }
    }

    /// Tweet ids the user expanded past the feed's body line cap; those rows
    /// render their full text until the screen goes away.
    private var expandedBodies = Set<String>()

    /// Re-renders one row with its full body after a "Show more" tap.
    private func expandBody(_ id: String) {
        expandedBodies.insert(id)
        var snapshot = dataSource.snapshot()
        guard snapshot.itemIdentifiers.contains(id) else { return }
        snapshot.reconfigureItems([id])
        dataSource.apply(snapshot, animatingDifferences: true)
    }

    init(viewModel: TimelineViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = DesignSystem.Color.background
        configureCollectionView()
        configureFreshness()
        configureDataSource()
        configureNavigationDefaults()
        configureUnreadButton()
        bind()
        viewModel.first()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        settleVideoPlayback()
        freshnessDismissed = false
        startFreshnessTimer()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        freshnessTimer?.invalidate()
        freshnessTimer = nil
        pauseAllVideos()
    }

    /// Ticks the freshness pill every 20s while visible so "updated Nm ago"
    /// stays current; torn down off screen.
    private func startFreshnessTimer() {
        freshnessTimer?.invalidate()
        freshnessTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.viewModel.tickFreshness()
        }
    }

    private func configureNavigationDefaults() {
        if openTweet == nil {
            openTweet = { [weak self] tweet in
                self?.navigationController?.pushViewController(ThreadViewController(tweet: tweet), animated: true)
            }
        }
        if openProfile == nil {
            openProfile = { [weak self] handle in
                self?.navigationController?.pushViewController(ProfileViewController(handle: handle), animated: true)
            }
        }
    }

    func askMenu(for tweet: Tweet) -> UIMenu {
        let api = AppEnvironment.shared.api
        return UIMenu(title: "Ask", image: DesignSystem.icon("sparkles"), children: AskPreset.allCases.map { preset in
            UIAction(title: preset.title) { [weak self] _ in
                self?.presentStream(title: preset.title) { api.askStream(tweetID: tweet.restID, preset: preset) }
            }
        })
    }

    func tweetCell(for tweet: Tweet) -> TweetCell? { cell(for: tweet) }

    private func cell(for tweet: Tweet) -> TweetCell? {
        guard let index = dataSource.indexPath(for: tweet.restID) else { return nil }
        return collectionView.cellForItem(at: index) as? TweetCell
    }

    /// Decorates the row with the author's country flag: synchronously when
    /// the author already resolved this session, otherwise lazily — the
    /// resolve lands as a direct label update on whichever cells currently
    /// show that author, with no snapshot churn.
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

    private func presentReply(_ tweet: Tweet) {
        let compose = ComposeViewController(mode: .reply(to: tweet))
        present(UINavigationController(rootViewController: compose), animated: true)
    }

    private func configureCollectionView() {
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: makeLayout())
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.keyboardDismissMode = .onDrag
        view.addManaged(collectionView)
        collectionView.pinEdges(to: view)

        let refresh = UIRefreshControl()
        refresh.tintColor = DesignSystem.Color.secondaryLabel
        refresh.addTarget(self, action: #selector(pullToRefresh), for: .valueChanged)
        collectionView.refreshControl = refresh

        emptyState.isHidden = true
        emptyState.onRetry = { [weak self] in self?.viewModel.refresh() }
        view.addManaged(emptyState)
        emptyState.pinEdges(toSafeAreaOf: view)

        loadingIndicator.hidesWhenStopped = true
        view.addManaged(loadingIndicator)

        collectingLabel.font = DesignSystem.Typography.metric()
        collectingLabel.textColor = DesignSystem.Color.secondaryLabel
        collectingLabel.textAlignment = .center
        collectingLabel.isHidden = true
        view.addManaged(collectingLabel)
        NSLayoutConstraint.activate([
            loadingIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            collectingLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            collectingLabel.topAnchor.constraint(equalTo: loadingIndicator.bottomAnchor, constant: DesignSystem.Spacing.m),
        ])

    }

    /// Builds the freshness pill: a dim caption on a subtle capsule, pinned
    /// top-centre over the feed and non-interactive. `applyFreshness` reserves a
    /// matching top strip (`additionalSafeAreaInsets`) when it's shown, so the
    /// first tweet clears it at rest and the pill never overlaps a row.
    private func configureFreshness() {
        freshnessLabel.font = DesignSystem.Typography.caption()
        freshnessLabel.textColor = DesignSystem.Color.secondaryLabel
        freshnessLabel.textAlignment = .center
        freshnessPill.backgroundColor = DesignSystem.Color.elevatedBackground
        freshnessPill.clipsToBounds = true
        freshnessPill.isUserInteractionEnabled = false
        freshnessPill.isHidden = true
        freshnessPill.addManaged(freshnessLabel)
        view.addManaged(freshnessPill)
        freshnessTopConstraint = freshnessPill.topAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.topAnchor, constant: DesignSystem.Spacing.xs)
        NSLayoutConstraint.activate([
            freshnessPill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            freshnessTopConstraint,
            freshnessLabel.topAnchor.constraint(equalTo: freshnessPill.topAnchor, constant: DesignSystem.Spacing.xxs),
            freshnessLabel.bottomAnchor.constraint(equalTo: freshnessPill.bottomAnchor, constant: -DesignSystem.Spacing.xxs),
            freshnessLabel.leadingAnchor.constraint(equalTo: freshnessPill.leadingAnchor, constant: DesignSystem.Spacing.m),
            freshnessLabel.trailingAnchor.constraint(equalTo: freshnessPill.trailingAnchor, constant: -DesignSystem.Spacing.m),
        ])
    }

    /// Opens tapped media in a full-screen viewer — a zoomable photo gallery, or
    /// the native player for video/GIF — instead of navigating into the thread.
    private func openMedia(_ tweet: Tweet, at tappedIndex: Int) {
        if let video = tweet.media.enumerated().first(where: { $0.element.isVideo }) {
            let url = video.element.videoURL.flatMap(URL.init)
                ?? AppEnvironment.shared.api.mediaURL(tweetID: tweet.restID, index: video.offset)
            pauseAllVideos()
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
        guard !photoIndices.isEmpty else { handleSelect(tweet); return }
        let start = min(max(0, tappedIndex), photoIndices.count - 1)
        presentPhotoViewer(for: tweet, photoIndices: photoIndices, startAt: start)
    }

    /// A list-configured section so rows get native swipe actions, with the
    /// list's own separators suppressed (the cell draws its own) and the
    /// profile header riding along as a boundary item.
    private func makeLayout() -> UICollectionViewCompositionalLayout {
        let hasHeader = headerView != nil
        let layout = UICollectionViewCompositionalLayout { [weak self] _, environment in
            var config = UICollectionLayoutListConfiguration(appearance: .plain)
            config.showsSeparators = false
            config.backgroundColor = .clear
            config.leadingSwipeActionsConfigurationProvider = { [weak self] indexPath in
                self?.leadingSwipeActions(at: indexPath)
            }
            config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
                self?.trailingSwipeActions(at: indexPath)
            }
            let section = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
            var supplementaries: [NSCollectionLayoutBoundarySupplementaryItem] = []
            if hasHeader {
                let headerSize = NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1), heightDimension: .estimated(160))
                supplementaries.append(NSCollectionLayoutBoundarySupplementaryItem(
                    layoutSize: headerSize, elementKind: Self.headerKind, alignment: .top))
            }
            let footerSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1), heightDimension: .estimated(56))
            supplementaries.append(NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: footerSize, elementKind: Self.footerKind, alignment: .bottom))
            section.boundarySupplementaryItems = supplementaries
            return section
        }
        return layout
    }

    private func tweet(at indexPath: IndexPath) -> Tweet? {
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return nil }
        return tweetsByID[id]
    }

    private func leadingSwipeActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let tweet = tweet(at: indexPath) else { return nil }
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
        guard let tweet = tweet(at: indexPath) else { return nil }
        let reply = UIContextualAction(style: .normal, title: "Reply") { [weak self] _, _, done in
            self?.presentReply(tweet)
            done(true)
        }
        reply.image = DesignSystem.icon("arrowshape.turn.up.left.fill", pointSize: 18)
        reply.backgroundColor = DesignSystem.Color.accent

        let api = AppEnvironment.shared.api
        let ask = UIContextualAction(style: .normal, title: "Ask") { [weak self] _, _, done in
            self?.presentStream(title: AskPreset.explain.title) { api.askStream(tweetID: tweet.restID, preset: .explain) }
            done(true)
        }
        ask.image = DesignSystem.icon("sparkles", pointSize: 18)
        ask.backgroundColor = DesignSystem.Color.quote
        return UISwipeActionsConfiguration(actions: [reply, ask])
    }

    private func configureDataSource() {
        let registration = cellRegistration
        dataSource = UICollectionViewDiffableDataSource<Int, String>(collectionView: collectionView) {
            collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
        let headerReg = UICollectionView.SupplementaryRegistration<HostReusableView>(
            elementKind: Self.headerKind) { [weak self] host, _, _ in
            if let header = self?.headerView { host.host(header) }
        }
        let footerReg = UICollectionView.SupplementaryRegistration<FeedFooterView>(
            elementKind: Self.footerKind) { [weak self] footer, _, _ in
            self?.configureFooter(footer)
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            if kind == Self.footerKind {
                return collectionView.dequeueConfiguredReusableSupplementary(using: footerReg, for: indexPath)
            }
            return collectionView.dequeueConfiguredReusableSupplementary(using: headerReg, for: indexPath)
        }
    }

    /// The end-of-list footer: "You're all caught up" once the cursor is
    /// exhausted, "Scroll to retry" while paging stalled but the cursor lives,
    /// and hidden while a non-empty list is still loading.
    private func configureFooter(_ footer: FeedFooterView) {
        let count = dataSource.snapshot().numberOfItems
        guard count > 0 else { footer.setHidden(); return }
        if viewModel.isExhausted {
            footer.show(text: "You're all caught up", showsRetry: false)
        } else if viewModel.isLoading.value {
            footer.showLoading()
        } else {
            footer.show(text: "Scroll to retry", showsRetry: true)
            footer.onRetry = { [weak self] in self?.viewModel.loadMoreIfNeeded(currentIndex: count - 1) }
        }
    }

    /// Re-renders the footer to reflect the current load/exhaustion state.
    private func refreshFooter() {
        for indexPath in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: Self.footerKind) {
            if let footer = collectionView.supplementaryView(forElementKind: Self.footerKind, at: indexPath) as? FeedFooterView {
                configureFooter(footer)
            }
        }
    }

    private func bind() {
        viewModel.tweets
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tweets in self?.apply(tweets) }
            .store(in: &cancellables)

        viewModel.isRefreshing
            .receive(on: DispatchQueue.main)
            .sink { [weak self] refreshing in
                guard let self, let rc = self.collectionView.refreshControl else { return }
                if refreshing {
                    rc.attributedTitle = self.refreshTitle("Loading new tweets…")
                } else {
                    rc.endRefreshing()
                }
            }
            .store(in: &cancellables)

        viewModel.freshness
            .receive(on: DispatchQueue.main)
            .sink { [weak self] freshness in self?.applyFreshness(freshness) }
            .store(in: &cancellables)

        viewModel.isLoading
            .receive(on: DispatchQueue.main)
            .sink { [weak self] loading in
                if loading { self?.lastErrorText = nil }
                self?.updateChrome()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.pauseAllVideos() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.settleVideoPlayback() }
            .store(in: &cancellables)

        viewModel.collectingProgress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateChrome() }
            .store(in: &cancellables)

        viewModel.errorMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in self?.handleError(message) }
            .store(in: &cancellables)

        viewModel.seenChanged
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ids in self?.reconfigure(ids) }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: TwemojiCache.imagesDidLoad)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reconfigureVisibleForEmoji() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: AppSettings.fontScaleDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reloadForFontScale() }
            .store(in: &cancellables)
    }

    /// Re-renders every row (on- and off-screen) after a text-size change so
    /// fonts re-resolve and self-sizing heights re-measure.
    private func reloadForFontScale() {
        var snapshot = dataSource.snapshot()
        guard snapshot.numberOfItems > 0 else { return }
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// Re-renders on-screen rows once Twemoji art lands so a cold-cache emoji
    /// flips from the native glyph to the flat Twemoji image — never during a
    /// scroll, so it stays off the hot path.
    private func reconfigureVisibleForEmoji() {
        guard !isScrolling else { return }
        let visible = collectionView.indexPathsForVisibleItems.compactMap { dataSource.itemIdentifier(for: $0) }
        guard !visible.isEmpty else { return }
        var snapshot = dataSource.snapshot()
        let present = visible.filter { snapshot.itemIdentifiers.contains($0) }
        guard !present.isEmpty else { return }
        snapshot.reconfigureItems(present)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// Dims (or restores) the rows whose read state changed. Rows on screen are
    /// updated in place — a reconfigure would rebuild each one's photos and
    /// restart its video, once a second while scrolling Following — and rows off
    /// screen pick the state up when they are next dequeued.
    private func reconfigure(_ ids: [String]) {
        let changed = Set(ids)
        for indexPath in collectionView.indexPathsForVisibleItems {
            guard let id = dataSource.itemIdentifier(for: indexPath), changed.contains(id),
                  let cell = collectionView.cellForItem(at: indexPath) as? TweetCell else { continue }
            cell.setSeen(viewModel.isSeen(id))
        }
        updateUnreadCount()
    }

    /// Display the feed strictly newest-first. Used by the Following feed's
    /// chronological toggle; re-sorts whatever's already loaded without a
    /// refetch, and orders every later page on arrival.
    private(set) var chronologicalSort = false

    func setChronologicalSort(_ on: Bool) {
        guard on != chronologicalSort else { return }
        chronologicalSort = on
        apply(viewModel.tweets.value)
    }

    /// Publishes the model's tweets to the list. Replacing the list mid-scroll
    /// (a network result landing over the cache seed) would reflow tweets under
    /// the user's finger, so while they are scrolling it is held until the
    /// scroll settles; a pure pagination append (more tweets than shown, same
    /// prefix) only grows the bottom and is applied at once.
    private func apply(_ incoming: [Tweet]) {
        let tweets = chronologicalSort ? incoming.sorted { $0.createdAt > $1.createdAt } : incoming
        let hadItems = dataSource.snapshot().numberOfItems > 0
        let activelyScrolling = collectionView.isDragging || collectionView.isDecelerating
        if hadItems, !tweets.isEmpty, activelyScrolling, !isPureAppend(tweets) {
            pendingTweets = tweets
            return
        }
        pendingTweets = nil
        applyNow(tweets)
    }

    /// True when `tweets` only adds rows after the current list (infinite scroll)
    /// — those grow the bottom and never disturb the viewport, so they needn't
    /// be deferred.
    private func isPureAppend(_ tweets: [Tweet]) -> Bool {
        let current = dataSource.snapshot().itemIdentifiers
        guard tweets.count >= current.count else { return false }
        return zip(current, tweets).allSatisfy { $0 == $1.restID }
    }

    /// Applies `tweets` to the list. Once the user has scrolled into it, their
    /// viewport is held still across the update: the topmost visible tweet is
    /// the anchor, the snapshot applies without animation, and the anchor's
    /// on-screen position is restored, so inserts and removals above it never
    /// shove the content.
    private func applyNow(_ tweets: [Tweet]) {
        var changed: [String] = []
        for tweet in tweets {
            if let existing = tweetsByID[tweet.restID], existing.displayDiffers(from: tweet) {
                changed.append(tweet.restID)
            }
            tweetsByID[tweet.restID] = tweet
        }
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(tweets.map(\.restID), toSection: 0)
        if !changed.isEmpty { snapshot.reconfigureItems(changed) }
        if !tweets.isEmpty { lastErrorText = nil }

        let hadItems = dataSource.snapshot().numberOfItems > 0
        let growsBottomOnly = hadItems && changed.isEmpty && isPureAppend(tweets)
        let anchor = (hadItems && !tweets.isEmpty && !growsBottomOnly && collectionView.contentOffset.y > 1)
            ? scrollAnchor(in: snapshot) : nil
        let animated = anchor == nil && !growsBottomOnly && !tweets.isEmpty
        dataSource.apply(snapshot, animatingDifferences: animated) { [weak self] in
            if let anchor { self?.restoreScrollAnchor(anchor) }
        }
        updateChrome()
        updateUnreadCount()
        if !isScrolling {
            DispatchQueue.main.async { [weak self] in self?.settleVideoPlayback() }
        }
        DispatchQueue.main.async { [weak self] in self?.pageIfContentFitsScreen() }
    }

    /// A feed whose loaded posts don't fill the screen never scrolls, so no row
    /// reaches the point that asks for the next page; ask for it here, until the
    /// screen is full or the feed has ended.
    private func pageIfContentFitsScreen() {
        let count = dataSource.snapshot().numberOfItems
        guard isViewLoaded, view.window != nil, count > 0, collectionView.bounds.height > 0,
              collectionView.contentSize.height < collectionView.bounds.height else { return }
        viewModel.loadMoreIfNeeded(currentIndex: count - 1)
    }

    /// Flushes a deferred feed replace once the scroll comes to rest.
    private func flushPendingTweets() {
        guard let pending = pendingTweets else { return }
        pendingTweets = nil
        applyNow(pending)
    }

    /// The topmost on-screen tweet that survives into `snapshot`, with its
    /// distance below the viewport top — the anchor for a scroll-stable update.
    private func scrollAnchor(in snapshot: NSDiffableDataSourceSnapshot<Int, String>) -> (id: String, offset: CGFloat)? {
        let surviving = Set(snapshot.itemIdentifiers)
        for indexPath in collectionView.indexPathsForVisibleItems.sorted() {
            guard let id = dataSource.itemIdentifier(for: indexPath), surviving.contains(id),
                  let attributes = collectionView.layoutAttributesForItem(at: indexPath) else { continue }
            return (id, attributes.frame.minY - collectionView.contentOffset.y)
        }
        return nil
    }

    private func restoreScrollAnchor(_ anchor: (id: String, offset: CGFloat)) {
        guard let indexPath = dataSource.indexPath(for: anchor.id),
              let attributes = collectionView.layoutAttributesForItem(at: indexPath) else { return }
        let target = attributes.frame.minY - anchor.offset
        let maxOffset = max(0, collectionView.contentSize.height - collectionView.bounds.height
            + collectionView.adjustedContentInset.bottom)
        collectionView.setContentOffset(CGPoint(x: 0, y: min(max(0, target), maxOffset)), animated: false)
    }

    // MARK: - Inline video playback (scroll-aware)

    /// Whether clips may start on their own: not with the system's video
    /// autoplay switched off, Reduce Motion on, or images switched off in the
    /// app, where a clip would pull its poster and stream regardless.
    private static var autoplaysVideo: Bool {
        UIAccessibility.isVideoAutoplayEnabled && !UIAccessibility.isReduceMotionEnabled && AppSettings.imagesEnabled
    }

    private func pauseAllVideos() {
        for case let cell as TweetCell in collectionView.visibleCells { cell.pauseVideo() }
    }

    /// Plays only the on-screen video cell with the greatest overlap with the
    /// viewport and pauses the rest — the "one video at a time, only at rest"
    /// rule. Called when the feed settles; never while scrolling.
    func settleVideoPlayback() {
        isScrolling = false
        guard Self.autoplaysVideo, isViewLoaded, view.window != nil else {
            pauseAllVideos()
            return
        }
        let visible = CGRect(origin: collectionView.contentOffset, size: collectionView.bounds.size)
        var best: TweetCell?
        var bestOverlap: CGFloat = 0
        for case let cell as TweetCell in collectionView.visibleCells where cell.hasVideo {
            guard let indexPath = collectionView.indexPath(for: cell),
                  let frame = collectionView.collectionViewLayout.layoutAttributesForItem(at: indexPath)?.frame
            else { continue }
            let intersection = frame.intersection(visible)
            let overlap = intersection.isNull ? 0 : intersection.height
            if overlap > bestOverlap { bestOverlap = overlap; best = cell }
        }
        for case let cell as TweetCell in collectionView.visibleCells where cell.hasVideo {
            if cell === best { cell.playVideo() } else { cell.pauseVideo() }
        }
    }

    /// Centralizes empty/loading/error chrome: a subtle centered spinner while a
    /// feed (or feed switch) is loading, and the illustrated empty/error state
    /// only once a load has settled — so switching feeds no longer flashes
    /// "Nothing here yet" for a frame.
    private func updateChrome() {
        refreshFooter()
        guard dataSource.snapshot().numberOfItems == 0 else {
            emptyState.isHidden = true
            loadingIndicator.stopAnimating()
            hideCollecting()
            return
        }
        if viewModel.awaitingQuery {
            loadingIndicator.stopAnimating()
            hideCollecting()
            emptyState.isHidden = false
            emptyState.show(symbol: "magnifyingglass", title: "Search X",
                            subtitle: "Find tweets, people, and topics.", showRetry: false)
        } else if viewModel.collectingProgress.value != nil, MetalCollectingView.isSupported {
            emptyState.isHidden = true
            loadingIndicator.stopAnimating()
            collectingLabel.isHidden = true
            showCollecting()
        } else if viewModel.isLoading.value || !viewModel.hasLoadedOnce {
            emptyState.isHidden = true
            hideCollecting()
            loadingIndicator.startAnimating()
            updateCollectingLabel()
        } else if let error = lastErrorText {
            loadingIndicator.stopAnimating()
            hideCollecting()
            emptyState.isHidden = false
            emptyState.show(symbol: "exclamationmark.triangle", title: "Couldn't load", subtitle: error, showRetry: true)
        } else {
            loadingIndicator.stopAnimating()
            hideCollecting()
            emptyState.isHidden = false
            emptyState.show(symbol: "tray", title: "Nothing here yet", subtitle: "Pull to refresh.", showRetry: true)
        }
    }

    /// Reveals the full-screen Metal collecting state, driving the latest
    /// progress into the shader and starting its display link.
    private func showCollecting() {
        if let progress = viewModel.collectingProgress.value {
            collectingView.update(collected: progress, target: TimelineViewModel.targetSurvivors)
        }
        if collectingView.isHidden {
            collectingView.isHidden = false
            collectingView.start()
        }
    }

    /// Tears down the Metal collecting state — pauses its display link so it
    /// draws nothing while hidden.
    private func hideCollecting() {
        guard let collectingStorage, !collectingStorage.isHidden else { return }
        collectingStorage.isHidden = true
        collectingStorage.stop()
    }

    /// While collect-then-show filtering is gathering a batch, replaces the bare
    /// spinner caption with "collecting tweets… N/25". Used only on the
    /// fallback (no-Metal) path.
    private func updateCollectingLabel() {
        if let progress = viewModel.collectingProgress.value {
            collectingLabel.isHidden = false
            collectingLabel.text = "collecting tweets… \(progress)/\(TimelineViewModel.targetSurvivors)"
        } else {
            collectingLabel.isHidden = true
        }
    }

    private func handleError(_ message: String) {
        lastErrorText = message
        if dataSource.snapshot().numberOfItems == 0 {
            updateChrome()
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            showStaleNotice()
        }
    }

    /// Says so when a refresh failed over posts already on screen, which would
    /// otherwise pass for live ones: the saved posts stay, with a note on top.
    private func showStaleNotice() {
        freshnessHideWork?.cancel()
        freshnessDismissed = false
        freshnessLabel.text = "Couldn't refresh · showing saved posts"
        freshnessPill.isHidden = false
        freshnessPill.alpha = 1
        view.layoutIfNeeded()
        freshnessPill.layer.cornerRadius = freshnessPill.bounds.height / 2
        setFreshnessInset(freshnessPill.frame.height + DesignSystem.Spacing.s * 2)
        scheduleFreshnessHide()
        UIAccessibility.post(notification: .announcement, argument: freshnessLabel.text)
    }

    @objc func pullToRefresh() { viewModel.refresh() }

    /// A dim, caption-sized pull-to-refresh title for the "Loading new tweets…"
    /// state.
    private func refreshTitle(_ text: String) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [.foregroundColor: DesignSystem.Color.secondaryLabel,
                         .font: DesignSystem.Typography.caption()])
    }

    /// Shows or hides the freshness pill and reserves a matching top strip so
    /// the first tweet clears it. The pill floats over the feed and never
    /// mutates a row.
    private func applyFreshness(_ text: String?) {
        guard let text, !text.isEmpty else {
            freshnessHideWork?.cancel()
            freshnessDismissed = false
            freshnessPill.isHidden = true
            freshnessPill.alpha = 1
            setFreshnessInset(0)
            return
        }
        freshnessLabel.text = text
        guard !freshnessDismissed else { return }
        freshnessPill.isHidden = false
        freshnessPill.alpha = 1
        view.layoutIfNeeded()
        freshnessPill.layer.cornerRadius = freshnessPill.bounds.height / 2
        setFreshnessInset(freshnessPill.frame.height + DesignSystem.Spacing.s * 2)
        scheduleFreshnessHide()
    }

    /// Fades the freshness pill out ~4s after it shows and reclaims its strip,
    /// so it reads as a brief "here's how fresh this is" glance.
    private func scheduleFreshnessHide() {
        freshnessHideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            UIView.animate(withDuration: 0.3) {
                self.freshnessPill.alpha = 0
            } completion: { _ in
                self.freshnessDismissed = true
                self.freshnessPill.isHidden = true
                self.freshnessPill.alpha = 1
                self.setFreshnessInset(0)
            }
        }
        freshnessHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    /// Reserves a `top`-point strip for the freshness pill via
    /// `additionalSafeAreaInsets` — which `UIRefreshControl` never clobbers,
    /// unlike `contentInset` — and counter-shifts the pill's pin so it sits in
    /// that strip instead of riding the inset down onto the first row.
    private func setFreshnessInset(_ top: CGFloat) {
        additionalSafeAreaInsets.top = top
        freshnessTopConstraint.constant = DesignSystem.Spacing.xs - top
        view.layoutIfNeeded()
    }

    private func handleSelect(_ tweet: Tweet) {
        if let openTweet {
            openTweet(tweet)
        } else if let url = URL(string: tweet.url) {
            UIApplication.shared.open(url)
        }
    }

    private func handleProfile(_ handle: String) {
        if let openProfile {
            openProfile(handle)
        } else if let url = URL(string: "https://x.com/\(handle)") {
            UIApplication.shared.open(url)
        }
    }

    /// Opens a tapped `#hashtag` as a search-results feed pushed onto the stack.
    private func openHashtag(_ query: String) {
        Haptics.selection()
        let results = SearchResultsViewController(query: query, product: .top)
        navigationController?.pushViewController(results, animated: true)
    }

    /// Optimistic like: flip the heart and count on the visible cell now, fire
    /// the request, and on success write the new state back into the view model
    /// (so a second tap can unlike and reconfigures don't revert the heart);
    /// only roll the cell back if the network rejects it.
    func toggleLike(_ tweet: Tweet, cell: TweetCell?) {
        let target = !(cell?.isLiked ?? tweet.favorited)
        let optimisticCount = max(0, tweet.likeCount + (target ? 1 : -1))
        cell?.applyLike(favorited: target, count: optimisticCount)
        Task {
            do {
                _ = target
                    ? try await AppEnvironment.shared.api.like(tweetID: tweet.restID)
                    : try await AppEnvironment.shared.api.unlike(tweetID: tweet.restID)
                viewModel.applyLike(id: tweet.restID, favorited: target)
            } catch {
                if cell?.tweetID == tweet.restID { cell?.applyLike(favorited: !target, count: tweet.likeCount) }
                Haptics.error()
                AppLogger.shared.warn("like failed: \(error)", category: .timeline)
            }
        }
    }

    /// Optimistic repost toggle, same contract as `toggleLike`: the arrows go
    /// green and the count bumps instantly, the confirmed state is written back
    /// through the view model, and the cell rolls back on a network reject.
    func toggleRetweet(_ tweet: Tweet, cell: TweetCell?) {
        let target = !(cell?.isRetweeted ?? tweet.retweeted)
        cell?.applyRetweet(retweeted: target, count: max(0, tweet.retweetCount + (target ? 1 : -1)))
        Task {
            do {
                _ = target
                    ? try await EngageService.engage.retweet(tweetID: tweet.restID)
                    : try await EngageService.engage.unretweet(tweetID: tweet.restID)
                viewModel.applyRetweet(id: tweet.restID, retweeted: target)
            } catch {
                if cell?.tweetID == tweet.restID { cell?.applyRetweet(retweeted: !target, count: tweet.retweetCount) }
                Haptics.error()
                AppLogger.shared.warn("retweet failed: \(error)", category: .timeline)
            }
        }
    }

    /// Optimistic bookmark toggle, same contract as `toggleLike`.
    func toggleBookmark(_ tweet: Tweet, cell: TweetCell?) {
        let target = !(cell?.isBookmarked ?? tweet.bookmarked)
        cell?.applyBookmark(bookmarked: target, count: max(0, tweet.bookmarkCount + (target ? 1 : -1)))
        Task {
            do {
                _ = target
                    ? try await EngageService.engage.bookmark(tweetID: tweet.restID)
                    : try await EngageService.engage.unbookmark(tweetID: tweet.restID)
                viewModel.applyBookmark(id: tweet.restID, bookmarked: target)
            } catch {
                if cell?.tweetID == tweet.restID { cell?.applyBookmark(bookmarked: !target, count: tweet.bookmarkCount) }
                Haptics.error()
                AppLogger.shared.warn("bookmark failed: \(error)", category: .timeline)
            }
        }
    }

    /// Opens the compose screen prefilled with a quote preview of `tweet`;
    /// posting sends `quote_tweet_id`.
    func presentQuote(_ tweet: Tweet) {
        let compose = ComposeViewController(mode: .quote(of: tweet))
        present(UINavigationController(rootViewController: compose), animated: true)
    }

    // MARK: - Unread navigation

    private lazy var unreadButtonView: UIButton = {
        var config = UIButton.Configuration.tinted()
        config.cornerStyle = .capsule
        config.image = DesignSystem.icon("arrow.down.to.line", pointSize: 11, weight: .bold)
        config.imagePlacement = .leading
        config.imagePadding = 4
        config.baseForegroundColor = DesignSystem.Color.accent
        config.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 12)
        let button = UIButton(configuration: config)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.titleLabel?.numberOfLines = 1
        button.titleLabel?.lineBreakMode = .byClipping
        button.addAction(UIAction { [weak self] _ in self?.jumpToNextUnread() }, for: .touchUpInside)
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(unreadPillLongPressed(_:)))
        button.addGestureRecognizer(longPress)
        return button
    }()

    /// Long-pressing the unread pill marks every loaded tweet read (the TUI's
    /// `U`): rows dim, the pill clears, and the server's read tracker catches up
    /// in one batch.
    @objc private func unreadPillLongPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        Haptics.success()
        viewModel.markAllRead()
        updateUnreadCount()
    }

    private lazy var unreadButton: UIBarButtonItem = {
        let item = UIBarButtonItem(customView: unreadButtonView)
        item.isHidden = true
        return item
    }()

    /// Shows a "⤓ N" pill — a jump-down glyph and the unread count — only while
    /// there are unread tweets below the fold (the jump scrolls *down* to the
    /// next one). Hidden entirely at zero, so there's no bare, inert arrow.
    func updateUnreadCount() {
        guard viewModel.supportsSeenTracking else { return }
        let count = viewModel.unreadCount
        unreadButton.isHidden = count == 0
        guard count > 0 else { return }
        unreadButtonView.configuration?.title = count > 99 ? "99+" : "\(count)"
        unreadButtonView.accessibilityLabel = "\(count) unread, jump to next unread"
        unreadButtonView.accessibilityHint = "Scrolls to the next unread tweet. Long-press to mark all read."
    }

    /// Shows the "jump to next unread" button only on seen-tracking feeds
    /// (Following / Mentions). Subclasses that own `rightBarButtonItems` call
    /// `unreadBarButton` to fold it into their own bar.
    func configureUnreadButton() {
        guard !(self is HomeViewController) else { return }
        navigationItem.rightBarButtonItem = viewModel.supportsSeenTracking ? unreadButton : nil
    }

    /// The unread button when the current source supports seen-tracking, else
    /// nil — for subclasses composing their own bar-button array.
    var unreadBarButton: UIBarButtonItem? { viewModel.supportsSeenTracking ? unreadButton : nil }

    /// Walks the *displayed* order (the diffable snapshot, which reflects the
    /// chronological re-sort when it's on — model indices don't), wrapping to
    /// the top, and scrolls to the first unread row past the viewport.
    private func jumpToNextUnread() {
        let ids = dataSource.snapshot().itemIdentifiers
        guard !ids.isEmpty else { return }
        let visible = collectionView.indexPathsForVisibleItems.map(\.item).max() ?? -1
        let ordered = Array((visible + 1)..<ids.count) + Array(0...max(0, min(visible, ids.count - 1)))
        guard let next = ordered.first(where: { $0 >= 0 && $0 < ids.count && !viewModel.isSeen(ids[$0]) })
        else { return }
        Haptics.selection()
        collectionView.scrollToItem(at: IndexPath(item: next, section: 0), at: .top, animated: true)
    }
}

extension FeedViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard let id = dataSource.itemIdentifier(for: indexPath), let tweet = tweetsByID[id] else { return }
        handleSelect(tweet)
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        viewModel.loadMoreIfNeeded(currentIndex: indexPath.item)
        if let id = dataSource.itemIdentifier(for: indexPath) { viewModel.enqueueSeen([id]) }
    }

    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        (cell as? TweetCell)?.pauseVideo()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        isScrolling = true
        pauseAllVideos()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { settleVideoPlayback(); flushPendingTweets() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settleVideoPlayback(); flushPendingTweets() }
    func scrollViewDidScrollToTop(_ scrollView: UIScrollView) { settleVideoPlayback(); flushPendingTweets() }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { settleVideoPlayback(); flushPendingTweets() }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard let id = dataSource.itemIdentifier(for: indexPath), let tweet = tweetsByID[id] else { return nil }
        return UIContextMenuConfiguration(identifier: id as NSString, previewProvider: nil) { [weak self] _ in
            self?.tweetContextMenu(tweet)
        }
    }
}

extension FeedViewController: UICollectionViewDataSourcePrefetching {
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        guard AppSettings.imagesEnabled else { return }
        let width = collectionView.bounds.width
        for indexPath in indexPaths {
            guard let id = dataSource.itemIdentifier(for: indexPath), let tweet = tweetsByID[id] else { continue }
            if let avatar = tweet.author.avatarURL.flatMap(URL.init) {
                ImageLoader.prefetch(avatar, pointSize: CGSize(width: 44, height: 44), scale: 3)
            }
            if let url = Self.previewURL(for: tweet) {
                ImageLoader.prefetch(url, pointSize: CGSize(width: width, height: width * 9 / 16), scale: 2)
            }
            Task { await TwemojiCache.shared.prewarm(graphemesIn: tweet.text) }
        }
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths {
            guard let id = dataSource.itemIdentifier(for: indexPath), let tweet = tweetsByID[id] else { continue }
            if let url = Self.previewURL(for: tweet) { ImageLoader.cancelPrefetch(url) }
        }
    }

    /// The first attachment that has a fetchable cover image (polls have none).
    private static func previewURL(for tweet: Tweet) -> URL? {
        for media in tweet.media {
            if case .poll = media.kind { continue }
            if !media.url.isEmpty { return URL(string: media.url) }
        }
        return nil
    }
}
