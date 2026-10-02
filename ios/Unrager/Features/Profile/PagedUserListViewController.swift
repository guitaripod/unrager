import Combine
import UIKit
import UnragerKit

/// The shared plumbing behind every paginated list of people (followers,
/// following, likers): an initial spinner, infinite scroll on the page cursor,
/// a footer that shows "Loading more…" or a retry when a later page fails, and
/// an empty or error state when the first page does. Subclasses supply the
/// fetch and the copy.
class PagedUserListViewController: UIViewController {
    struct Page {
        let users: [User]
        let cursor: String?
        /// Shown under the last row once the list has ended, for a list that
        /// isn't everyone (X only serves part of it).
        var endNote: String?
    }

    struct EmptyCopy {
        let symbol: String
        let title: String
        let subtitle: String
    }

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var rowsByID: [String: UserRow] = [:]
    private(set) var order: [String] = []
    private let emptyState = EmptyStateView()
    private let loadingIndicator = UIActivityIndicatorView(style: .medium)
    private var cursor: String?
    private var exhausted = false
    private var loading = false
    private var pagingFailed = false
    /// A pull-to-refresh failed while rows were showing: they stay, with
    /// "Couldn't refresh" under them.
    private var refreshFailed = false
    private var endNote: String?
    /// The request in flight, and a counter bumped whenever a newer one
    /// supersedes it, so a stale answer (an old query's people, a page from
    /// before a refresh) is dropped instead of shown.
    private var loadTask: Task<Void, Never>?
    private var generation = 0
    private var redrawObserver: AnyCancellable?
    private let footer = PagingFooter()

    private lazy var registration = UICollectionView.CellRegistration<UserRowCell, String> {
        [weak self] cell, _, id in
        guard let row = self?.rowsByID[id] else { return }
        cell.configure(with: row)
    }

    func fetchPage(cursor: String?) async throws -> Page {
        fatalError("PagedUserListViewController.fetchPage(cursor:) must be overridden")
    }

    var emptyCopy: EmptyCopy {
        EmptyCopy(symbol: "person.2", title: "Nothing here", subtitle: "There is nobody to show.")
    }

    var logCategory: LogCategory { .profile }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = DesignSystem.Color.background

        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: makeLayout())
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.delegate = self
        footer.attach(to: collectionView)
        footer.onRetry = { [weak self] in
            guard let self else { return }
            self.load(reset: self.refreshFailed)
        }
        view.addManaged(collectionView)
        collectionView.pinEdges(to: view)
        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(reload), for: .valueChanged)
        collectionView.refreshControl = refresh

        emptyState.isHidden = true
        emptyState.onRetry = { [weak self] in self?.reload() }
        view.addManaged(emptyState)
        emptyState.pinEdges(toSafeAreaOf: view)

        loadingIndicator.hidesWhenStopped = true
        view.addManaged(loadingIndicator)
        NSLayoutConstraint.activate([
            loadingIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        configureDataSource()
        redrawObserver = NotificationCenter.default.publisher(for: TwemojiCache.imagesDidLoad)
            .merge(with: NotificationCenter.default.publisher(for: AppSettings.displayDidChange))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.dataSource.reconfigureVisibleItems(of: self.collectionView)
            }
        load(reset: true)
    }

    private func makeLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { _, environment in
            var config = UICollectionLayoutListConfiguration(appearance: .plain)
            config.backgroundColor = .clear
            let section = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
            section.boundarySupplementaryItems = [PagingFooter.boundaryItem()]
            return section
        }
    }

    private func configureDataSource() {
        let registration = registration
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { cv, indexPath, id in
            cv.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
        footer.install(on: dataSource)
    }

    /// "Loading more…" while a later page is in flight, a retry when it failed,
    /// nothing otherwise.
    private func updateFooter() {
        guard !order.isEmpty else { footer.set(.hidden); return }
        if refreshFailed {
            footer.set(.failed("Couldn't refresh"))
        } else if pagingFailed {
            footer.set(.failed("Couldn't load more"))
        } else if loading {
            footer.set(.loading("Loading more…"))
        } else if exhausted, let endNote {
            footer.set(.note(endNote))
        } else {
            footer.set(.hidden)
        }
    }

    /// Pull-to-refresh: a page still loading gives way to the fresh first
    /// page.
    @objc private func reload() {
        supersedeInFlightLoad()
        load(reset: true)
    }

    /// Starts again from the first page — for a screen whose query changed.
    /// Whatever the old query still had in flight is dropped.
    func restart() {
        supersedeInFlightLoad()
        cursor = nil
        exhausted = false
        endNote = nil
        order.removeAll()
        rowsByID.removeAll()
        pagingFailed = false
        refreshFailed = false
        dataSource.apply(NSDiffableDataSourceSnapshot<Int, String>(), animatingDifferences: false)
        load(reset: true)
    }

    private func supersedeInFlightLoad() {
        loadTask?.cancel()
        loadTask = nil
        generation += 1
        loading = false
    }

    /// Loads the first page (`reset`) or the next one. The cursor and the end
    /// of the list are only replaced once a first page has actually arrived,
    /// so a failed refresh leaves the rows and paging as they were.
    private func load(reset: Bool) {
        guard !loading, reset || !exhausted else { return }
        loading = true
        pagingFailed = false
        refreshFailed = false
        generation += 1
        let current = generation
        let requestCursor = reset ? nil : cursor
        if order.isEmpty { emptyState.isHidden = true; loadingIndicator.startAnimating() }
        updateFooter()
        loadTask = Task {
            defer {
                if current == generation {
                    loading = false
                    loadTask = nil
                    loadingIndicator.stopAnimating()
                    collectionView.refreshControl?.endRefreshing()
                    updateFooter()
                }
            }
            do {
                let page = try await fetchPage(cursor: requestCursor)
                guard current == generation else { return }
                if reset {
                    rowsByID.removeAll()
                    order.removeAll()
                    exhausted = false
                }
                for user in page.users where rowsByID[user.restID] == nil {
                    rowsByID[user.restID] = UserRow(user)
                    order.append(user.restID)
                }
                cursor = page.cursor
                endNote = page.endNote
                if page.cursor == nil || page.users.isEmpty { exhausted = true }
                apply()
            } catch {
                guard current == generation else { return }
                AppLogger.shared.warn("user list load failed: \(error)", category: logCategory)
                if order.isEmpty {
                    emptyState.isHidden = false
                    emptyState.show(symbol: "exclamationmark.triangle", title: "Couldn't load",
                                    subtitle: error.localizedDescription, showRetry: true)
                } else if reset {
                    refreshFailed = true
                } else {
                    pagingFailed = true
                }
            }
        }
    }

    private func apply() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(order, toSection: 0)
        dataSource.apply(snapshot, animatingDifferences: true)
        guard order.isEmpty else { emptyState.isHidden = true; return }
        let copy = emptyCopy
        emptyState.isHidden = false
        emptyState.show(symbol: copy.symbol, title: copy.title, subtitle: copy.subtitle, showRetry: true)
    }
}

#if DEBUG
extension PagedUserListViewController {
    /// Test hook: what a pull-to-refresh does.
    func restartFromPull() { reload() }

    /// Test hook: what scrolling to the end does.
    func loadNextPage() { load(reset: false) }
}
#endif

extension PagedUserListViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath), let row = rowsByID[id] else { return }
        navigationController?.pushViewController(ProfileViewController(handle: row.handle), animated: true)
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard !pagingFailed, indexPath.item >= order.count - 4 else { return }
        load(reset: false)
    }
}
