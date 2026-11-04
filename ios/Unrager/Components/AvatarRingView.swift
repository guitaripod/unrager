import UIKit

/// A ring a little clear of a round avatar, tinted for how the person stands
/// with the viewer. It is pinned to the avatar with constraints, so it follows
/// the picture through every layout pass, the first one included: a ring
/// placed from the avatar's frame in the cell's own layout is drawn before the
/// stacks inside the cell have moved the picture, at the content's corner.
final class AvatarRingView: UIView {
    /// The ring's colour, or nil for no ring.
    var tint: UIColor? {
        didSet { paint() }
    }

    init(lineWidth: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        isHidden = true
        layer.borderWidth = lineWidth
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) {
            (view: AvatarRingView, _) in view.paint()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The constraints that hold the ring around `avatar`, `gap` points clear
    /// of its edge. The ring and the avatar must share an ancestor.
    func surrounding(_ avatar: UIView, gap: CGFloat) -> [NSLayoutConstraint] {
        let outset = gap + layer.borderWidth / 2
        return [
            leadingAnchor.constraint(equalTo: avatar.leadingAnchor, constant: -outset),
            trailingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: outset),
            topAnchor.constraint(equalTo: avatar.topAnchor, constant: -outset),
            bottomAnchor.constraint(equalTo: avatar.bottomAnchor, constant: outset),
        ]
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }

    private func paint() {
        isHidden = tint == nil
        layer.borderColor = tint?.resolvedColor(with: traitCollection).cgColor
    }
}
