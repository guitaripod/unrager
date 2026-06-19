import UIKit
import UnragerKit

/// A paginated "Liked by" list for a tweet: avatar, name, handle and a verified
/// badge per row, infinite-scrolled via the likers cursor. Tapping a row opens
/// that user's profile.
final class LikersViewController: UIViewController {
    private let tweetID: String
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var usersByID: [String: User] = [:]
    private var order: [String] = []
    private let emptyState = EmptyStateView()
    private var cursor: String?
    private var exhausted = false
    private var loading = false

    init(tweetID: String) {
        self.tweetID = tweetID
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private lazy var registration = UICollectionView.CellRegistration<UICollectionViewListCell, String> {
        [weak self] cell, _, id in
        guard let user = self?.usersByID[id] else { return }
        var content = UIListContentConfiguration.subtitleCell()
        content.text = user.name
        content.secondaryText = "@\(user.handle)"
        content.secondaryTextProperties.color = DesignSystem.Color.secondaryLabel
        content.image = DesignSystem.icon("person.crop.circle.fill", pointSize: 36)
        content.imageProperties.tintColor = DesignSystem.Color.tertiaryLabel
        content.imageProperties.maximumSize = CGSize(width: 40, height: 40)
        content.imageProperties.cornerRadius = 20
        cell.contentConfiguration = content
        cell.accessibilityLabel = "\(user.name), @\(user.handle)\(user.verified ? ", verified" : "")"

        if user.verified {
            let badge = UIImageView(image: DesignSystem.icon("checkmark.seal.fill", pointSize: 16))
            badge.tintColor = DesignSystem.Color.verified
            cell.accessories = [.customView(configuration: .init(customView: badge, placement: .trailing()))]
        } else {
            cell.accessories = [.disclosureIndicator()]
        }

        if AppSettings.imagesEnabled, let url = user.avatarURL.flatMap(URL.init) {
            self?.loadAvatar(url, into: cell, id: id)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Liked by"
        view.backgroundColor = DesignSystem.Color.background

        var config = UICollectionLayoutListConfiguration(appearance: .plain)
        config.backgroundColor = .clear
        collectionView = UICollectionView(frame: view.bounds,
                                          collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config))
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        view.addManaged(collectionView)
        collectionView.pinEdges(to: view)
        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(reload), for: .valueChanged)
        collectionView.refreshControl = refresh

        emptyState.isHidden = true
        emptyState.onRetry = { [weak self] in self?.reload() }
        view.addManaged(emptyState)
        emptyState.pinEdges(toSafeAreaOf: view)

        let reg = registration
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { cv, ip, id in
            cv.dequeueConfiguredReusableCell(using: reg, for: ip, item: id)
        }
        load(reset: true)
    }

    @objc private func reload() { load(reset: true) }

    private func load(reset: Bool) {
        guard !loading, reset || !exhausted else { return }
        loading = true
        if reset { exhausted = false; cursor = nil }
        Task {
            defer { loading = false; collectionView.refreshControl?.endRefreshing() }
            do {
                let page = try await AppEnvironment.shared.api.likers(tweetID: tweetID, cursor: reset ? nil : cursor)
                if reset { usersByID.removeAll(); order.removeAll() }
                for user in page.users where usersByID[user.restID] == nil {
                    usersByID[user.restID] = user
                    order.append(user.restID)
                }
                cursor = page.cursor
                if page.cursor == nil || page.users.isEmpty { exhausted = true }
                apply()
            } catch {
                if order.isEmpty {
                    emptyState.isHidden = false
                    emptyState.show(symbol: "exclamationmark.triangle", title: "Couldn't load",
                                    subtitle: error.localizedDescription, showRetry: true)
                }
                AppLogger.shared.warn("likers load failed: \(error)", category: .timeline)
            }
        }
    }

    private func apply() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(order, toSection: 0)
        dataSource.apply(snapshot, animatingDifferences: true)
        if order.isEmpty {
            emptyState.isHidden = false
            emptyState.show(symbol: "heart", title: "No likes yet",
                            subtitle: "Nobody has liked this tweet, or X isn't sharing the list.", showRetry: true)
        } else {
            emptyState.isHidden = true
        }
    }

    private func loadAvatar(_ url: URL, into cell: UICollectionViewListCell, id: String) {
        Task { [weak self, weak cell] in
            let image = await ImageLoader.image(for: url, pointSize: CGSize(width: 40, height: 40), scale: 3)
            guard let self, let cell, let image,
                  var content = cell.contentConfiguration as? UIListContentConfiguration,
                  self.usersByID[id] != nil else { return }
            content.image = image
            cell.contentConfiguration = content
        }
    }
}

extension LikersViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath), let user = usersByID[id] else { return }
        navigationController?.pushViewController(ProfileViewController(handle: user.handle), animated: true)
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        if indexPath.item >= order.count - 4 { load(reset: false) }
    }
}
