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
    /// they draw (an emoji image) lands, without touching the rest.
    func reconfigureVisibleItems(of collectionView: UICollectionView) {
        var snapshot = self.snapshot()
        let visible = collectionView.indexPathsForVisibleItems.compactMap { itemIdentifier(for: $0) }
        let present = visible.filter { snapshot.indexOfItem($0) != nil }
        guard !present.isEmpty else { return }
        snapshot.reconfigureItems(present)
        apply(snapshot, animatingDifferences: false)
    }
}
