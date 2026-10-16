import UIKit

/// One way to narrow a list: a chip with the number of people it leaves.
struct LensChip: Hashable {
    let id: String
    let title: String
    let count: Int?
    let tint: UIColor
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
    private var controls: [String: ChipControl] = [:]
    private var ids: [String] = []
    private var chosen: String?
    private var heightConstraint: NSLayoutConstraint!

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

        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerYAnchor),
            scroll.contentLayoutGuide.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Shows `chips` with `selected` chosen. The same chips again only update
    /// their counts and the choice, so the row never rebuilds under a finger.
    func configure(chips: [LensChip], selected: String) {
        let newIDs = chips.map(\.id)
        if newIDs != ids {
            controls.values.forEach { $0.removeFromSuperview() }
            controls = [:]
            for chip in chips {
                let control = ChipControl(title: chip.title, tint: chip.tint)
                control.addAction(UIAction { [weak self] _ in self?.tapped(chip.id) }, for: .touchUpInside)
                controls[chip.id] = control
                stack.addArrangedSubview(control)
            }
            ids = newIDs
        }
        for chip in chips {
            controls[chip.id]?.setCount(chip.count)
            controls[chip.id]?.isChosen = chip.id == selected
        }
        heightConstraint.constant = chips.isEmpty ? 0 : Self.height
        isHidden = chips.isEmpty
        if chosen != selected {
            chosen = selected
            revealChosen()
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
