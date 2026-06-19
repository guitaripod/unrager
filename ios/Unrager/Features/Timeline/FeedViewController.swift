import UIKit
import AVKit
import Combine
import UnragerKit

/// Generic tweet-feed screen: compositional layout + diffable data source over
/// `Tweet.ID`, prefetching, pull-to-refresh and infinite scroll. Home, Search,
/// profile timelines, bookmarks and mentions all reuse it by swapping the
/// view model's `Source`.
class FeedViewController: UIViewController {
    let viewModel: TimelineViewModel
    private(set) var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var tweetsByID: [String: Tweet] = [:]
    private var cancellables = Set<AnyCancellable>()
    private let emptyState = EmptyStateView()
    private let loadingIndicator = UIActivityIndicatorView(style: .medium)
    private let collectingLabel = UILabel()
    private var lastErrorText: String?
    /// Set between drag-begin and the feed coming to rest. No inline video plays
    /// while scrolling, so `AVPlayer` allocation/decode never lands on the scroll
    /// path — the source of the start-of-scroll frame spike.
    private var isScrolling = false

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
                       contentWidth: max(120, contentWidth), seen: self.viewModel.isSeen(tweet.restID))
        cell.onTapAuthor = { [weak self] in self?.handleProfile(tweet.author.handle) }
        cell.onTapPhoto = { [weak self] index in self?.openMedia(tweet, at: index) }
        cell.onTapCard = { url in UIApplication.shared.open(url) }
        cell.onReply = { [weak self] in self?.presentReply(tweet) }
        cell.onTapQuoted = { [weak self] in
            if let quoted = tweet.quotedTweet { self?.handleSelect(quoted) }
        }
        cell.onLike = { [weak self] in self?.toggleLike(tweet, cell: cell) }
        cell.onTapMention = { [weak self] handle in self?.handleProfile(handle) }
        cell.onTapHashtag = { [weak self] query in self?.openHashtag(query) }
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
        configureDataSource()
        configureNavigationDefaults()
        configureUnreadButton()
        bind()
        viewModel.first()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        settleVideoPlayback()
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

    func tweetContextMenu(_ tweet: Tweet) -> UIMenu {
        let api = AppEnvironment.shared.api
        let ask = UIMenu(title: "Ask", image: DesignSystem.icon("sparkles"), children: AskPreset.allCases.map { preset in
            UIAction(title: preset.title) { [weak self] _ in
                self?.presentStream(title: preset.title) { api.askStream(tweetID: tweet.restID, preset: preset) }
            }
        })
        let translate = UIAction(title: "Translate", image: DesignSystem.icon("character.bubble")) { [weak self] _ in
            self?.presentStream(title: "Translation") { api.translateStream(tweetID: tweet.restID) }
        }
        let like = UIAction(title: tweet.favorited ? "Unlike" : "Like",
                            image: DesignSystem.icon(tweet.favorited ? "heart.slash" : "heart")) { [weak self] _ in
            self?.toggleLike(tweet, cell: self?.cell(for: tweet))
        }
        let likers = UIAction(title: "Liked by", image: DesignSystem.icon("heart.text.square")) { [weak self] _ in
            self?.navigationController?.pushViewController(LikersViewController(tweetID: tweet.restID), animated: true)
        }
        let share = UIAction(title: "Share…", image: DesignSystem.icon("square.and.arrow.up")) { [weak self] _ in
            self?.shareTweet(tweet)
        }
        let saveMedia = saveMediaAction(tweet)
        let open = UIAction(title: "Open in X", image: DesignSystem.icon("safari")) { _ in
            if let url = URL(string: tweet.url) { UIApplication.shared.open(url) }
        }
        let copy = UIAction(title: "Copy link", image: DesignSystem.icon("link")) { _ in
            UIPasteboard.general.string = tweet.url
        }
        let copyEmbed = UIAction(title: "Copy embed link", image: DesignSystem.icon("link.badge.plus")) { _ in
            UIPasteboard.general.string = Self.fixupxURL(tweet)
        }
        var topLevel: [UIMenuElement] = [ask, translate, like, likers]
        if let saveMedia { topLevel.append(saveMedia) }
        topLevel.append(UIMenu(options: .displayInline, children: [share, open, copy, copyEmbed]))
        return UIMenu(children: topLevel)
    }

    /// The fixupx embed-friendly URL (`https://fixupx.com/<handle>/status/<id>`)
    /// — pastes into chats with a working preview where x.com's doesn't.
    static func fixupxURL(_ tweet: Tweet) -> String {
        "https://fixupx.com/\(tweet.author.handle)/status/\(tweet.restID)"
    }

    private func cell(for tweet: Tweet) -> TweetCell? {
        guard let index = dataSource.indexPath(for: tweet.restID) else { return nil }
        return collectionView.cellForItem(at: index) as? TweetCell
    }

    private func saveMediaAction(_ tweet: Tweet) -> UIAction? {
        let saveable = tweet.media.enumerated().first { (_, media) in
            switch media.kind {
            case .photo, .video, .animatedGif: return true
            default: return false
            }
        }
        guard let (index, media) = saveable else { return nil }
        let isVideo = media.isVideo
        return UIAction(title: isVideo ? "Save video" : "Save image",
                        image: DesignSystem.icon(isVideo ? "arrow.down.circle" : "square.and.arrow.down")) { [weak self] _ in
            self?.saveMedia(tweetID: tweet.restID, index: index, isVideo: isVideo, fallbackURL: media.videoURL ?? media.url)
        }
    }

    private func shareTweet(_ tweet: Tweet) {
        let items: [Any] = [URL(string: tweet.url) ?? Self.fixupxURL(tweet)]
        let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = cell(for: tweet) ?? view
        present(activity, animated: true)
    }

    private func saveMedia(tweetID: String, index: Int, isVideo: Bool, fallbackURL: String) {
        let url = AppEnvironment.shared.api.mediaURL(tweetID: tweetID, index: index)
        Task {
            do {
                try await MediaSaver.save(from: url, isVideo: isVideo)
                Haptics.success()
                self.toast("Saved to Photos")
            } catch {
                AppLogger.shared.warn("save media failed: \(error)", category: .media)
                self.present(AlertFactory.error(error, title: "Couldn't save"), animated: true)
            }
        }
    }

    private func presentReply(_ tweet: Tweet) {
        let compose = ComposeViewController(mode: .reply(to: tweet))
        present(UINavigationController(rootViewController: compose), animated: true)
    }

    private func toast(_ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        present(alert, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { alert.dismiss(animated: true) }
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

    /// Opens tapped media in a full-screen viewer — a zoomable photo gallery, or
    /// the native player for video/GIF — instead of navigating into the thread.
    private func openMedia(_ tweet: Tweet, at tappedIndex: Int) {
        if let video = tweet.media.enumerated().first(where: { $0.element.isVideo }) {
            let url = video.element.videoURL.flatMap(URL.init)
                ?? AppEnvironment.shared.api.mediaURL(tweetID: tweet.restID, index: video.offset)
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
        present(MediaViewerViewController(tweetID: tweet.restID, photoMediaIndices: photoIndices, startIndex: start), animated: true)
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
            footer.setHidden()
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
                if !refreshing { self?.collectionView.refreshControl?.endRefreshing() }
            }
            .store(in: &cancellables)

        viewModel.isLoading
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateChrome() }
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
    }

    private func reconfigure(_ ids: [String]) {
        var snapshot = dataSource.snapshot()
        let present = Set(snapshot.itemIdentifiers)
        let visible = ids.filter { present.contains($0) }
        guard !visible.isEmpty else { return }
        snapshot.reconfigureItems(visible)
        dataSource.apply(snapshot, animatingDifferences: true)
        updateUnreadCount()
    }

    private func apply(_ tweets: [Tweet]) {
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
        dataSource.apply(snapshot, animatingDifferences: !tweets.isEmpty)
        updateChrome()
        updateUnreadCount()
        if !isScrolling {
            DispatchQueue.main.async { [weak self] in self?.settleVideoPlayback() }
        }
    }

    // MARK: - Inline video playback (scroll-aware)

    private func pauseAllVideos() {
        for case let cell as TweetCell in collectionView.visibleCells { cell.pauseVideo() }
    }

    /// Plays only the on-screen video cell with the greatest overlap with the
    /// viewport and pauses the rest — the "one video at a time, only at rest"
    /// rule. Called when the feed settles; never while scrolling.
    func settleVideoPlayback() {
        isScrolling = false
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
            collectingLabel.isHidden = true
            return
        }
        if viewModel.awaitingQuery {
            loadingIndicator.stopAnimating()
            collectingLabel.isHidden = true
            emptyState.isHidden = false
            emptyState.show(symbol: "magnifyingglass", title: "Search X",
                            subtitle: "Find tweets, people, and topics.", showRetry: false)
        } else if viewModel.isLoading.value || !viewModel.hasLoadedOnce {
            emptyState.isHidden = true
            loadingIndicator.startAnimating()
            updateCollectingLabel()
        } else if let error = lastErrorText {
            loadingIndicator.stopAnimating()
            collectingLabel.isHidden = true
            emptyState.isHidden = false
            emptyState.show(symbol: "exclamationmark.triangle", title: "Couldn't load", subtitle: error, showRetry: true)
        } else {
            loadingIndicator.stopAnimating()
            collectingLabel.isHidden = true
            emptyState.isHidden = false
            emptyState.show(symbol: "tray", title: "Nothing here yet", subtitle: "Pull to refresh.", showRetry: true)
        }
    }

    /// While collect-then-show filtering is gathering a batch, replaces the bare
    /// spinner caption with "collecting tweets… N/25".
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
        }
    }

    @objc private func pullToRefresh() { viewModel.refresh() }

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
    /// the request, and only roll the cell back if the network rejects it.
    private func toggleLike(_ tweet: Tweet, cell: TweetCell?) {
        let target = !tweet.favorited
        let optimisticCount = max(0, tweet.likeCount + (target ? 1 : -1))
        cell?.applyLike(favorited: target, count: optimisticCount)
        Task {
            do {
                _ = target
                    ? try await AppEnvironment.shared.api.like(tweetID: tweet.restID)
                    : try await AppEnvironment.shared.api.unlike(tweetID: tweet.restID)
            } catch {
                cell?.applyLike(favorited: tweet.favorited, count: tweet.likeCount)
                Haptics.error()
                AppLogger.shared.warn("like failed: \(error)", category: .timeline)
            }
        }
    }

    // MARK: - Unread navigation

    private lazy var unreadButton = UIBarButtonItem(
        image: DesignSystem.icon("arrow.down.to.line.compact"),
        primaryAction: UIAction { [weak self] _ in self?.jumpToNextUnread() })

    /// Reflects the unread count on the jump-to-unread button: an `N↑` text
    /// badge when there are unread tweets (matching the TUI's header counter), a
    /// bare down-arrow icon otherwise.
    func updateUnreadCount() {
        guard viewModel.supportsSeenTracking else { return }
        let count = viewModel.unreadCount
        if count > 0 {
            unreadButton.image = nil
            unreadButton.title = "\(count) ↑"
        } else {
            unreadButton.title = nil
            unreadButton.image = DesignSystem.icon("arrow.down.to.line.compact")
        }
        unreadButton.accessibilityLabel = count > 0 ? "\(count) unread, jump to next" : "Jump to next unread"
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

    private func jumpToNextUnread() {
        let visible = collectionView.indexPathsForVisibleItems.map(\.item).max() ?? -1
        guard let next = viewModel.nextUnreadIndex(after: visible) else { return }
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
        if !decelerate { settleVideoPlayback() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settleVideoPlayback() }
    func scrollViewDidScrollToTop(_ scrollView: UIScrollView) { settleVideoPlayback() }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { settleVideoPlayback() }

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
        }
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths {
            guard let id = dataSource.itemIdentifier(for: indexPath), let tweet = tweetsByID[id] else { continue }
            if let url = Self.previewURL(for: tweet) { ImageLoader.cancel(url) }
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
