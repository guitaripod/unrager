import UIKit
import UnragerKit

/// Notifications feed. A flat list of activity (likes, replies, follows, …);
/// tapping an item opens the target tweet or the actor's profile.
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
    private var hasLoadedOnce = false

    private lazy var registration = UICollectionView.CellRegistration<UICollectionViewListCell, String> {
        [weak self] cell, _, id in
        guard let self, let notif = self.items[id] else { return }
        var content = cell.defaultContentConfiguration()
        let style = Self.style(for: notif.type)
        content.attributedText = Self.title(for: notif, style: style)
        content.secondaryText = notif.targetTweetSnippet
        content.secondaryTextProperties.color = DesignSystem.Color.secondaryLabel
        content.secondaryTextProperties.numberOfLines = 2
        content.image = Self.avatarPlaceholder(color: style.color)
        content.imageProperties.cornerRadius = 20
        content.imageProperties.reservedLayoutSize = CGSize(width: 44, height: 44)
        content.imageProperties.maximumSize = CGSize(width: 40, height: 40)
        cell.contentConfiguration = content

        var accessories: [UICellAccessory] = [
            .customView(configuration: .init(
                customView: Self.typeChip(symbol: style.symbol, color: style.color),
                placement: .leading(displayed: .always))),
        ]
        if AppSettings.imagesEnabled, let thumb = notif.thumbnailURL {
            accessories.append(.customView(configuration: .init(
                customView: Self.makeThumb(url: thumb, isVideo: notif.targetMedia.first?.isVideo ?? false),
                placement: .trailing(displayed: .always))))
        }
        if notif.targetTweetID != nil { accessories.append(.disclosureIndicator()) }
        cell.accessories = accessories

        if AppSettings.imagesEnabled, let url = notif.actors.first?.avatarURL.flatMap(URL.init) {
            self.loadAvatar(url, into: cell, id: id)
        }
    }

    /// Async-swaps the real actor avatar into the cell's content image, guarding
    /// that the cell still shows this notification (list cells reuse fast).
    private func loadAvatar(_ url: URL, into cell: UICollectionViewListCell, id: String) {
        Task { [weak self, weak cell] in
            let image = await ImageLoader.image(for: url, pointSize: CGSize(width: 40, height: 40), scale: 3)
            guard let self, let cell, let image,
                  let indexPath = self.collectionView.indexPath(for: cell),
                  self.dataSource.itemIdentifier(for: indexPath) == id,
                  var content = cell.contentConfiguration as? UIListContentConfiguration else { return }
            content.image = image
            cell.contentConfiguration = content
        }
    }

    /// A neutral round placeholder shown under the avatar until it loads.
    private static func avatarPlaceholder(color: UIColor) -> UIImage {
        let size = CGSize(width: 40, height: 40)
        return UIGraphicsImageRenderer(size: size).image { _ in
            color.withAlphaComponent(0.14).setFill()
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).fill()
        }.withRenderingMode(.alwaysOriginal)
    }

    /// A small colored circular chip carrying the action glyph (heart, reply, …)
    /// so the activity type reads at a glance beside the actor's face.
    private static func typeChip(symbol: String, color: UIColor) -> UIView {
        let diameter: CGFloat = 26
        let view = UIImageView(image: badge(symbol: symbol, color: color, diameter: diameter, glyphSize: 13))
        view.frame = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        return view
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
        default: return .init(color: DesignSystem.Color.accent, symbol: "bell.fill", verb: rawType.replacingOccurrences(of: "_", with: " "))
        }
    }

    private static func title(for notif: XNotification, style: NotifStyle) -> NSAttributedString {
        let names = notif.actors.prefix(2).map(\.name).joined(separator: ", ")
        let extra = notif.actors.count > 2 ? " +\(notif.actors.count - 2)" : ""
        let who = names.isEmpty ? "Someone" : names + extra
        let result = NSMutableAttributedString(string: who, attributes: [
            .font: DesignSystem.Typography.name(),
            .foregroundColor: DesignSystem.Color.label,
        ])
        result.append(NSAttributedString(string: " " + style.verb, attributes: [
            .font: DesignSystem.Typography.handle(),
            .foregroundColor: style.color,
        ]))
        return result
    }

    /// A colored circular chip with the action glyph — the splash of color the
    /// flat list was missing.
    private static func badge(symbol: String, color: UIColor, diameter: CGFloat = 38, glyphSize: CGFloat = 17) -> UIImage {
        let size = CGSize(width: diameter, height: diameter)
        return UIGraphicsImageRenderer(size: size).image { _ in
            color.withAlphaComponent(0.16).setFill()
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).fill()
            let config = UIImage.SymbolConfiguration(pointSize: glyphSize, weight: .semibold)
            guard let glyph = UIImage(systemName: symbol, withConfiguration: config)?
                .withTintColor(color, renderingMode: .alwaysOriginal) else { return }
            let rect = CGRect(x: (size.width - glyph.size.width) / 2,
                              y: (size.height - glyph.size.height) / 2,
                              width: glyph.size.width, height: glyph.size.height)
            glyph.draw(in: rect)
        }.withRenderingMode(.alwaysOriginal)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Notifications"
        view.backgroundColor = DesignSystem.Color.background
        navigationItem.largeTitleDisplayMode = .always

        var config = UICollectionLayoutListConfiguration(appearance: .plain)
        config.backgroundColor = .clear
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config))
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
        loadingIndicator.startAnimating()
        reload()
    }

    @objc private func reload() { load(reset: true) }

    private func load(reset: Bool) {
        guard !loading, reset || !exhausted else { return }
        loading = true
        if reset { exhausted = false; cursor = nil }
        if order.isEmpty { emptyState.isHidden = true; loadingIndicator.startAnimating() }
        Task {
            defer { loading = false; hasLoadedOnce = true; loadingIndicator.stopAnimating(); collectionView.refreshControl?.endRefreshing() }
            do {
                let page = try await AppEnvironment.shared.api.notifications(cursor: reset ? nil : cursor)
                if reset { items.removeAll(); order.removeAll() }
                for notif in page.notifications where items[notif.id] == nil {
                    items[notif.id] = notif
                    order.append(notif.id)
                }
                cursor = page.cursor
                if page.cursor == nil || page.notifications.isEmpty { exhausted = true }
                var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
                snapshot.appendSections([0])
                snapshot.appendItems(order)
                await dataSource.apply(snapshot, animatingDifferences: true)
                emptyState.isHidden = !order.isEmpty
                if order.isEmpty {
                    emptyState.show(symbol: "bell", title: "No notifications", subtitle: "You're all caught up.", showRetry: true)
                }
            } catch {
                if order.isEmpty {
                    emptyState.isHidden = false
                    emptyState.show(symbol: "exclamationmark.triangle", title: "Couldn't load", subtitle: error.localizedDescription, showRetry: true)
                }
                AppLogger.shared.warn("notifications load failed: \(error)", category: .timeline)
            }
        }
    }

}

extension NotificationsViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath), let notif = items[id] else { return }
        if let tweetID = notif.targetTweetID {
            navigationController?.pushViewController(ThreadViewController(tweetID: tweetID), animated: true)
        } else if let actor = notif.actors.first {
            navigationController?.pushViewController(ProfileViewController(handle: actor.handle), animated: true)
        }
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        if indexPath.item >= order.count - 4 { load(reset: false) }
    }
}
