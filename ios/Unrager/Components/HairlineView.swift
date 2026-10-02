import UIKit

/// A one-pixel rule in the separator colour. Its height is derived from the
/// screen scale it is shown at, so it is a true hairline on every display —
/// reading the scale when the view is built would see the default traits, not
/// the screen's.
final class HairlineView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = DesignSystem.Color.separator
        registerForTraitChanges([UITraitDisplayScale.self]) { (view: HairlineView, _) in
            view.invalidateIntrinsicContentSize()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 1 / max(1, traitCollection.displayScale))
    }
}
