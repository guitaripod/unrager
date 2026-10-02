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
        content.secondaryText = "@\(post.tweet.author.handle): \(post.tweet.text)"
        content.secondaryTextProperties.numberOfLines = 5
        content.secondaryTextProperties.color = DesignSystem.Color.label
        content.secondaryTextProperties.font = DesignSystem.Typography.body()
        cell.contentConfiguration = content
        cell.accessories = [.customView(configuration: .init(
            customView: self.showButton(for: post), placement: .trailing(), maintainsFixedSize: true))]
        cell.accessibilityLabel = "Hidden: \(post.reason ?? "the filter"). @\(post.tweet.author.handle): \(post.tweet.text)"
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

    private func showButton(for post: HiddenPost) -> UIButton {
        var config = UIButton.Configuration.tinted()
        config.title = "Show"
        config.cornerStyle = .capsule
        let button = UIButton(configuration: config)
        button.addAction(UIAction { [weak self] _ in self?.show(post) }, for: .touchUpInside)
        button.accessibilityLabel = "Show this post"
        return button
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
