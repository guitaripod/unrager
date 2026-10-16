import Combine
import UIKit
import UnragerKit

/// The shared plumbing behind every paginated list of people (followers,
/// following, likers): placeholder rows before the first page, infinite scroll
/// on the page cursor, a Follow button on each row the list can say it for, an
/// optional heading above the people, optional lens chips pinned over them that
/// narrow what is loaded, a footer that shows "Loading more…" or a retry when a
/// later page fails, and an empty or error state when the first page does.
/// Subclasses supply the fetch and the copy.
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

    private enum ListSection: Hashable, Sendable {
        case header
        case people
    }

    private static let headerID = "list-header"
    private static let sparseRows = 12
    private static let maxAutoPages = 8

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<ListSection, String>!
    private var rowsByID: [String: UserRow] = [:]
    private(set) var order: [String] = []
    private let emptyState = EmptyStateView()
    private let skeleton = UserListSkeletonView()
    private let social = SocialAPI(baseURL: { AppSettings.serverURL })
    private var followsInFlight = Set<String>()
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
    private var contentSizeObserver: NSKeyValueObservation?
    private let footer = PagingFooter()

    /// The lens the reader chose, nil until they choose one, and the people it
    /// let in. A person stays in the lens they were let into when their follow
    /// state changes, so Follow back doesn't make the row vanish under the
    /// finger; the next lens, refresh or page recomputes.
    private(set) var lens: String?
    private var lensMembers = Set<String>()
    private var lensChipsShown: [LensChip] = []
    private var lensAutoPages = 0

    private lazy var registration = UICollectionView.CellRegistration<UserRowCell, String> {
        [weak self] cell, _, id in
        guard let self, let row = self.rowsByID[id] else { return }
        cell.configure(with: row, detailed: self.showsDetail)
        cell.onToggleFollow = { [weak self] in self?.toggleFollow(id) }
    }

    private lazy var lensRegistration = UICollectionView.SupplementaryRegistration<LensBarView>(
        elementKind: LensBarView.kind) { [weak self] bar, _, _ in
        self?.configureLensBar(bar)
    }

    // MARK: - For subclasses

    func fetchPage(cursor: String?) async throws -> Page {
        fatalError("PagedUserListViewController.fetchPage(cursor:) must be overridden")
    }

    var emptyCopy: EmptyCopy {
        EmptyCopy(symbol: "person.2", title: "Nothing here", subtitle: "There is nobody to show.")
    }

    var logCategory: LogCategory { .profile }

    /// Whether the list opens with a heading section above the people (the post
    /// the likes are on). Read once, when the view loads.
    var hasHeader: Bool { false }

    /// The heading's cell, dequeued from the subclass's own registration. Asked
    /// for whenever the heading is drawn or `reloadHeader()` is called.
    func headerCell(in collectionView: UICollectionView, at indexPath: IndexPath) -> UICollectionViewCell {
        fatalError("PagedUserListViewController.headerCell(in:at:) must be overridden with hasHeader")
    }

    /// Whether rows show where each person stands with the viewer and how big
    /// their account is, not only who they are.
    var showsDetail: Bool { false }

    /// Whether lens chips are pinned over the people. Read once, when the view
    /// loads.
    var supportsLens: Bool { false }

    /// The chips for the loaded people, the unfiltered list first. Empty hides
    /// the bar. Asked after `peopleDidChange()`.
    var lensChips: [LensChip] { [] }

    func includes(_ row: UserRow, lens: String) -> Bool { true }

    /// What to say under the list when a lens leaves nobody in it.
    func emptyLensNote(_ lens: String) -> String { "Nobody to show." }

    /// The loaded people or their follow state changed: update whatever the
    /// heading and the chips are drawn from, then `reloadHeader()` if it moved.
    func peopleDidChange() {}

    /// Every loaded person, in the order X listed them.
    var loadedRows: [UserRow] { order.compactMap { rowsByID[$0] } }

    /// Whether the first page is still on its way.
    var isLoadingFirstPage: Bool { loading && order.isEmpty }

    /// Draws the heading again from the subclass's model.
    func reloadHeader() {
        guard hasHeader, isViewLoaded, dataSource != nil else { return }
        var snapshot = dataSource.snapshot()
        guard snapshot.indexOfItem(Self.headerID) != nil else { return }
        snapshot.reconfigureItems([Self.headerID])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// Narrows the list to the people `id` lets in; the first chip shows all.
    func selectLens(_ id: String) {
        guard id != (lens ?? lensChipsShown.first?.id) else { return }
        lens = id
        lensAutoPages = 0
        lensMembers = Set(order.filter { rowsByID[$0].map { includes($0, lens: id) } ?? false })
        applySnapshot(animated: true)
        refreshPeople()
        updateFooter()
        scrollPeopleIntoView()
        loadMoreIfSparse()
    }

    // MARK: - Lifecycle

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
            self.lensAutoPages = 0
            self.load(reset: self.refreshFailed)
        }
        view.addManaged(collectionView)
        collectionView.pinEdges(to: view)
        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(reload), for: .valueChanged)
        collectionView.refreshControl = refresh

        emptyState.isHidden = true
        emptyState.onRetry = { [weak self] in self?.reload() }
        collectionView.addSubview(emptyState)

        skeleton.isHidden = true
        collectionView.addSubview(skeleton)

        configureDataSource()
        applySnapshot(animated: false)
        contentSizeObserver = collectionView.observe(\.contentSize) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.positionBelowHeader() }
        }
        redrawObserver = NotificationCenter.default.publisher(for: TwemojiCache.imagesDidLoad)
            .merge(with: NotificationCenter.default.publisher(for: AppSettings.displayDidChange))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.dataSource.reconfigureVisibleItems(of: self.collectionView)
            }
        load(reset: true)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        positionBelowHeader()
    }

    private func makeLayout() -> UICollectionViewCompositionalLayout {
        let hasHeader = hasHeader
        let supportsLens = supportsLens
        return UICollectionViewCompositionalLayout { sectionIndex, environment in
            let isHeader = hasHeader && sectionIndex == 0
            var config = UICollectionLayoutListConfiguration(appearance: .plain)
            config.backgroundColor = .clear
            config.itemSeparatorHandler = { _, configuration in
                var configuration = configuration
                if isHeader {
                    configuration.topSeparatorVisibility = .hidden
                    configuration.bottomSeparatorVisibility = .hidden
                }
                return configuration
            }
            let section = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
            if !isHeader {
                var edges: [NSCollectionLayoutBoundarySupplementaryItem] = []
                if supportsLens { edges.append(LensBarView.boundaryItem()) }
                edges.append(PagingFooter.boundaryItem())
                section.boundarySupplementaryItems = edges
            }
            return section
        }
    }

    private func configureDataSource() {
        let registration = registration
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { [weak self] cv, indexPath, id in
            if id == Self.headerID, let self {
                return self.headerCell(in: cv, at: indexPath)
            }
            return cv.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
        footer.install(on: dataSource)
        let footerProvider = dataSource.supplementaryViewProvider
        let lensRegistration = lensRegistration
        dataSource.supplementaryViewProvider = { cv, kind, indexPath in
            kind == LensBarView.kind
                ? cv.dequeueConfiguredReusableSupplementary(using: lensRegistration, for: indexPath)
                : footerProvider?(cv, kind, indexPath)
        }
    }

    // MARK: - Placeholder and empty state

    /// Shows the placeholder rows where the people will land, under the heading
    /// when there is one.
    private func showSkeleton() {
        guard skeleton.isHidden else { return }
        positionBelowHeader()
        skeleton.alpha = 0
        skeleton.isHidden = false
        UIView.animate(withDuration: 0.25) { self.skeleton.alpha = 1 }
    }

    private func hideSkeleton() {
        guard !skeleton.isHidden else { return }
        skeleton.layer.removeAllAnimations()
        skeleton.isHidden = true
    }

    /// Lays the skeleton and the empty state out in the space under the
    /// heading, so a heading that grows with its post never sits under them.
    private func positionBelowHeader() {
        guard isViewLoaded, collectionView != nil else { return }
        let width = collectionView.bounds.width
        guard width > 0 else { return }
        let top = hasHeader ? collectionView.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame.maxY ?? 0 : 0
        let frame = CGRect(x: 0, y: top, width: width, height: skeleton.fittingHeight(width: width))
        if skeleton.frame != frame { skeleton.frame = frame }
        let inset = collectionView.adjustedContentInset
        let room = collectionView.bounds.height - inset.top - inset.bottom - top
        let emptyFrame = CGRect(x: 0, y: top, width: width, height: max(room, 280))
        if emptyState.frame != emptyFrame { emptyState.frame = emptyFrame }
    }

    // MARK: - Following

    /// Follows or unfollows `id` from its row. Unfollowing asks first.
    private func toggleFollow(_ id: String) {
        guard let row = rowsByID[id], let following = row.following, !followsInFlight.contains(id) else { return }
        guard following else { return setFollowing(true, for: row) }
        let alert = UIAlertController(title: "Unfollow @\(row.handle)?", message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Unfollow", style: .destructive) { [weak self] _ in
            self?.setFollowing(false, for: row)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    /// Changes the row at once and tells the server; a refusal puts it back.
    private func setFollowing(_ following: Bool, for row: UserRow) {
        let id = row.id
        followsInFlight.insert(id)
        setRowFollowing(following, id: id)
        Haptics.selection()
        Task {
            defer { followsInFlight.remove(id) }
            do {
                let result = following ? try await social.follow(userID: id) : try await social.unfollow(userID: id)
                setRowFollowing(result.following, id: id)
            } catch {
                AppLogger.shared.warn("follow change failed: \(error)", category: logCategory)
                Haptics.error()
                setRowFollowing(!following, id: id)
            }
        }
    }

    private func setRowFollowing(_ following: Bool, id: String) {
        guard var row = rowsByID[id], row.following != following else { return }
        row.following = following
        rowsByID[id] = row
        var snapshot = dataSource.snapshot()
        guard snapshot.indexOfItem(id) != nil else { return }
        snapshot.reconfigureItems([id])
        dataSource.apply(snapshot, animatingDifferences: false)
        refreshPeople()
    }

    // MARK: - Footer

    /// "Loading more…" while a later page is in flight, a retry when it failed,
    /// what a lens found when it found nothing, nothing otherwise.
    private func updateFooter() {
        guard !order.isEmpty else { footer.set(.hidden); return }
        if refreshFailed {
            footer.set(.failed("Couldn't refresh"))
        } else if pagingFailed {
            footer.set(.failed("Couldn't load more"))
        } else if loading {
            footer.set(.loading("Loading more…"))
        } else if let lens, narrowed, visibleIDs.isEmpty {
            footer.set(exhausted
                ? .note(emptyLensNote(lens))
                : .failed("Nobody yet among the \(order.count.formatted()) loaded"))
        } else if exhausted, let endNote {
            footer.set(.note(endNote))
        } else {
            footer.set(.hidden)
        }
    }

    // MARK: - Loading

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
        lens = nil
        lensMembers.removeAll()
        pagingFailed = false
        refreshFailed = false
        applySnapshot(animated: false)
        refreshPeople()
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
        if order.isEmpty { emptyState.isHidden = true; showSkeleton() }
        updateFooter()
        refreshPeople()
        loadTask = Task {
            defer {
                if current == generation {
                    loading = false
                    loadTask = nil
                    hideSkeleton()
                    collectionView.refreshControl?.endRefreshing()
                    updateFooter()
                    refreshPeople()
                }
            }
            do {
                let page = try await fetchPage(cursor: requestCursor)
                guard current == generation else { return }
                if reset {
                    rowsByID.removeAll()
                    order.removeAll()
                    lensMembers.removeAll()
                    exhausted = false
                }
                for user in page.users where rowsByID[user.restID] == nil {
                    let row = UserRow(user)
                    rowsByID[user.restID] = row
                    order.append(user.restID)
                    if let lens, includes(row, lens: lens) { lensMembers.insert(user.restID) }
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

    // MARK: - Lens

    /// Whether a lens other than "all" is narrowing the list.
    private var narrowed: Bool {
        guard let lens else { return false }
        return lens != lensChipsShown.first?.id
    }

    /// The people on screen: everyone, or those the lens let in.
    private var visibleIDs: [String] {
        narrowed ? order.filter(lensMembers.contains) : order
    }

    /// Updates the heading and the chips from the loaded people.
    private func refreshPeople() {
        peopleDidChange()
        lensChipsShown = supportsLens ? lensChips : []
        refreshLensBar()
    }

    private func configureLensBar(_ bar: LensBarView) {
        bar.onSelect = { [weak self] in self?.selectLens($0) }
        bar.configure(chips: lensChipsShown, selected: lens ?? lensChipsShown.first?.id ?? "")
    }

    private var lensBarWasShown = false

    private func refreshLensBar() {
        guard isViewLoaded, collectionView != nil else { return }
        for indexPath in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: LensBarView.kind) {
            if let bar = collectionView.supplementaryView(forElementKind: LensBarView.kind, at: indexPath) as? LensBarView {
                configureLensBar(bar)
            }
        }
        let shown = !lensChipsShown.isEmpty
        guard shown != lensBarWasShown else { return }
        lensBarWasShown = shown
        DispatchQueue.main.async { [weak self] in
            guard let list = self?.collectionView, list.window != nil else { return }
            list.performBatchUpdates(nil)
        }
    }

    /// When the reader is below the start of the people, brings the first of
    /// them back under the pinned chips, so a lens that narrows the list is
    /// read from its top.
    private func scrollPeopleIntoView() {
        guard let first = visibleIDs.first, let indexPath = dataSource.indexPath(for: first),
              let attributes = collectionView.layoutAttributesForItem(at: indexPath) else { return }
        let bar = lensChipsShown.isEmpty ? 0 : LensBarView.height
        let top = attributes.frame.minY - bar - collectionView.adjustedContentInset.top
        guard collectionView.contentOffset.y > top else { return }
        collectionView.setContentOffset(CGPoint(x: 0, y: top), animated: false)
    }

    /// A lens that leaves few people keeps fetching pages until it fills the
    /// screen, the list ends, or a handful of pages have gone by, after which
    /// the footer offers to carry on.
    private func loadMoreIfSparse() {
        guard narrowed, !exhausted, !loading, !pagingFailed,
              visibleIDs.count < Self.sparseRows, lensAutoPages < Self.maxAutoPages else { return }
        lensAutoPages += 1
        load(reset: false)
    }

    // MARK: - Snapshot

    private func applySnapshot(animated: Bool) {
        var snapshot = NSDiffableDataSourceSnapshot<ListSection, String>()
        if hasHeader {
            snapshot.appendSections([.header])
            snapshot.appendItems([Self.headerID], toSection: .header)
        }
        snapshot.appendSections([.people])
        snapshot.appendItems(visibleIDs, toSection: .people)
        dataSource.apply(snapshot, animatingDifferences: animated)
    }

    private func apply() {
        refreshPeople()
        applySnapshot(animated: true)
        updateFooter()
        loadMoreIfSparse()
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

    /// Test hook: the people the list shows, after any lens.
    var shownIDs: [String] { visibleIDs }

    /// Screenshot hook: scrolls by `points`.
    func debugScroll(by points: CGFloat) {
        collectionView.setContentOffset(CGPoint(x: 0, y: collectionView.contentOffset.y + points), animated: false)
    }
}
#endif

extension PagedUserListViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        dataSource.itemIdentifier(for: indexPath) != Self.headerID
    }

    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        dataSource.itemIdentifier(for: indexPath) != Self.headerID
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath), let row = rowsByID[id] else { return }
        navigationController?.pushViewController(ProfileViewController(handle: row.handle), animated: true)
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard !pagingFailed, dataSource.sectionIdentifier(for: indexPath.section) == .people,
              indexPath.item >= dataSource.snapshot().numberOfItems(inSection: .people) - 4 else { return }
        load(reset: false)
    }
}
