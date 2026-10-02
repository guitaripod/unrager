import UIKit

extension UICollectionViewDiffableDataSource {
    /// Re-renders every row — after a text-size change, so fonts re-resolve and
    /// self-sizing heights re-measure.
    func reconfigureAllItems() {
        var snapshot = self.snapshot()
        guard snapshot.numberOfItems > 0 else { return }
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        apply(snapshot, animatingDifferences: false)
    }

    /// Re-renders only the rows on screen — when something that affects how
    /// they draw (an emoji image) lands, without touching the rest; `affected`
    /// narrows it to the on-screen cells the change actually reaches.
    func reconfigureVisibleItems(
        of collectionView: UICollectionView, where affected: (UICollectionViewCell) -> Bool = { _ in true }
    ) {
        var snapshot = self.snapshot()
        let visible = collectionView.indexPathsForVisibleItems.compactMap { indexPath -> ItemIdentifierType? in
            guard let cell = collectionView.cellForItem(at: indexPath), affected(cell) else { return nil }
            return itemIdentifier(for: indexPath)
        }
        let present = visible.filter { snapshot.indexOfItem($0) != nil }
        guard !present.isEmpty else { return }
        snapshot.reconfigureItems(present)
        apply(snapshot, animatingDifferences: false)
    }
}
