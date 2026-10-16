import UIKit

/// One way to narrow a list: a chip with the number of people it leaves.
struct LensChip: Hashable {
    let id: String
    let title: String
    let count: Int?
    let tint: UIColor
    /// A grey stand-in that holds the bar's place while the chips it will show
    /// load; it takes no touches.
    var isPlaceholder = false

    /// The stand-ins a bar shows until its chips are known.
    static var placeholders: [LensChip] {
        (0..<4).map { LensChip(id: "placeholder-\($0)", title: "", count: nil, tint: .clear, isPlaceholder: true) }
    }
}

/// The row of lens chips pinned under the navigation bar while a list of
/// people scrolls beneath it: glass capsules that slide sideways when Dynamic
/// Type makes them wider than the screen, the chosen one tinted solid. With no
/// chips it measures zero, so a list that doesn't narrow carries nothing.
final class LensBarView: UICollectionReusableView {
    static let kind = "lens-bar"
    static let height: CGFloat = 52

    var onSelect: ((String) -> Void)?

    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let placeholderStack = UIStackView()
    private var controls: [String: ChipControl] = [:]
    private var chosen: String?
    private var showsPlaceholders = false
    private var heightConstraint: NSLayoutConstraint!
    private static let placeholderWidths: [CGFloat] = [58, 104, 112, 96]

    /// The boundary item that pins the bar to the top of its section.
    static func boundaryItem() -> NSCollectionLayoutBoundarySupplementaryItem {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(height))
        let item = NSCollectionLayoutBoundarySupplementaryItem(layoutSize: size, elementKind: kind, alignment: .top)
        item.pinToVisibleBounds = true
        item.zIndex = 10
        return item
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        let backdrop = FadeBackdropView()
        addManaged(backdrop)
        backdrop.pinEdges(to: self)

        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        scroll.clipsToBounds = false
        addManaged(scroll)
        scroll.pinEdges(to: self)
        heightConstraint = scroll.heightAnchor.constraint(equalToConstant: Self.height)
        heightConstraint.isActive = true

        for row in [stack, placeholderStack] {
            row.spacing = 6
            row.translatesAutoresizingMaskIntoConstraints = false
            scroll.addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 12),
                row.centerYAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerYAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -12),
            scroll.contentLayoutGuide.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
        for width in Self.placeholderWidths {
            let capsule = UIView()
            capsule.backgroundColor = .secondarySystemFill
            capsule.layer.cornerRadius = 17.5
            capsule.layer.cornerCurve = .continuous
            capsule.translatesAutoresizingMaskIntoConstraints = false
            placeholderStack.addArrangedSubview(capsule)
            NSLayoutConstraint.activate([
                capsule.widthAnchor.constraint(equalToConstant: width),
                capsule.heightAnchor.constraint(equalToConstant: 35),
            ])
        }
        placeholderStack.isHidden = true
        placeholderStack.isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        breathePlaceholders()
    }

    /// Shows `chips` with `selected` chosen. The same chips again only update
    /// their counts and the choice, and a chip that is new fades in beside the
    /// ones already there, so the row never rebuilds under a finger. Stand-ins
    /// hold the bar's height until the real chips replace them, which then
    /// rise in one after another.
    func configure(chips: [LensChip], selected: String) {
        let placeholders = chips.first?.isPlaceholder == true
        heightConstraint.constant = chips.isEmpty ? 0 : Self.height
        isHidden = chips.isEmpty
        if placeholders {
            showPlaceholders()
            return
        }
        let cameFromPlaceholders = showsPlaceholders
        hidePlaceholders()
        let animated = window != nil && !UIAccessibility.isReduceMotionEnabled
        let firstReal = controls.isEmpty
        let ids = Set(chips.map(\.id))
        for (id, control) in controls where !ids.contains(id) {
            control.removeFromSuperview()
            controls[id] = nil
        }
        var added: [ChipControl] = []
        for (index, chip) in chips.enumerated() where controls[chip.id] == nil {
            let control = ChipControl(title: chip.title, tint: chip.tint)
            control.addAction(UIAction { [weak self] _ in self?.tapped(chip.id) }, for: .touchUpInside)
            controls[chip.id] = control
            stack.insertArrangedSubview(control, at: min(index, stack.arrangedSubviews.count))
            added.append(control)
        }
        for chip in chips {
            controls[chip.id]?.setCount(chip.count)
            controls[chip.id]?.isChosen = chip.id == selected
        }
        if animated, !added.isEmpty {
            rise(added, staggered: firstReal || cameFromPlaceholders)
        }
        if chosen != selected {
            chosen = selected
            revealChosen()
        }
    }

    private func showPlaceholders() {
        guard !showsPlaceholders || placeholderStack.isHidden else { return }
        showsPlaceholders = true
        stack.isHidden = true
        placeholderStack.isHidden = false
        placeholderStack.alpha = 1
        breathePlaceholders()
    }

    private func hidePlaceholders() {
        guard showsPlaceholders else { return }
        showsPlaceholders = false
        stack.isHidden = false
        placeholderStack.arrangedSubviews.forEach { $0.layer.removeAnimation(forKey: "breathe") }
        guard window != nil, !UIAccessibility.isReduceMotionEnabled else {
            placeholderStack.isHidden = true
            return
        }
        UIView.animate(withDuration: 0.16, delay: 0, options: [.allowUserInteraction]) {
            self.placeholderStack.alpha = 0
        } completion: { _ in
            if !self.showsPlaceholders { self.placeholderStack.isHidden = true }
        }
    }

    /// The stand-ins pulse, each a beat behind the one before.
    private func breathePlaceholders() {
        for (index, capsule) in placeholderStack.arrangedSubviews.enumerated() {
            capsule.layer.removeAnimation(forKey: "breathe")
            guard showsPlaceholders, window != nil, !UIAccessibility.isReduceMotionEnabled else { continue }
            let breathe = CABasicAnimation(keyPath: "opacity")
            breathe.fromValue = 0.45
            breathe.toValue = 1
            breathe.duration = 0.8
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.beginTime = CACurrentMediaTime() + Double(index) * 0.12
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            capsule.layer.add(breathe, forKey: "breathe")
        }
    }

    /// Lifts `chips` into place from a little below and a little small.
    private func rise(_ chips: [ChipControl], staggered: Bool) {
        for (index, chip) in chips.enumerated() {
            chip.alpha = 0
            chip.transform = CGAffineTransform(translationX: 0, y: 8).scaledBy(x: 0.94, y: 0.94)
            UIView.animate(withDuration: 0.45, delay: staggered ? 0.05 + Double(index) * 0.045 : 0,
                           usingSpringWithDamping: 0.82, initialSpringVelocity: 0, options: [.allowUserInteraction]) {
                chip.alpha = 1
                chip.transform = .identity
            }
        }
    }

    private func tapped(_ id: String) {
        guard id != chosen else { return }
        Haptics.selection()
        onSelect?(id)
    }

    private func revealChosen() {
        guard let chosen, let control = controls[chosen] else { return }
        layoutIfNeeded()
        scroll.scrollRectToVisible(control.frame.insetBy(dx: -16, dy: 0), animated: window != nil)
    }
}
