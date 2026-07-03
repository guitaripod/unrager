import UIKit
import UnragerKit

/// A paginated followers / following list for a user: avatar, name, handle and
/// a verified badge per row, infinite-scrolled via the user-list cursor.
/// Tapping a row opens that user's profile. Mirrors `LikersViewController`.
final class UserListViewController: UIViewController {
    enum Mode {
        case followers
        case following

        var title: String {
            switch self {
            case .followers: return "Followers"
            case .following: return "Following"
            }
        }

        var emptySymbol: String {
            switch self {
            case .followers: return "person.2"
            case .following: return "person.badge.plus"
            }
        }

        var emptyText: String {
            switch self {
            case .followers: return "No followers to show — X only shares part of this list."
            case .following: return "This account doesn't follow anyone X will show."
            }
        }
    }

    private let userID: String
    private let mode: Mode
    private let social = SocialAPI(baseURL: { AppSettings.serverURL })
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var usersByID: [String: User] = [:]
    private var order: [String] = []
    private let emptyState = EmptyStateView()
    private var cursor: String?
    private var exhausted = false
    private var loading = false

    init(user: User, mode: Mode) {
        self.userID = user.restID
        self.mode = mode
        super.init(nibName: nil, bundle: nil)
        title = mode.title
    }

    /// Opens by id/handle only (debug router); the server resolves either.
    init(userID: String, mode: Mode) {
        self.userID = userID
        self.mode = mode
        super.init(nibName: nil, bundle: nil)
        title = mode.title
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
                let page = mode == .followers
                    ? try await social.followers(userID: userID, cursor: reset ? nil : cursor)
                    : try await social.following(userID: userID, cursor: reset ? nil : cursor)
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
                AppLogger.shared.warn("\(mode.title) load failed: \(error)", category: .profile)
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
            emptyState.show(symbol: mode.emptySymbol, title: "Nothing here",
                            subtitle: mode.emptyText, showRetry: true)
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

extension UserListViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath), let user = usersByID[id] else { return }
        navigationController?.pushViewController(ProfileViewController(handle: user.handle), animated: true)
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        if indexPath.item >= order.count - 4 { load(reset: false) }
    }
}
