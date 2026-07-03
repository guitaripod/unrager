import UIKit
import UnragerKit

/// The full actor list behind a grouped notification ("A, B and 3 others
/// followed you") — every face is reachable, not just the first. Mirrors the
/// Likers list styling; tapping a row opens that user's profile.
final class NotificationActorsViewController: UIViewController {
    private let actors: [NotificationActor]
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var actorsByID: [String: NotificationActor] = [:]

    init(title: String, actors: [NotificationActor]) {
        self.actors = actors
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private lazy var registration = UICollectionView.CellRegistration<UICollectionViewListCell, String> {
        [weak self] cell, _, id in
        guard let actor = self?.actorsByID[id] else { return }
        var content = UIListContentConfiguration.subtitleCell()
        content.text = actor.name
        content.secondaryText = "@\(actor.handle)"
        content.secondaryTextProperties.color = DesignSystem.Color.secondaryLabel
        content.image = DesignSystem.icon("person.crop.circle.fill", pointSize: 36)
        content.imageProperties.tintColor = DesignSystem.Color.tertiaryLabel
        content.imageProperties.maximumSize = CGSize(width: 40, height: 40)
        content.imageProperties.cornerRadius = 20
        cell.contentConfiguration = content
        cell.accessibilityLabel = "\(actor.name), @\(actor.handle)\(actor.verified ? ", verified" : "")"

        if actor.verified {
            let badge = UIImageView(image: DesignSystem.icon("checkmark.seal.fill", pointSize: 16))
            badge.tintColor = DesignSystem.Color.verified
            cell.accessories = [.customView(configuration: .init(customView: badge, placement: .trailing()))]
        } else {
            cell.accessories = [.disclosureIndicator()]
        }

        if AppSettings.imagesEnabled, let url = actor.avatarURL.flatMap(URL.init) {
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

        let reg = registration
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { cv, ip, id in
            cv.dequeueConfiguredReusableCell(using: reg, for: ip, item: id)
        }

        var order: [String] = []
        for actor in actors where actorsByID[actor.restID] == nil {
            actorsByID[actor.restID] = actor
            order.append(actor.restID)
        }
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(order)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func loadAvatar(_ url: URL, into cell: UICollectionViewListCell, id: String) {
        Task { [weak self, weak cell] in
            let image = await ImageLoader.image(for: url, pointSize: CGSize(width: 40, height: 40), scale: 3)
            guard let self, let cell, let image,
                  var content = cell.contentConfiguration as? UIListContentConfiguration,
                  self.actorsByID[id] != nil else { return }
            content.image = image
            cell.contentConfiguration = content
        }
    }
}

extension NotificationActorsViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath), let actor = actorsByID[id] else { return }
        navigationController?.pushViewController(ProfileViewController(handle: actor.handle), animated: true)
    }
}
