import UIKit
import UnragerKit

/// Notifications. Activity grouped under New and then by day, with a digest of
/// what the unread part added up to; filter chips for All, Mentions (the
/// full-post mentions feed), Likes, Reposts and Follows; faces that open the
/// people behind a group; Follow back on a new follower; and live arrivals that
/// glow in, or wait behind a "new" pill when the reader has scrolled away.
/// Tapping a row opens its post, the person, or the list of people.
final class NotificationsViewController: UIViewController {
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<NotificationSection, String>!
    private var items: [String: XNotification] = [:]
    private var order: [String] = []
    private let emptyState = EmptyStateView()
    private let skeleton = NotificationSkeletonView()
    private let chipBar: NotificationChipBar
    private let newPill = UIButton(configuration: .prominentGlass())
    private let followLoader = FollowStateLoader()
    private var cursor: String?
    private var exhausted = false
    private var loading = false
    /// True while a reset load's fetch is in flight. The 15s poller can
    /// `mergeFresh` during that window; a completing reset must not wipe those
    /// live-merged items when it rebuilds the list from its (older) page.
    private var resetLoadInFlight = false
    /// Items the poller live-merged while a reset load was in flight, buffered
    /// so the completing reset can re-insert them instead of dropping them.
    private var mergedDuringResetLoad: [XNotification] = []
    /// Rows newer than this render as unread. Captured from the seen marker at
    /// each reset load, *before* the load advances it — so the unread block
    /// survives the visit and clears on the next one, like X.
    private var unreadCutoff: Date?
    /// Rows the user opened since the last reset load: they drop their unread
    /// mark without leaving the New section.
    private var locallyRead = Set<String>()
    /// Rows that just arrived and should glow once when they are drawn.
    private var glowIDs = Set<String>()
    /// Arrivals held back from the seen marker because the chosen chip hides
    /// them; they count as shown once a chip that includes them is chosen.
    private var hiddenFresh: [XNotification] = []
    private var digests: [NotificationSection: String] = [:]
    /// When the list last finished a reset load, so coming back to the tab only
    /// reloads a list that has gone stale.
    private var lastLoaded: Date?
    private static let staleAfter: TimeInterval = 120
    private static let fewRows = 10
    private let footer = PagingFooter()
    private var displayObservers: [NSObjectProtocol] = []
    private var clock: Timer?
    private var placedInitialOffset = false
    private var lastHadUnread: Bool?
    private var loadFailure: LoadFailure?

    private enum LoadFailure { case refresh, more }

    private var pendingNew = 0 {
        didSet { updateNewPill() }
    }

    // MARK: - Chip choice

    private static let filterKey = "unrager.ios.notificationsFilter"

    /// The chip showing. Only All and Mentions are remembered: the narrower
    /// chips are lenses on the loaded list, and opening the tab on one would
    /// leave the activity it hides unseen.
    private var category: NotificationCategory

    private static func rememberedCategory() -> NotificationCategory {
        let raw = UserDefaults.standard.string(forKey: filterKey)
        return raw == NotificationCategory.mentions.rawValue ? .mentions : .all
    }

    /// The full-tweet mentions timeline embedded when the Mentions chip is
    /// chosen — the same source as the standalone Mentions tab.
    private var mentionsController: FeedViewController?

    init() {
        let remembered = Self.rememberedCategory()
        category = remembered
        chipBar = NotificationChipBar(selected: remembered)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setCategory(_ newCategory: NotificationCategory) {
        guard newCategory != category else { return }
        category = newCategory
        if newCategory == .all || newCategory == .mentions {
            UserDefaults.standard.set(newCategory.rawValue, forKey: Self.filterKey)
        }
        chipBar.select(newCategory)
        applyCategory()
    }

    /// Shows the surface for the chosen chip: the embedded mentions feed
    /// (created on first use), or the list narrowed to the chip.
    private func applyCategory() {
        let showMentions = category == .mentions
        if showMentions, mentionsController == nil {
            let feed = FeedViewController(viewModel: TimelineViewModel(source: .mentions))
            addChild(feed)
            view.insertSubview(feed.view, belowSubview: chipBar)
            feed.view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                feed.view.topAnchor.constraint(equalTo: chipBar.bottomAnchor),
                feed.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                feed.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                feed.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            feed.didMove(toParent: self)
            mentionsController = feed
        }
        mentionsController?.view.isHidden = !showMentions
        collectionView.isHidden = showMentions
        pendingNew = 0
        if showMentions {
            emptyState.isHidden = true
            skeleton.isHidden = true
            return
        }
        showHiddenFreshNowVisible()
        scrollToTop(animated: false)
        UIView.transition(with: collectionView, duration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.2,
                          options: [.transitionCrossDissolve, .allowUserInteraction]) {
            self.applySnapshot(animated: false)
        }
        if lastLoaded == nil, !loading { load(reset: true) }
        loadMoreIfSparse()
    }

    /// Reports to the seen marker the arrivals a chip was hiding, now that the
    /// chosen one shows them.
    private func showHiddenFreshNowVisible() {
        guard !hiddenFresh.isEmpty else { return }
        let nowVisible = hiddenFresh.filter(category.includes)
        hiddenFresh.removeAll { category.includes($0) }
        if !nowVisible.isEmpty, view.window != nil {
            NotificationCenterService.shared.notificationsDisplayed(nowVisible)
        }
    }

    // MARK: - Rows

    private lazy var registration = UICollectionView.CellRegistration<NotificationCell, String> {
        [weak self] cell, _, id in
        guard let self, let notification = self.items[id] else { return }
        var follow: FollowStateLoader.State?
        if NotificationType(raw: notification.type) == .follow,
           NotificationPresentation.peopleCount(notification) == 1, let actor = notification.actors.first {
            self.followLoader.request(restID: actor.restID, handle: actor.handle)
            follow = self.followLoader.state(for: actor.restID)
        }
        cell.configure(notification: notification, unread: self.isUnread(notification),
                       glow: self.glowIDs.remove(id) != nil, follow: follow,
                       actions: self.rowActions(for: notification))
    }

    private lazy var headerRegistration = UICollectionView.SupplementaryRegistration<NotificationSectionHeaderView>(
        elementKind: UICollectionView.elementKindSectionHeader
    ) { [weak self] header, _, indexPath in
        self?.configure(header, at: indexPath)
    }

    private func configure(_ header: NotificationSectionHeaderView, at indexPath: IndexPath) {
        guard let section = dataSource.sectionIdentifier(for: indexPath.section) else { return }
        header.configure(title: section.title, digest: digests[section], offersMarkRead: section == .new)
        header.onAction = { [weak self] in self?.markAllRead() }
    }

    private func refreshHeaders() {
        for indexPath in collectionView.indexPathsForVisibleSupplementaryElements(
            ofKind: UICollectionView.elementKindSectionHeader) {
            guard let header = collectionView.supplementaryView(
                forElementKind: UICollectionView.elementKindSectionHeader, at: indexPath)
                as? NotificationSectionHeaderView else { continue }
            configure(header, at: indexPath)
        }
    }

    private func rowActions(for notification: XNotification) -> NotificationRowActions {
        NotificationRowActions(
            openProfile: { [weak self] handle in
                self?.navigationController?.pushViewController(ProfileViewController(handle: handle), animated: true)
            },
            openPeople: { [weak self] in self?.showPeople(of: notification) },
            followBack: { [weak self] in
                guard let actor = notification.actors.first else { return }
                self?.followLoader.follow(restID: actor.restID, handle: actor.handle)
            })
    }

    /// Whether the notification arrived since the user's last visit.
    private func isNew(_ notification: XNotification) -> Bool {
        guard let cutoff = unreadCutoff else { return false }
        return NotificationPrefs.isNewer(notification.timestamp, than: cutoff)
    }

    private func isUnread(_ notification: XNotification) -> Bool {
        isNew(notification) && !locallyRead.contains(notification.id)
    }

    private func showPeople(of notification: XNotification) {
        let verb = NotificationType(raw: notification.type).style.verb
        let list = NotificationActorsViewController(
            title: verb.prefix(1).uppercased() + verb.dropFirst(), actors: notification.actors,
            othersCount: notification.othersCount)
        navigationController?.pushViewController(list, animated: true)
    }

    // MARK: - Layout

    private func makeLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { [weak self] sectionIndex, environment in
            var config = UICollectionLayoutListConfiguration(appearance: .plain)
            config.backgroundColor = .clear
            config.headerMode = .supplementary
            config.headerTopPadding = 0
            config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
                self?.trailingSwipe(at: indexPath)
            }
            config.leadingSwipeActionsConfigurationProvider = { [weak self] indexPath in
                self?.leadingSwipe(at: indexPath)
            }
            let section = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
            if let self, let sections = self.dataSource?.snapshot().numberOfSections, sectionIndex == sections - 1 {
                section.boundarySupplementaryItems.append(PagingFooter.boundaryItem())
            }
            return section
        }
    }

    /// A trailing swipe that lists every person behind a grouped row.
    private func trailingSwipe(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let id = dataSource.itemIdentifier(for: indexPath), let notification = items[id],
              NotificationPresentation.hasPeopleList(notification) else { return nil }
        let people = UIContextualAction(style: .normal, title: "People") { [weak self] _, _, done in
            self?.showPeople(of: notification)
            done(true)
        }
        people.image = DesignSystem.icon("person.2.fill", pointSize: 18)
        people.backgroundColor = DesignSystem.Color.accent
        return UISwipeActionsConfiguration(actions: [people])
    }

    /// A leading swipe that reads one unread row.
    private func leadingSwipe(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let id = dataSource.itemIdentifier(for: indexPath), let notification = items[id],
              isUnread(notification) else { return nil }
        let read = UIContextualAction(style: .normal, title: "Read") { [weak self] _, _, done in
            self?.markRead(notification)
            done(true)
        }
        read.image = DesignSystem.icon("checkmark.circle.fill", pointSize: 18)
        read.backgroundColor = DesignSystem.Color.badge
        let configuration = UISwipeActionsConfiguration(actions: [read])
        configuration.performsFirstActionWithFullSwipe = true
        return configuration
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Notifications"
        view.backgroundColor = DesignSystem.Color.background
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = makeMoreButton()

        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: makeLayout())
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.contentInset.top = NotificationChipBar.height
        collectionView.verticalScrollIndicatorInsets.top = NotificationChipBar.height
        view.addManaged(collectionView)
        collectionView.pinEdges(to: view)
        setContentScrollView(collectionView, for: .top)
        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(reload), for: .valueChanged)
        collectionView.refreshControl = refresh

        view.addManaged(skeleton)
        view.addManaged(emptyState)
        view.addManaged(chipBar)
        view.addManaged(newPill)
        NSLayoutConstraint.activate([
            chipBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            chipBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            chipBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            chipBar.heightAnchor.constraint(equalToConstant: NotificationChipBar.height),
            skeleton.topAnchor.constraint(equalTo: chipBar.bottomAnchor),
            skeleton.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            skeleton.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            skeleton.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyState.topAnchor.constraint(equalTo: chipBar.bottomAnchor),
            emptyState.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyState.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            newPill.topAnchor.constraint(equalTo: chipBar.bottomAnchor, constant: DesignSystem.Spacing.s),
            newPill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])
        let edge = UIScrollEdgeElementContainerInteraction()
        edge.scrollView = collectionView
        edge.edge = .top
        chipBar.addInteraction(edge)
        chipBar.onSelect = { [weak self] category in self?.setCategory(category) }
        emptyState.onRetry = { [weak self] in self?.reload() }
        emptyState.isHidden = true
        skeleton.isHidden = true
        configureNewPill()

        let cellRegistration = registration
        let header = headerRegistration
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { cv, ip, id in
            cv.dequeueConfiguredReusableCell(using: cellRegistration, for: ip, item: id)
        }
        footer.attach(to: collectionView)
        footer.onRetry = { [weak self] in self?.retryFailedLoad() }
        footer.install(on: dataSource)
        let footerProvider = dataSource.supplementaryViewProvider
        dataSource.supplementaryViewProvider = { cv, kind, ip in
            kind == UICollectionView.elementKindSectionHeader
                ? cv.dequeueConfiguredReusableSupplementary(using: header, for: ip)
                : footerProvider?(cv, kind, ip)
        }

        followLoader.onChange = { [weak self] restID in self?.followStateChanged(restID) }
        observeDisplayChanges()
        if category == .mentions {
            applyCategory()
        } else {
            reload()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !placedInitialOffset, collectionView.adjustedContentInset.top >= NotificationChipBar.height else { return }
        placedInitialOffset = true
        scrollToTop(animated: false)
    }

    /// Redraws rows when the text size or display options change and when
    /// emoji art lands, so neither needs a reload.
    private func observeDisplayChanges() {
        let center = NotificationCenter.default
        displayObservers = [AppSettings.fontScaleDidChange, AppSettings.displayDidChange].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dataSource.reconfigureAllItems() }
            }
        }
        displayObservers.append(center.addObserver(forName: TwemojiCache.imagesDidLoad, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.collectionView.isHidden else { return }
                self.dataSource.reconfigureVisibleItems(of: self.collectionView)
            }
        })
    }

    /// Refreshes whenever the tab comes forward so the list is fresh without a
    /// manual pull, and starts live-merging poller results into the visible
    /// list. The seen marker advances only for pages/items the list actually
    /// renders (`notificationsDisplayed`), so nothing is consumed unseen.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let service = NotificationCenterService.shared
        let unseenActivity = service.hasUnreadActivity
        service.setViewingNotifications(true)
        service.onVisibleFresh = { [weak self] fresh in self?.mergeFresh(fresh) }
        service.onResumeWhileVisible = { [weak self] in self?.refreshIfStale(after: 0) }
        refreshIfStale(after: unseenActivity ? 0 : Self.staleAfter)
        startClock()
    }

    /// Keeps the "5m" on each row true while the list stays open: once a
    /// minute the rows on screen draw again with the current time.
    private func startClock() {
        clock?.invalidate()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.collectionView.isHidden else { return }
                self.dataSource.reconfigureVisibleItems(of: self.collectionView)
            }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
    }

    /// Reloads the list when it has never loaded or is older than `age`
    /// seconds. Coming back from a thread or another tab within that window
    /// keeps the loaded pages and the scroll position; the live poller keeps the
    /// top current meanwhile. Activity that lit the badge while the list was
    /// away is not in it, so `viewDidAppear` passes 0 then: the list has to
    /// show those rows for the seen marker to move past them.
    private func refreshIfStale(after age: TimeInterval) {
        guard category != .mentions, !loading else { return }
        if let lastLoaded, Date().timeIntervalSince(lastLoaded) < age { return }
        load(reset: true)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let service = NotificationCenterService.shared
        service.onVisibleFresh = nil
        service.onResumeWhileVisible = nil
        service.setViewingNotifications(false)
        clock?.invalidate()
        clock = nil
    }

    // MARK: - Reading

    /// Marks everything fetched as read: the displayed rows, the poller's
    /// newest, and the server marker — then regroups the list, the New block
    /// settling into its days.
    private func markAllRead() {
        Haptics.success()
        hiddenFresh.removeAll()
        NotificationCenterService.shared.markAllSeen(displayed: order.compactMap { items[$0] })
        unreadCutoff = NotificationPrefs.lastSeenTimestamp
        locallyRead.removeAll()
        applySnapshot(animated: true, reconfigure: order)
    }

    /// Reads one row: its unread mark goes, it stays where it is.
    private func markRead(_ notification: XNotification) {
        NotificationCenterService.shared.markSeen(notification)
        guard locallyRead.insert(notification.id).inserted else { return }
        Haptics.selection()
        applySnapshot(animated: false, reconfigure: [notification.id])
    }

    private func followStateChanged(_ restID: String) {
        let affected = order.filter { id in
            guard let notification = items[id], NotificationType(raw: notification.type) == .follow else { return false }
            return NotificationPresentation.peopleCount(notification) == 1 && notification.actors.first?.restID == restID
        }
        guard !affected.isEmpty else { return }
        applySnapshot(animated: false, reconfigure: affected)
    }

    // MARK: - Snapshot

    private func makeSnapshot() -> NSDiffableDataSourceSnapshot<NotificationSection, String> {
        let visible = order.filter { id in items[id].map(category.includes) ?? false }
        let sections = NotificationPresentation.sections(order: visible, items: items, isUnread: isNew)
        var snapshot = NSDiffableDataSourceSnapshot<NotificationSection, String>()
        digests = [:]
        for (section, ids) in sections {
            snapshot.appendSections([section])
            snapshot.appendItems(ids, toSection: section)
            if section == .new { digests[.new] = NotificationPresentation.digest(of: ids.compactMap { items[$0] }) }
        }
        return snapshot
    }

    /// Draws the list for the chosen chip. `reconfigure` re-renders just those
    /// rows (an unread mark cleared, a follow state landed) so no other row
    /// rebuilds its faces and thumbnail; `keepingPosition` holds what the
    /// reader is looking at still while rows arrive above it.
    private func applySnapshot(animated: Bool, keepingPosition: Bool = false, reconfigure ids: [String] = []) {
        var snapshot = makeSnapshot()
        let present = ids.filter { snapshot.indexOfItem($0) != nil }
        if !present.isEmpty { snapshot.reconfigureItems(present) }
        if keepingPosition {
            dataSource.applyKeepingPosition(snapshot, in: collectionView)
        } else {
            dataSource.apply(snapshot, animatingDifferences: animated)
        }
        refreshHeaders()
        updateChrome()
    }

    /// Everything around the rows that depends on them: the chips' unread dots,
    /// the menu, the empty state, the skeleton and the footer note.
    private func updateChrome() {
        var unreadCategories = Set<NotificationCategory>()
        for notification in items.values where isUnread(notification) {
            for candidate in NotificationCategory.allCases where candidate != .all && candidate.includes(notification) {
                unreadCategories.insert(candidate)
            }
            unreadCategories.insert(.all)
        }
        chipBar.setUnread(unreadCategories)
        let hasUnread = unreadCategories.contains(.all)
        if hasUnread != lastHadUnread {
            lastHadUnread = hasUnread
            navigationItem.rightBarButtonItem = makeMoreButton()
        }
        updateEmptyState()
        updateFooter()
    }

    private func updateEmptyState() {
        guard category != .mentions else { return }
        let hasRows = dataSource.snapshot().numberOfItems > 0
        skeleton.isHidden = hasRows || !(loading && lastLoaded == nil)
        if hasRows || loading {
            emptyState.isHidden = true
            return
        }
        if loadFailure != nil, order.isEmpty { return }
        let copy = category.emptyState
        emptyState.isHidden = false
        emptyState.show(symbol: copy.symbol, title: copy.title, subtitle: copy.subtitle, showRetry: false)
    }

    private func makeMoreButton() -> UIBarButtonItem {
        let hasUnread = items.values.contains(where: isUnread)
        let markRead = UIAction(title: "Mark all read", image: DesignSystem.icon("checkmark.circle"),
                                attributes: hasUnread ? [] : [.disabled]) { [weak self] _ in self?.markAllRead() }
        let settings = UIAction(title: "Notification settings", image: DesignSystem.icon("bell.badge")) { [weak self] _ in
            self?.navigationController?.pushViewController(NotificationSettingsViewController(), animated: true)
        }
        let item = UIBarButtonItem(image: DesignSystem.icon("ellipsis.circle"),
                                   menu: UIMenu(children: [markRead, settings]))
        item.accessibilityLabel = "More"
        return item
    }

    private func scrollToTop(animated: Bool) {
        collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.adjustedContentInset.top), animated: animated)
    }

    /// A narrow chip over a short list asks the server for more until it has
    /// enough to fill the screen, or there is no more.
    private func loadMoreIfSparse() {
        guard category != .all, category != .mentions, !exhausted, !loading, loadFailure == nil,
              dataSource.snapshot().numberOfItems < Self.fewRows else { return }
        load(reset: false)
    }

    // MARK: - New-arrivals pill

    private func configureNewPill() {
        var config = UIButton.Configuration.prominentGlass()
        config.cornerStyle = .capsule
        config.image = DesignSystem.icon("arrow.up", pointSize: 12, weight: .bold)
        config.imagePadding = 6
        config.baseBackgroundColor = DesignSystem.Color.badge
        config.baseForegroundColor = .white
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = DesignSystem.Typography.system(14, weight: .semibold)
            return outgoing
        }
        newPill.configuration = config
        newPill.alpha = 0
        newPill.isHidden = true
        newPill.addAction(UIAction { [weak self] _ in
            Haptics.selection()
            self?.pendingNew = 0
            self?.scrollToTop(animated: true)
        }, for: .touchUpInside)
    }

    private func updateNewPill() {
        let show = pendingNew > 0
        newPill.configuration?.title = "\(pendingNew) new"
        newPill.accessibilityLabel = "\(pendingNew) new notifications. Scroll to top."
        if show { newPill.isHidden = false }
        let reduce = UIAccessibility.isReduceMotionEnabled
        newPill.transform = show || reduce ? .identity : CGAffineTransform(translationX: 0, y: -12).scaledBy(x: 0.9, y: 0.9)
        UIView.animate(withDuration: reduce ? 0 : 0.35, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.4) {
            self.newPill.alpha = show ? 1 : 0
            self.newPill.transform = show ? .identity : CGAffineTransform(translationX: 0, y: -12).scaledBy(x: 0.9, y: 0.9)
        } completion: { _ in
            if !show { self.newPill.isHidden = true }
        }
    }

    // MARK: - Live merging

    /// Live-merges fresh poller items to the top of the list (they glow in and
    /// render as unread) and reports them displayed so the seen marker tracks
    /// what the user can actually see. A scrolled list keeps the rows being
    /// read where they are and raises the "new" pill instead. Under the
    /// Mentions chip the list isn't on screen: a new mention refreshes the
    /// mentions feed, and nothing is marked seen, so the rest still counts as
    /// unread when the user leaves. A narrow chip reports only what it shows.
    private func mergeFresh(_ fresh: [XNotification]) {
        guard category != .mentions else {
            if fresh.contains(where: { NotificationCategory.mentions.includes($0) }) {
                mentionsController?.viewModel.refresh()
            }
            return
        }
        let merge = Self.merge(fresh, into: order, items: items)
        guard !merge.incoming.isEmpty else { return }
        order = merge.order
        for notification in merge.incoming {
            items[notification.id] = notification
            locallyRead.remove(notification.id)
        }
        if resetLoadInFlight { mergedDuringResetLoad.append(contentsOf: merge.incoming) }
        let shown = merge.incoming.filter(category.includes)
        let hidden = merge.incoming.filter { !category.includes($0) }
        hiddenFresh.append(contentsOf: hidden)
        glowIDs.formUnion(shown.map(\.id))
        let scrolledAway = collectionView.scrollAnchor() != nil
        applySnapshot(animated: true, keepingPosition: true, reconfigure: merge.grown)
        if scrolledAway { pendingNew += shown.count }
        if view.window != nil, !shown.isEmpty {
            NotificationCenterService.shared.notificationsDisplayed(shown)
        }
    }

    /// Where fresh poller items go: a new one joins the top, and one already
    /// listed that has grown since ("Alice liked" → "Alice, Bob and 3 others
    /// liked") replaces its old row and moves to the top. Items identical to
    /// the listed row change nothing. Oldest are placed first, so the newest
    /// ends up on top.
    static func merge(
        _ fresh: [XNotification], into order: [String], items: [String: XNotification]
    ) -> (order: [String], incoming: [XNotification], grown: [String]) {
        let incoming = fresh
            .filter { items[$0.id] != $0 }
            .sorted { $0.timestamp < $1.timestamp }
        var order = order
        var grown: [String] = []
        for notification in incoming {
            if let index = order.firstIndex(of: notification.id) {
                order.remove(at: index)
                grown.append(notification.id)
            }
            order.insert(notification.id, at: 0)
        }
        return (order, incoming, grown)
    }

    /// Re-inserts, at the top, the fresh items the poller live-merged while the
    /// just-completed reset load was fetching — the reset page predates them, so
    /// rebuilding from it alone would silently drop notifications the user has
    /// already seen (their seen marker was advanced by `notificationsDisplayed`).
    private func reinsertLiveMerged() {
        defer { mergedDuringResetLoad.removeAll() }
        for notification in mergedDuringResetLoad.sorted(by: { $0.timestamp < $1.timestamp })
        where items[notification.id] == nil {
            items[notification.id] = notification
            order.insert(notification.id, at: 0)
        }
    }

    // MARK: - Loading

    @objc private func reload() { load(reset: true) }

    private func load(reset: Bool) {
        guard !loading, reset || !exhausted else { return }
        loading = true
        if reset {
            exhausted = false
            cursor = nil
            resetLoadInFlight = true
            mergedDuringResetLoad.removeAll()
        }
        loadFailure = nil
        updateEmptyState()
        updateFooter()
        Task {
            defer {
                loading = false
                resetLoadInFlight = false
                collectionView.refreshControl?.endRefreshing()
                updateEmptyState()
                updateFooter()
            }
            do {
                let page = try await AppEnvironment.shared.api.notifications(cursor: reset ? nil : cursor)
                if reset {
                    unreadCutoff = NotificationPrefs.lastSeenTimestamp
                    locallyRead.removeAll()
                    glowIDs.removeAll()
                    hiddenFresh.removeAll()
                    items.removeAll()
                    order.removeAll()
                    lastLoaded = Date()
                    pendingNew = 0
                }
                for notification in page.notifications where items[notification.id] == nil {
                    items[notification.id] = notification
                    order.append(notification.id)
                }
                if reset { reinsertLiveMerged() }
                cursor = page.cursor
                if page.cursor == nil || page.notifications.isEmpty { exhausted = true }
                applySnapshot(animated: reset && dataSource.snapshot().numberOfItems > 0)
                if reset, view.window != nil {
                    reportDisplayed(page.notifications)
                }
                loadMoreIfSparse()
            } catch {
                loadFailure = reset ? .refresh : .more
                if order.isEmpty {
                    emptyState.isHidden = false
                    skeleton.isHidden = true
                    emptyState.show(symbol: "exclamationmark.triangle", title: "Couldn't load",
                                    subtitle: error.localizedDescription, showRetry: true)
                }
                AppLogger.shared.warn("notifications load failed: \(error)", category: .timeline)
            }
        }
    }

    /// Hands the seen marker the page's rows the chosen chip shows, and holds
    /// back the rest until a chip shows them.
    private func reportDisplayed(_ notifications: [XNotification]) {
        let shown = notifications.filter(category.includes)
        hiddenFresh.append(contentsOf: notifications.filter { !category.includes($0) })
        guard !shown.isEmpty else { return }
        NotificationCenterService.shared.notificationsDisplayed(shown)
    }

    private func updateFooter() {
        switch loadFailure {
        case .refresh? where !order.isEmpty: footer.set(.failed("Couldn't refresh"))
        case .more?: footer.set(.failed("Couldn't load more"))
        case .refresh?: footer.set(.hidden)
        case nil:
            if loading && !order.isEmpty && !resetLoadInFlight {
                footer.set(.loading("Loading more…"))
            } else if exhausted && !order.isEmpty && !loading {
                footer.set(.note("You're all caught up"))
            } else {
                footer.set(.hidden)
            }
        }
    }

    private func retryFailedLoad() {
        let wasRefresh = loadFailure == .refresh
        loadFailure = nil
        updateFooter()
        load(reset: wasRefresh)
    }
}

extension NotificationsViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath), let notification = items[id] else { return }
        NotificationCenterService.shared.markSeen(notification)
        if locallyRead.insert(notification.id).inserted {
            applySnapshot(animated: false, reconfigure: [notification.id])
        }
        switch NotificationPresentation.destination(of: notification) {
        case .post(let tweetID)?:
            navigationController?.pushViewController(ThreadViewController(tweetID: tweetID), animated: true)
        case .people?:
            showPeople(of: notification)
        case .profile(let handle)?:
            navigationController?.pushViewController(ProfileViewController(handle: handle), animated: true)
        case nil:
            break
        }
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {
        let lastSection = collectionView.numberOfSections - 1
        guard loadFailure == nil, !exhausted, indexPath.section == lastSection,
              indexPath.item >= collectionView.numberOfItems(inSection: lastSection) - 4 else { return }
        load(reset: false)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard pendingNew > 0, scrollView.contentOffset.y <= -scrollView.adjustedContentInset.top + 40 else { return }
        pendingNew = 0
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first, let id = dataSource.itemIdentifier(for: indexPath),
              let notification = items[id] else { return nil }
        return UIContextMenuConfiguration(identifier: id as NSString, previewProvider: nil) { [weak self] _ in
            self?.menu(for: notification)
        }
    }

    private func menu(for notification: XNotification) -> UIMenu {
        var primary: [UIMenuElement] = []
        if let tweetID = notification.targetTweetID {
            primary.append(UIAction(title: "Open post", image: DesignSystem.icon("text.bubble")) { [weak self] _ in
                self?.navigationController?.pushViewController(ThreadViewController(tweetID: tweetID), animated: true)
            })
        }
        let profiles = notification.actors.prefix(3).map { actor in
            UIAction(title: "@\(actor.handle)", subtitle: actor.name, image: DesignSystem.icon("person.crop.circle")) {
                [weak self] _ in
                self?.navigationController?.pushViewController(ProfileViewController(handle: actor.handle), animated: true)
            }
        }
        if profiles.count == 1 {
            primary.append(profiles[0])
        } else if profiles.count > 1 {
            primary.append(UIMenu(title: "People", image: DesignSystem.icon("person.2"), children: profiles))
        }
        if NotificationPresentation.hasPeopleList(notification) {
            primary.append(UIAction(title: "See everyone", image: DesignSystem.icon("person.2.fill")) { [weak self] _ in
                self?.showPeople(of: notification)
            })
        }
        var secondary: [UIMenuElement] = []
        if isUnread(notification) {
            secondary.append(UIAction(title: "Mark as read", image: DesignSystem.icon("checkmark.circle")) {
                [weak self] _ in self?.markRead(notification)
            })
        }
        if let tweetID = notification.targetTweetID, let url = NotificationPresentation.postURL(tweetID) {
            secondary.append(UIAction(title: "Copy link", image: DesignSystem.icon("link")) { _ in
                UIPasteboard.general.string = url.absoluteString
            })
            secondary.append(UIAction(title: "Open in X", image: DesignSystem.icon("safari")) { _ in
                UIApplication.shared.open(url)
            })
        }
        return UIMenu(children: [UIMenu(options: .displayInline, children: primary),
                                 UIMenu(options: .displayInline, children: secondary)])
    }
}

#if DEBUG
extension NotificationsViewController {
    /// Screenshot-QA hook (`UNRAGER_SCREEN=notifications:mentions`, `:likes`, …):
    /// picks a chip deterministically.
    func debugSelect(_ raw: String) {
        loadViewIfNeeded()
        guard let category = NotificationCategory(rawValue: raw) else { return }
        setCategory(category)
    }

    func debugShowMentions() { debugSelect(NotificationCategory.mentions.rawValue) }

    /// Screenshot-QA hook: drags to the bottom of the list a few times, a
    /// second apart, so later pages load while it is scrolled.
    func debugScrollToEnd(times: Int, then raw: String? = nil) {
        loadViewIfNeeded()
        if let raw, let category = NotificationCategory(rawValue: raw) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3 + Double(times) * 1.2) { [weak self] in
                self?.setCategory(category)
            }
        }
        for step in 0..<times {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3 + Double(step) * 1.2) { [weak self] in
                guard let self else { return }
                let bottom = max(-self.collectionView.adjustedContentInset.top,
                                 self.collectionView.contentSize.height - self.collectionView.bounds.height
                                 + self.collectionView.adjustedContentInset.bottom)
                self.collectionView.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
            }
        }
    }

    func debugScroll(by points: CGFloat) {
        loadViewIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            self.collectionView.setContentOffset(
                CGPoint(x: 0, y: -self.collectionView.adjustedContentInset.top + points), animated: false)
        }
    }
}
#endif
