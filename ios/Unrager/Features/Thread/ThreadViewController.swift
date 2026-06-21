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
    private var focalID: String?
    private var selfHandle: String?
    private var cursor: String?
    private var exhausted = false
    private var loadingMore = false
    private var didRenderFocal = false
    private let emptyState = EmptyStateView()
    private let loadingIndicator = UIActivityIndicatorView(style: .medium)

    private enum Section { case ancestors, focal, replies }

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
        cell.onTapAuthor = { [weak self] in self?.push(ProfileViewController(handle: tweet.author.handle)) }
        cell.onLike = { [weak self] in self?.toggleLike(tweet, cell: cell) }
        cell.onReply = { [weak self] in self?.reply(to: tweet) }
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
    }

    /// Opens from a `Tweet` already in hand (the feed) so the focal tweet renders
    /// instantly while ancestors and replies stream in.
    convenience init(tweet: Tweet) {
        self.init(tweetID: tweet.restID)
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

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: DesignSystem.icon("arrowshape.turn.up.left"),
            primaryAction: UIAction { [weak self] _ in self?.replyToFocal() })

        let reg = registration
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { cv, ip, id in
            cv.dequeueConfiguredReusableCell(using: reg, for: ip, item: id)
        }
        renderFocalIfAvailable()
        resolveSelfHandle()
        load()
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
                loadingIndicator.stopAnimating()
                focalID = thread.focal.restID
                replyOrder = []
                for tweet in thread.ancestors + [thread.focal] {
                    tweetsByID[tweet.restID] = tweet
                }
                for reply in thread.replies where !replyOrder.contains(reply.restID) {
                    tweetsByID[reply.restID] = reply
                    replyOrder.append(reply.restID)
                }
                cursor = thread.cursor
                exhausted = thread.cursor == nil
                applyThread(ancestors: thread.ancestors.map(\.restID), focal: thread.focal.restID)
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
        snapshot.appendItems(replyOrder, toSection: .replies)
        let shouldPinFocal = didRenderFocal && !ancestors.isEmpty
        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            guard let self, shouldPinFocal, let anchorBefore else { return }
            self.pinFocal(toScreenY: anchorBefore)
        }
        didRenderFocal = true
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
                for reply in page.replies where !replyOrder.contains(reply.restID) {
                    tweetsByID[reply.restID] = reply
                    replyOrder.append(reply.restID)
                    added = true
                }
                self.cursor = page.cursor
                if page.cursor == nil || !added { exhausted = true }
                var snapshot = dataSource.snapshot()
                snapshot.deleteSections([.replies])
                snapshot.appendSections([.replies])
                snapshot.appendItems(replyOrder, toSection: .replies)
                await dataSource.apply(snapshot, animatingDifferences: true)
            } catch {
                AppLogger.shared.warn("thread loadMore failed: \(error)", category: .thread)
            }
        }
    }

    private func replyToFocal() {
        guard let focalID, let focal = tweetsByID[focalID] else { return }
        reply(to: focal)
    }

    private func reply(to tweet: Tweet) {
        let compose = ComposeViewController(mode: .reply(to: tweet))
        present(UINavigationController(rootViewController: compose), animated: true)
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

    private func toggleLike(_ tweet: Tweet, cell: TweetCell) {
        let target = !tweet.favorited
        cell.applyLike(favorited: target, count: max(0, tweet.likeCount + (target ? 1 : -1)))
        Task {
            do {
                _ = target
                    ? try await AppEnvironment.shared.api.like(tweetID: tweet.restID)
                    : try await AppEnvironment.shared.api.unlike(tweetID: tweet.restID)
            } catch {
                cell.applyLike(favorited: tweet.favorited, count: tweet.likeCount)
                Haptics.error()
            }
        }
    }

    private func push(_ vc: UIViewController) {
        navigationController?.pushViewController(vc, animated: true)
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
        guard let id = dataSource.itemIdentifier(for: indexPath), replyOrder.suffix(4).contains(id) else { return }
        loadMore()
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard let id = dataSource.itemIdentifier(for: indexPath), let tweet = tweetsByID[id] else { return nil }
        return UIContextMenuConfiguration(identifier: id as NSString, previewProvider: nil) { _ in
            UIMenu(children: [
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
