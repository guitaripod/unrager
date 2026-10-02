import UIKit
import UnragerKit

/// Notifications feed. A flat list of activity (likes, replies, follows, …)
/// with unread tinting, live-merging poller updates, and an All / Mentions
/// filter (Mentions swaps in the full-tweet mentions timeline). Tapping a row
/// opens the target tweet, the actor's profile, or the grouped actor list;
/// tapping an avatar always opens that actor's profile.
final class NotificationsViewController: UIViewController {
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var items: [String: XNotification] = [:]
    private var order: [String] = []
    private let emptyState = EmptyStateView()
    private let loadingIndicator = UIActivityIndicatorView(style: .medium)
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
    /// Rows newer than this render tinted as unread. Captured from the seen
    /// marker at each reset load, *before* the load advances it — so the tint
    /// survives the visit and clears on the next one, like X.
    private var unreadCutoff: Date?
    /// Rows the user opened since the last reset load: they drop their unread
    /// tint without disturbing the rest.
    private var locallyRead = Set<String>()
    /// When the list last finished a reset load, so coming back to the tab only
    /// reloads a list that has gone stale.
    private var lastLoaded: Date?
    private static let staleAfter: TimeInterval = 120
    private let footer = PagingFooter()
    private var displayObservers: [NSObjectProtocol] = []
    private var clock: Timer?

    // MARK: - Filter (All / Mentions)

    private enum Filter: String {
        case all
        case mentions
    }

    private static let filterKey = "unrager.ios.notificationsFilter"

    private var filter: Filter = {
        UserDefaults.standard.string(forKey: NotificationsViewController.filterKey)
            .flatMap(Filter.init(rawValue:)) ?? .all
    }() {
        didSet { UserDefaults.standard.set(filter.rawValue, forKey: Self.filterKey) }
    }

    /// The full-tweet mentions timeline embedded when the Mentions filter is
    /// active — the same source as the standalone Mentions tab.
    private var mentionsController: FeedViewController?

    private lazy var filterButton: UIBarButtonItem = {
        let item = UIBarButtonItem(image: DesignSystem.icon("line.3.horizontal.decrease.circle"),
                                   menu: makeFilterMenu())
        item.accessibilityLabel = "Filter notifications"
        return item
    }()

    private func makeFilterMenu() -> UIMenu {
        let all = UIAction(title: "All", image: DesignSystem.icon("bell"),
                           state: filter == .all ? .on : .off) { [weak self] _ in
            self?.setFilter(.all)
        }
        let mentions = UIAction(title: "Mentions", image: DesignSystem.icon("at"),
                                state: filter == .mentions ? .on : .off) { [weak self] _ in
            self?.setFilter(.mentions)
        }
        let segment = UIMenu(options: [.displayInline, .singleSelection], children: [all, mentions])
        let markRead = UIAction(title: "Mark all read",
                                image: DesignSystem.icon("checkmark.circle")) { [weak self] _ in
            self?.markAllRead()
        }
        return UIMenu(children: [segment, UIMenu(options: .displayInline, children: [markRead])])
    }

    private func setFilter(_ newFilter: Filter) {
        guard newFilter != filter else { return }
        Haptics.selection()
        filter = newFilter
        applyFilter()
    }

    /// Shows the surface for the active filter: the activity list, or the
    /// embedded mentions feed (created on first use).
    private func applyFilter() {
        filterButton.menu = makeFilterMenu()
        filterButton.image = DesignSystem.icon(
            filter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        let showMentions = filter == .mentions
        if showMentions, mentionsController == nil {
            let feed = FeedViewController(viewModel: TimelineViewModel(source: .mentions))
            addChild(feed)
            view.addManaged(feed.view)
            feed.view.pinEdges(to: view)
            feed.didMove(toParent: self)
            mentionsController = feed
        }
        mentionsController?.view.isHidden = !showMentions
        collectionView.isHidden = showMentions
        if showMentions {
            emptyState.isHidden = true
            loadingIndicator.stopAnimating()
        } else {
            emptyState.isHidden = !order.isEmpty || !hasSettledEmpty
            if !loading { load(reset: true) }
        }
    }

    /// True when an empty state has genuinely settled (a load completed with
    /// nothing), so toggling filters doesn't flash "No notifications".
    private var hasSettledEmpty = false

    // MARK: - Row building

    private lazy var registration = UICollectionView.CellRegistration<UICollectionViewListCell, String> {
        [weak self] cell, _, id in
        guard let self, let notif = self.items[id] else { return }
        let style = Self.style(for: notif.type)
        let unread = self.isUnread(notif)

        var content = cell.defaultContentConfiguration()
        content.attributedText = Self.title(for: notif, style: style)
        content.textProperties.numberOfLines = 2
        content.secondaryText = notif.targetTweetSnippet
        content.secondaryTextProperties.color = DesignSystem.Color.secondaryLabel
        content.secondaryTextProperties.numberOfLines = 2
        cell.contentConfiguration = content

        var background = UIBackgroundConfiguration.listCell()
        if unread {
            background.backgroundColor = DesignSystem.Color.accent.withAlphaComponent(0.08)
        }
        cell.backgroundConfiguration = background

        let stack = NotificationAvatarStackView(
            actors: notif.actors,
            chip: Self.badge(symbol: style.symbol, color: style.color,
                             diameter: notif.actors.isEmpty ? 38 : 20,
                             glyphSize: notif.actors.isEmpty ? 17 : 10),
            accentColor: style.color) { [weak self] actor in
            self?.navigationController?.pushViewController(
                ProfileViewController(handle: actor.handle), animated: true)
        }
        var accessories: [UICellAccessory] = [
            .customView(configuration: {
                var config = UICellAccessory.CustomViewConfiguration(
                    customView: stack, placement: .leading(displayed: .always), maintainsFixedSize: true)
                config.reservedLayoutWidth = .custom(NotificationAvatarStackView.size(for: NotificationAvatarStackView.maxAvatars).width)
                return config
            }()),
        ]
        if AppSettings.imagesEnabled, let thumb = notif.thumbnailURL {
            accessories.append(.customView(configuration: .init(
                customView: Self.makeThumb(url: thumb, isVideo: notif.targetMedia.first?.isVideo ?? false),
                placement: .trailing(displayed: .always),
                maintainsFixedSize: true)))
        }
        if notif.targetTweetID != nil { accessories.append(.disclosureIndicator()) }
        cell.accessories = accessories

        let copy = Self.bannerCopy(for: notif)
        let unreadPrefix = unread ? "Unread. " : ""
        cell.isAccessibilityElement = true
        cell.accessibilityTraits = .button
        cell.accessibilityLabel = "\(unreadPrefix)\(copy.title). \(copy.body)"
        cell.accessibilityCustomActions = notif.actors.prefix(NotificationAvatarStackView.maxAvatars).map { actor in
            UIAccessibilityCustomAction(name: "Open \(actor.name)'s profile") { [weak self] _ in
                self?.navigationController?.pushViewController(ProfileViewController(handle: actor.handle), animated: true)
                return true
            }
        }
    }

    private func isUnread(_ notif: XNotification) -> Bool {
        guard let cutoff = unreadCutoff, !locallyRead.contains(notif.id) else { return false }
        return NotificationPrefs.isNewer(notif.timestamp, than: cutoff)
    }

    /// A rounded media thumbnail for the trailing edge, with a play glyph on
    /// videos so a clip reads differently from a still. Cell-accessory custom
    /// views must keep `translatesAutoresizingMaskIntoConstraints` on and size
    /// via their frame; auto layout is used only inside.
    private static func makeThumb(url: URL, isVideo: Bool) -> UIView {
        let thumb = AsyncImageView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        thumb.contentMode = .scaleAspectFill
        thumb.clipsToBounds = true
        thumb.setRounded(8)
        thumb.load(url: url, targetSize: CGSize(width: 44, height: 44))
        if isVideo {
            let play = UIImageView(image: DesignSystem.icon("play.circle.fill", pointSize: 18))
            play.tintColor = .white
            play.translatesAutoresizingMaskIntoConstraints = false
            thumb.addSubview(play)
            NSLayoutConstraint.activate([
                play.centerXAnchor.constraint(equalTo: thumb.centerXAnchor),
                play.centerYAnchor.constraint(equalTo: thumb.centerYAnchor),
            ])
        }
        return thumb
    }

    private struct NotifStyle { let color: UIColor; let symbol: String; let verb: String }

    private static func style(for rawType: String) -> NotifStyle {
        switch rawType.lowercased().replacingOccurrences(of: "_", with: "") {
        case "like", "favorite": return .init(color: DesignSystem.Color.like, symbol: "heart.fill", verb: "liked your post")
        case "retweet", "repost": return .init(color: DesignSystem.Color.retweet, symbol: "arrow.2.squarepath", verb: "reposted you")
        case "reply": return .init(color: DesignSystem.Color.accent, symbol: "arrowshape.turn.up.left.fill", verb: "replied")
        case "mention": return .init(color: DesignSystem.Color.quote, symbol: "at", verb: "mentioned you")
        case "follow": return .init(color: DesignSystem.Color.retweet, symbol: "person.fill.badge.plus", verb: "followed you")
        case "quote": return .init(color: DesignSystem.Color.quote, symbol: "quote.bubble.fill", verb: "quoted you")
        case "communitynote": return .init(color: DesignSystem.Color.secondaryLabel, symbol: "note.text", verb: "added a Community Note")
        case "recommendation": return .init(color: DesignSystem.Color.accent, symbol: "sparkles", verb: "— suggested for you")
        case "trending": return .init(color: DesignSystem.Color.accent, symbol: "chart.line.uptrend.xyaxis", verb: "— trending")
        default: return .init(color: DesignSystem.Color.accent, symbol: "bell.fill", verb: rawType.replacingOccurrences(of: "_", with: " "))
        }
    }

    /// "A, B and 5 others" — the leading actor names plus the grouped
    /// remainder (undisplayed actors and the server's `others_count`), or nil
    /// when the notification carries no actors at all.
    private static func whoText(for notif: XNotification) -> String? {
        let shown = notif.actors.prefix(2).map(\.name)
        guard !shown.isEmpty else { return nil }
        let remaining = max(0, notif.actors.count - shown.count) + (notif.othersCount ?? 0)
        let names = shown.joined(separator: ", ")
        guard remaining > 0 else { return names }
        return "\(names) and \(remaining) other\(remaining == 1 ? "" : "s")"
    }

    /// Plain title + body for a local banner. The title carries the actor names
    /// and action verb; actor-less types fall back to X's own rendered message
    /// (never "Someone Poll"). The body is the target tweet snippet when present.
    static func bannerCopy(for notif: XNotification) -> (title: String, body: String) {
        let style = style(for: notif.type)
        if let who = whoText(for: notif) {
            return (title: "\(who) \(style.verb)", body: notif.targetTweetSnippet ?? "")
        }
        if let message = notif.message, !message.isEmpty {
            return (title: message, body: notif.targetTweetSnippet ?? "")
        }
        return (title: "Someone \(style.verb)", body: notif.targetTweetSnippet ?? "")
    }

    /// Badge image + title + optional subtitle for the in-app notification toast,
    /// reusing the row's action styling.
    static func toastContent(for notif: XNotification) -> (badge: UIImage, title: String, subtitle: String?) {
        let s = style(for: notif.type)
        let copy = bannerCopy(for: notif)
        return (badge(symbol: s.symbol, color: s.color), copy.title, copy.body.isEmpty ? nil : copy.body)
    }

    /// Coalesced toast content when several notifications land in one poll.
    static func toastSummary(count: Int) -> (badge: UIImage, title: String, subtitle: String?) {
        (badge(symbol: "bell.fill", color: DesignSystem.Color.accent), "\(count) new notifications", "Tap to view")
    }

    private static func title(for notif: XNotification, style: NotifStyle) -> NSAttributedString {
        let result = NSMutableAttributedString()
        if let who = whoText(for: notif) {
            result.append(NSAttributedString(string: who, attributes: [
                .font: DesignSystem.Typography.name(),
                .foregroundColor: DesignSystem.Color.label,
            ]))
            result.append(NSAttributedString(string: " " + style.verb, attributes: [
                .font: DesignSystem.Typography.handle(),
                .foregroundColor: style.color,
            ]))
        } else if let message = notif.message, !message.isEmpty {
            result.append(NSAttributedString(string: message, attributes: [
                .font: DesignSystem.Typography.name(),
                .foregroundColor: DesignSystem.Color.label,
            ]))
        } else {
            result.append(NSAttributedString(string: "Someone", attributes: [
                .font: DesignSystem.Typography.name(),
                .foregroundColor: DesignSystem.Color.label,
            ]))
            result.append(NSAttributedString(string: " " + style.verb, attributes: [
                .font: DesignSystem.Typography.handle(),
                .foregroundColor: style.color,
            ]))
        }
        result.append(NSAttributedString(string: " · " + Format.relativeTime(notif.timestamp), attributes: [
            .font: DesignSystem.Typography.handle(),
            .foregroundColor: DesignSystem.Color.secondaryLabel,
        ]))
        TwemojiText.substituteCachedEmoji(in: result, font: DesignSystem.Typography.name())
        return result
    }

    /// A colored circular chip with the action glyph — the splash of color the
    /// flat list was missing.
    private static func badge(symbol: String, color: UIColor, diameter: CGFloat = 38, glyphSize: CGFloat = 17) -> UIImage {
        let key = "\(symbol)|\(color.hash)|\(diameter)|\(glyphSize)|\(UITraitCollection.current.userInterfaceStyle.rawValue)"
        if let cached = badgeCache.object(forKey: key as NSString) { return cached }
        let image = renderBadge(symbol: symbol, color: color, diameter: diameter, glyphSize: glyphSize)
        badgeCache.setObject(image, forKey: key as NSString)
        return image
    }

    private static let badgeCache = NSCache<NSString, UIImage>()

    private static func renderBadge(symbol: String, color: UIColor, diameter: CGFloat, glyphSize: CGFloat) -> UIImage {
        let size = CGSize(width: diameter, height: diameter)
        return UIGraphicsImageRenderer(size: size).image { _ in
            color.withAlphaComponent(diameter <= 20 ? 1 : 0.16).setFill()
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).fill()
            let config = UIImage.SymbolConfiguration(pointSize: glyphSize, weight: .semibold)
            let tint = diameter <= 20 ? UIColor.white : color
            guard let glyph = UIImage(systemName: symbol, withConfiguration: config)?
                .withTintColor(tint, renderingMode: .alwaysOriginal) else { return }
            let rect = CGRect(x: (size.width - glyph.size.width) / 2,
                              y: (size.height - glyph.size.height) / 2,
                              width: glyph.size.width, height: glyph.size.height)
            glyph.draw(in: rect)
        }.withRenderingMode(.alwaysOriginal)
    }

    /// The list layout: a status footer, and a trailing swipe that lists every
    /// person behind a grouped like, repost or follow.
    private func makeLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { [weak self] _, environment in
            var config = UICollectionLayoutListConfiguration(appearance: .plain)
            config.backgroundColor = .clear
            config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
                self?.peopleSwipeAction(at: indexPath)
            }
            let section = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
            section.boundarySupplementaryItems = [PagingFooter.boundaryItem()]
            return section
        }
    }

    /// Whether a row stands for more than one person: the list names every
    /// actor X sent and its footer says how many more X left out.
    private func hasPeopleList(_ notif: XNotification) -> Bool {
        notif.actors.count > 1 || (notif.othersCount ?? 0) > 0
    }

    private func peopleSwipeAction(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let id = dataSource.itemIdentifier(for: indexPath), let notif = items[id],
              hasPeopleList(notif) else { return nil }
        let people = UIContextualAction(style: .normal, title: "People") { [weak self] _, _, done in
            self?.showPeople(of: notif)
            done(true)
        }
        people.image = DesignSystem.icon("person.2.fill", pointSize: 18)
        people.backgroundColor = DesignSystem.Color.accent
        return UISwipeActionsConfiguration(actions: [people])
    }

    private func showPeople(of notif: XNotification) {
        let verb = Self.style(for: notif.type).verb
        let list = NotificationActorsViewController(
            title: verb.prefix(1).uppercased() + verb.dropFirst(), actors: notif.actors,
            othersCount: notif.othersCount)
        navigationController?.pushViewController(list, animated: true)
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Notifications"
        view.backgroundColor = DesignSystem.Color.background
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = filterButton

        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: makeLayout())
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        view.addManaged(collectionView)
        collectionView.pinEdges(to: view)
        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(reload), for: .valueChanged)
        collectionView.refreshControl = refresh

        emptyState.onRetry = { [weak self] in self?.reload() }
        view.addManaged(emptyState)
        emptyState.pinEdges(toSafeAreaOf: view)
        emptyState.isHidden = true

        loadingIndicator.hidesWhenStopped = true
        view.addManaged(loadingIndicator)
        NSLayoutConstraint.activate([
            loadingIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        let reg = registration
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { cv, ip, id in
            cv.dequeueConfiguredReusableCell(using: reg, for: ip, item: id)
        }
        displayObservers = [AppSettings.fontScaleDidChange, AppSettings.displayDidChange].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dataSource.reconfigureAllItems() }
            }
        }
        footer.attach(to: collectionView)
        footer.onRetry = { [weak self] in self?.retryFailedLoad() }
        footer.install(on: dataSource)
        if filter == .mentions {
            applyFilter()
        } else {
            loadingIndicator.startAnimating()
            reload()
        }
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
        guard filter == .all, !loading else { return }
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

    /// Marks everything fetched as read: the displayed rows, the poller's
    /// newest, and the server marker — then untints the list.
    private func markAllRead() {
        Haptics.success()
        let unread = order.filter { id in items[id].map(isUnread) ?? false }
        NotificationCenterService.shared.markAllSeen(displayed: order.compactMap { items[$0] })
        unreadCutoff = NotificationPrefs.lastSeenTimestamp
        reconfigure(unread)
    }

    /// Re-renders just `ids` — the rows whose tint changed — so no other row
    /// rebuilds its avatars and thumbnail.
    private func reconfigure(_ ids: [String]) {
        guard var snapshot = dataSource?.snapshot() else { return }
        let present = ids.filter { snapshot.indexOfItem($0) != nil }
        guard !present.isEmpty else { return }
        snapshot.reconfigureItems(present)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// Live-merges fresh poller items to the top of the list (they render
    /// tinted as unread) and reports them displayed so the seen marker tracks
    /// what the user can actually see. A scrolled list keeps the rows being
    /// read where they are. Under the Mentions filter the list isn't on screen:
    /// a new mention refreshes the mentions feed instead, and nothing is marked
    /// seen, so the rest still counts as unread when the user leaves.
    private func mergeFresh(_ fresh: [XNotification]) {
        guard filter == .all else {
            if fresh.contains(where: { Self.isMention($0) }) { mentionsController?.viewModel.refresh() }
            return
        }
        let merge = Self.merge(fresh, into: order, items: items)
        guard !merge.incoming.isEmpty else { return }
        order = merge.order
        for notif in merge.incoming {
            items[notif.id] = notif
            locallyRead.remove(notif.id)
        }
        if resetLoadInFlight { mergedDuringResetLoad.append(contentsOf: merge.incoming) }
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(order)
        snapshot.reconfigureItems(merge.grown)
        dataSource.applyKeepingPosition(snapshot, in: collectionView)
        emptyState.isHidden = true
        if view.window != nil {
            NotificationCenterService.shared.notificationsDisplayed(merge.incoming)
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
        for notif in incoming {
            if let index = order.firstIndex(of: notif.id) {
                order.remove(at: index)
                grown.append(notif.id)
            }
            order.insert(notif.id, at: 0)
        }
        return (order, incoming, grown)
    }

    private static func isMention(_ notif: XNotification) -> Bool {
        let type = notif.type.lowercased().replacingOccurrences(of: "_", with: "")
        return type == "mention" || type == "reply" || type == "quote"
    }

    /// Re-inserts, at the top, the fresh items the poller live-merged while the
    /// just-completed reset load was fetching — the reset page predates them, so
    /// rebuilding from it alone would silently drop notifications the user has
    /// already seen (their seen marker was advanced by `notificationsDisplayed`).
    private func reinsertLiveMerged() {
        defer { mergedDuringResetLoad.removeAll() }
        for notif in mergedDuringResetLoad.sorted(by: { $0.timestamp < $1.timestamp })
        where items[notif.id] == nil {
            items[notif.id] = notif
            order.insert(notif.id, at: 0)
        }
    }

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
        if order.isEmpty { emptyState.isHidden = true; loadingIndicator.startAnimating() }
        loadFailure = nil
        updateFooter()
        Task {
            defer {
                loading = false
                resetLoadInFlight = false
                loadingIndicator.stopAnimating()
                collectionView.refreshControl?.endRefreshing()
                updateFooter()
            }
            do {
                let page = try await AppEnvironment.shared.api.notifications(cursor: reset ? nil : cursor)
                if reset {
                    unreadCutoff = NotificationPrefs.lastSeenTimestamp
                    locallyRead.removeAll()
                    items.removeAll()
                    order.removeAll()
                    lastLoaded = Date()
                }
                for notif in page.notifications where items[notif.id] == nil {
                    items[notif.id] = notif
                    order.append(notif.id)
                }
                if reset { reinsertLiveMerged() }
                cursor = page.cursor
                if page.cursor == nil || page.notifications.isEmpty { exhausted = true }
                var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
                snapshot.appendSections([0])
                snapshot.appendItems(order)
                await dataSource.apply(snapshot, animatingDifferences: true)
                if reset, view.window != nil {
                    NotificationCenterService.shared.notificationsDisplayed(page.notifications)
                }
                hasSettledEmpty = order.isEmpty
                emptyState.isHidden = !order.isEmpty || filter == .mentions
                if order.isEmpty, filter == .all {
                    emptyState.show(symbol: "bell", title: "No notifications", subtitle: "You're all caught up.", showRetry: true)
                }
            } catch {
                if order.isEmpty, filter == .all {
                    emptyState.isHidden = false
                    emptyState.show(symbol: "exclamationmark.triangle", title: "Couldn't load", subtitle: error.localizedDescription, showRetry: true)
                } else if !order.isEmpty {
                    loadFailure = reset ? .refresh : .more
                }
                AppLogger.shared.warn("notifications load failed: \(error)", category: .timeline)
            }
        }
    }

    private enum LoadFailure { case refresh, more }
    private var loadFailure: LoadFailure?

    private func updateFooter() {
        switch loadFailure {
        case .refresh?: footer.set(.failed("Couldn't refresh"))
        case .more?: footer.set(.failed("Couldn't load more"))
        case nil:
            footer.set(loading && !order.isEmpty && !resetLoadInFlight ? .loading("Loading more…") : .hidden)
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
        guard let id = dataSource.itemIdentifier(for: indexPath), let notif = items[id] else { return }
        NotificationCenterService.shared.markSeen(notif)
        if locallyRead.insert(notif.id).inserted { reconfigure([notif.id]) }
        if let tweetID = notif.targetTweetID {
            navigationController?.pushViewController(ThreadViewController(tweetID: tweetID), animated: true)
        } else if notif.actors.count > 1 {
            showPeople(of: notif)
        } else if let actor = notif.actors.first {
            navigationController?.pushViewController(ProfileViewController(handle: actor.handle), animated: true)
        }
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard loadFailure == nil, indexPath.item >= order.count - 4 else { return }
        load(reset: false)
    }
}

#if DEBUG
extension NotificationsViewController {
    /// Screenshot-QA hook (`UNRAGER_SCREEN=notifications:mentions`): flips the
    /// filter to the embedded Mentions feed deterministically.
    func debugShowMentions() {
        loadViewIfNeeded()
        setFilter(.mentions)
    }
}
#endif
