import Combine
import UIKit
import UnragerKit

/// What the rage filter hid from Home in this session, each with the rule that
/// hid it and a way to show it anyway. The filter drops posts before the feed
/// ever draws them, so without this a hidden post — wrongly hidden or not — was
/// simply gone.
final class HiddenPostsViewController: UIViewController {
    private let viewModel: TimelineViewModel
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var postsByID: [String: HiddenPost] = [:]
    private let emptyState = EmptyStateView()
    private var cancellable: AnyCancellable?
    private var emojiObserver: AnyCancellable?
    private var showing = Set<String>()

    init(viewModel: TimelineViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        title = "Hidden posts"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private lazy var registration = UICollectionView.CellRegistration<UICollectionViewListCell, String> {
        [weak self] cell, _, id in
        guard let self, let post = self.postsByID[id] else { return }
        var content = UIListContentConfiguration.subtitleCell()
        content.text = "Hidden: \(post.reason ?? "the filter")"
        content.textProperties.color = DesignSystem.Color.accent
        content.textProperties.font = DesignSystem.Typography.handle()
        content.secondaryAttributedText = TwemojiText.attributed(
            "@\(post.tweet.author.handle): \(Self.singleLine(post.tweet.text))",
            font: DesignSystem.Typography.body(), color: DesignSystem.Color.label)
        content.secondaryTextProperties.numberOfLines = 5
        cell.contentConfiguration = content
        cell.accessories = [.customView(configuration: .init(
            customView: self.showButton(for: post), placement: .trailing(), maintainsFixedSize: true))]
        cell.accessibilityLabel = "Hidden: \(post.reason ?? "the filter"). @\(post.tweet.author.handle): \(post.tweet.text)"
        cell.accessibilityHint = "Opens the post."
        cell.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Show this post") { [weak self] _ in
            self?.show(post)
            return true
        }]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = DesignSystem.Color.background
        navigationItem.largeTitleDisplayMode = .never

        var config = UICollectionLayoutListConfiguration(appearance: .plain)
        config.backgroundColor = .clear
        config.leadingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard let self, let id = self.dataSource.itemIdentifier(for: indexPath),
                  let post = self.postsByID[id] else { return nil }
            let action = UIContextualAction(style: .normal, title: "Open") { _, _, done in
                self.open(post)
                done(true)
            }
            action.image = DesignSystem.icon("text.bubble")
            action.backgroundColor = DesignSystem.Color.secondaryLabel
            return UISwipeActionsConfiguration(actions: [action])
        }
        config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard let self, let id = self.dataSource.itemIdentifier(for: indexPath),
                  let post = self.postsByID[id] else { return nil }
            let action = UIContextualAction(style: .normal, title: "Show") { _, _, done in
                self.show(post)
                done(true)
            }
            action.backgroundColor = DesignSystem.Color.accent
            return UISwipeActionsConfiguration(actions: [action])
        }
        collectionView = UICollectionView(frame: view.bounds,
                                          collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config))
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        view.addManaged(collectionView)
        collectionView.pinEdges(to: view)

        emptyState.isHidden = true
        view.addManaged(emptyState)
        emptyState.pinEdges(toSafeAreaOf: view)
        emptyState.show(symbol: "eye", title: "Nothing hidden",
                        subtitle: "Posts the filter hides from Home show up here.", showRetry: false)

        let reg = registration
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { cv, ip, id in
            cv.dequeueConfiguredReusableCell(using: reg, for: ip, item: id)
        }
        cancellable = viewModel.hiddenPosts
            .receive(on: DispatchQueue.main)
            .sink { [weak self] posts in self?.apply(posts) }
        emojiObserver = NotificationCenter.default.publisher(for: TwemojiCache.imagesDidLoad)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.dataSource.reconfigureVisibleItems(of: self.collectionView)
            }
    }

    private func apply(_ posts: [HiddenPost]) {
        let newest = Array(posts.reversed())
        postsByID = Dictionary(newest.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(newest.map(\.id))
        dataSource.apply(snapshot, animatingDifferences: true)
        emptyState.isHidden = !newest.isEmpty
    }

    /// The post's text with its line breaks folded into spaces, so a preview
    /// spends its lines on words rather than blank gaps.
    private static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    private func showButton(for post: HiddenPost) -> UIButton {
        var config = UIButton.Configuration.tinted()
        config.title = "Show"
        config.cornerStyle = .capsule
        let button = UIButton(configuration: config)
        button.addAction(UIAction { [weak self] _ in self?.show(post) }, for: .touchUpInside)
        button.accessibilityLabel = "Show this post"
        button.frame = CGRect(origin: .zero, size: button.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize))
        return button
    }

    /// Opens the whole post, so one cut off at five lines, or hidden for its
    /// photo or quote, can be read before deciding to show it.
    private func open(_ post: HiddenPost) {
        navigationController?.pushViewController(ThreadViewController(tweetID: post.id), animated: true)
    }

    private func show(_ post: HiddenPost) {
        guard showing.insert(post.id).inserted else { return }
        Haptics.selection()
        Task {
            defer { showing.remove(post.id) }
            do {
                try await viewModel.showHidden(post)
                Haptics.success()
            } catch {
                AppLogger.shared.warn("show hidden post failed: \(error)", category: .timeline)
                present(AlertFactory.error(error, title: "Couldn't show the post"), animated: true)
            }
        }
    }
}

extension HiddenPostsViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath), let post = postsByID[id] else { return }
        open(post)
    }
}
