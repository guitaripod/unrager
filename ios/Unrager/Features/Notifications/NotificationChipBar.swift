import UIKit

/// The filter chips under the navigation bar: All, Mentions, Likes, Reposts,
/// Follows. Glass capsules that scroll sideways when Dynamic Type makes them
/// wider than the screen; the chosen one is tinted solid. A small dot on a chip
/// says there is unread activity behind it.
final class NotificationChipBar: UIView {
    static let height: CGFloat = 52
    /// How far the veil reaches up behind the navigation bar, so rows never show through it.
    private static let veilAbove: CGFloat = 160

    var onSelect: ((NotificationCategory) -> Void)?

    private(set) var selected: NotificationCategory
    private let scroll = UIScrollView()
    private let backdrop = FadeBackdropView()
    private let stack = UIStackView()
    private var chips: [NotificationCategory: ChipControl] = [:]
    private var dots: [NotificationCategory: UIView] = [:]

    init(selected: NotificationCategory) {
        self.selected = selected
        super.init(frame: .zero)
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: topAnchor, constant: -Self.veilAbove),
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 18),
        ])
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        scroll.clipsToBounds = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        scroll.pinEdges(to: self)

        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerYAnchor),
            scroll.contentLayoutGuide.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
        for category in NotificationCategory.allCases {
            let chip = ChipControl(title: category.title)
            chip.addAction(UIAction { [weak self] _ in self?.tapped(category) }, for: .touchUpInside)
            addDot(for: category, to: chip)
            chips[category] = chip
            stack.addArrangedSubview(chip)
        }
        refreshStyles()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: Self.height) }

    func select(_ category: NotificationCategory) {
        guard category != selected else { return }
        selected = category
        refreshStyles()
        scrollToReveal(category)
    }

    /// Lights the dot on every chip in `categories` that is not the chosen one.
    func setUnread(_ categories: Set<NotificationCategory>) {
        for (category, dot) in dots {
            dot.isHidden = category == selected || !categories.contains(category)
        }
        for (category, chip) in chips {
            let unread = dots[category]?.isHidden == false
            chip.accessibilityValue = unread ? "Unread activity" : nil
        }
    }

    private func tapped(_ category: NotificationCategory) {
        guard category != selected else { return }
        select(category)
        dots[category]?.isHidden = true
        onSelect?(category)
    }

    private func addDot(for category: NotificationCategory, to chip: ChipControl) {
        let dot = UIView()
        dot.backgroundColor = DesignSystem.Color.badge
        dot.layer.cornerRadius = 4.5
        dot.isUserInteractionEnabled = false
        dot.isHidden = true
        dot.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(dot)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 9),
            dot.heightAnchor.constraint(equalToConstant: 9),
            dot.topAnchor.constraint(equalTo: chip.topAnchor, constant: 1),
            dot.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -1),
        ])
        dots[category] = dot
    }

    private func refreshStyles() {
        for (category, chip) in chips { chip.isChosen = category == selected }
    }

    /// Brings the chosen chip fully into view when the row scrolls.
    private func scrollToReveal(_ category: NotificationCategory) {
        guard let chip = chips[category] else { return }
        layoutIfNeeded()
        scroll.scrollRectToVisible(chip.frame.insetBy(dx: -16, dy: 0), animated: true)
    }
}

/// A veil of the page colour that is solid at the top and clear at the bottom,
/// so rows scrolling up under the chips fade out instead of running through
/// them. It does not take touches.
private final class FadeBackdropView: UIView {
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
/// the one chosen.
private final class ChipControl: UIControl {
    private let glass = UIVisualEffectView()
    private let label = UILabel()

    var isChosen = false {
        didSet {
            guard isChosen != oldValue else { return }
            refresh()
        }
    }

    init(title: String) {
        super.init(frame: .zero)
        label.text = title
        label.font = DesignSystem.Typography.system(14, weight: .semibold)
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
        accessibilityLabel = title
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.7 : 1 }
    }

    private func refresh() {
        let effect = UIGlassEffect(style: .regular)
        effect.isInteractive = true
        if isChosen { effect.tintColor = DesignSystem.Color.accent }
        glass.effect = effect
        label.textColor = isChosen ? .white : DesignSystem.Color.label
        accessibilityTraits = isChosen ? [.button, .selected] : .button
    }
}
