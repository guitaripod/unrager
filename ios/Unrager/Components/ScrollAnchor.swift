import UIKit

extension UICollectionView {
    /// A visible row and its distance below the top of the viewport.
    struct ScrollAnchor {
        let indexPath: IndexPath
        let distanceFromTop: CGFloat
    }

    /// The first row whose bottom edge is below the viewport top — what to hold
    /// still while rows are inserted above it. Nil when scrolled to the top, where
    /// new rows are meant to push the content down.
    func scrollAnchor() -> ScrollAnchor? {
        guard contentOffset.y > -adjustedContentInset.top + 1 else { return nil }
        for indexPath in indexPathsForVisibleItems.sorted() {
            guard let attributes = layoutAttributesForItem(at: indexPath),
                  attributes.frame.maxY > contentOffset.y else { continue }
            return ScrollAnchor(indexPath: indexPath, distanceFromTop: attributes.frame.minY - contentOffset.y)
        }
        return nil
    }

    /// Puts `anchor`'s row back at the same distance below the viewport top,
    /// where `newIndexPath` is the row's position after the update.
    func restore(_ anchor: ScrollAnchor, at newIndexPath: IndexPath) {
        layoutIfNeeded()
        guard let attributes = layoutAttributesForItem(at: newIndexPath) else { return }
        let lowest = -adjustedContentInset.top
        let highest = max(lowest, contentSize.height - bounds.height + adjustedContentInset.bottom)
        let target = min(max(lowest, attributes.frame.minY - anchor.distanceFromTop), highest)
        setContentOffset(CGPoint(x: 0, y: target), animated: false)
    }
}

extension UICollectionViewDiffableDataSource where ItemIdentifierType == String {
    /// Applies `snapshot` without moving what the reader is looking at: when the
    /// list is scrolled, the topmost visible row keeps its place on screen
    /// whatever is inserted or removed above it. At the top it animates as usual.
    func applyKeepingPosition(_ snapshot: NSDiffableDataSourceSnapshot<SectionIdentifierType, String>,
                              in collectionView: UICollectionView) {
        guard let anchor = collectionView.scrollAnchor(),
              let anchorID = itemIdentifier(for: anchor.indexPath),
              snapshot.indexOfItem(anchorID) != nil else {
            apply(snapshot, animatingDifferences: true)
            return
        }
        apply(snapshot, animatingDifferences: false) { [weak self, weak collectionView] in
            guard let self, let collectionView, let newIndexPath = self.indexPath(for: anchorID) else { return }
            collectionView.restore(anchor, at: newIndexPath)
        }
    }
}
