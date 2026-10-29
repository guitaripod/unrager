import UIKit

/// A veil of the page colour that is solid at the top and clear at the bottom,
/// so rows scrolling up under a row of chips fade out instead of running
/// through them. It does not take touches.
final class FadeBackdropView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        let layer = layer as! CAGradientLayer
        layer.startPoint = CGPoint(x: 0.5, y: 0)
        layer.endPoint = CGPoint(x: 0.5, y: 1)
        layer.locations = [0, 0.86, 1]
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: FadeBackdropView, _) in
            view.refreshColors()
        }
        refreshColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func refreshColors() {
        let base = DesignSystem.Color.background.resolvedColor(with: traitCollection)
        (layer as! CAGradientLayer).colors = [base.cgColor,
                                              base.withAlphaComponent(0.97).cgColor,
                                              base.withAlphaComponent(0).cgColor]
    }
}

/// One filter chip: a glass capsule sized to its title, tinted solid when it is
/// the one chosen. A chip that counts what it filters to shows the number after
/// its title, a step lighter.
final class ChipControl: UIControl {
    private let glass = UIVisualEffectView()
    private let label = UILabel()
    private let title: String
    private let tint: UIColor
    private var count: Int?

    var isChosen = false {
        didSet {
            guard isChosen != oldValue else { return }
            refresh()
        }
    }

    init(title: String, tint: UIColor = DesignSystem.Color.accent) {
        self.title = title
        self.tint = tint
        super.init(frame: .zero)
        glass.isUserInteractionEnabled = false
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.setCapsuleCorners()
        addSubview(glass)
        glass.pinEdges(to: self)
        label.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: 9),
            label.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -9),
        ])
        isAccessibilityElement = true
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.7 : 1 }
    }

    func setCount(_ newCount: Int?) {
        guard newCount != count else { return }
        count = newCount
        refresh()
    }

    private func refresh() {
        let effect = UIGlassEffect(style: .regular)
        effect.isInteractive = true
        if isChosen { effect.tintColor = tint }
        glass.effect = effect
        let color: UIColor = isChosen ? .white : DesignSystem.Color.label
        let text = NSMutableAttributedString(string: title, attributes: [
            .font: DesignSystem.Typography.system(14, weight: .semibold), .foregroundColor: color,
        ])
        if let count {
            text.append(NSAttributedString(string: "  \(count.formatted())", attributes: [
                .font: DesignSystem.Typography.system(14, weight: .medium),
                .foregroundColor: color.withAlphaComponent(isChosen ? 0.82 : 0.55),
            ]))
        }
        label.attributedText = text
        accessibilityLabel = count.map { "\(title), \($0.formatted())" } ?? title
        accessibilityTraits = isChosen ? [.button, .selected] : .button
    }
}
