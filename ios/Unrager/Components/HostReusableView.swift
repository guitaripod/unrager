import UIKit

/// A collection-view supplementary view that hosts an arbitrary `UIView`
/// (used for the scrolling profile header).
final class HostReusableView: UICollectionReusableView {
    private weak var hosted: UIView?

    func host(_ view: UIView) {
        guard hosted !== view else { return }
        hosted?.removeFromSuperview()
        addManaged(view)
        view.pinEdges(to: self)
        hosted = view
    }
}
