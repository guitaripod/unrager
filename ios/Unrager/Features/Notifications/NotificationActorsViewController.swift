import UIKit
import UnragerKit

/// The full actor list behind a grouped notification ("A, B and 3 others
/// followed you") — every face is reachable, not just the first. Mirrors the
/// Likers list styling; tapping a row opens that user's profile.
final class NotificationActorsViewController: UIViewController {
    private let actors: [NotificationActor]
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var rowsByID: [String: UserRow] = [:]

    init(title: String, actors: [NotificationActor]) {
        self.actors = actors
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private lazy var registration = UICollectionView.CellRegistration<UserRowCell, String> {
        [weak self] cell, _, id in
        guard let row = self?.rowsByID[id] else { return }
        cell.configure(with: row)
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
        for actor in actors where rowsByID[actor.restID] == nil {
            rowsByID[actor.restID] = UserRow(actor)
            order.append(actor.restID)
        }
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(order)
        dataSource.apply(snapshot, animatingDifferences: false)
    }
}

extension NotificationActorsViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath), let row = rowsByID[id] else { return }
        navigationController?.pushViewController(ProfileViewController(handle: row.handle), animated: true)
    }
}
