import UIKit

/// A screen that can hand its main actions to the iPad's dock: a thread gives
/// reply, repost, like and share for the post it is about, so they sit under
/// the thumb instead of at the top of the column.
@MainActor
protocol DetailDockProviding: UIViewController {
    func dockActions() -> [DetailDock.Action]
    /// Called by the screen whenever what `dockActions()` returns changes.
    var onDockChange: (() -> Void)? { get set }
}

/// The glass bar at the bottom of what's open on an iPad: the way back first,
/// then the open screen's own actions. It sits low and to one side, where a
/// thumb rests on an iPad held in both hands, so closing a post or liking it
/// never means reaching for the top of the window.
final class DetailDock: UIView {
    struct Action {
        var id: String
        var symbol: String
        var title: String
        var isOn = false
        var onSymbol: String?
        var onTint: UIColor?
        var menu: UIMenu?
        var handler: (() -> Void)?
    }

    var onWayBack: (() -> Void)?

    private let glass = UIVisualEffectView.glass(interactive: true)
    private let stack = UIStackView()
    private let wayBackButton = UIButton(type: .system)
    private let divider = UIView()
    private var actionButtons: [UIButton] = []
    private var heightConstraint: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityContainerType = .semanticGroup
        glass.setCapsuleCorners()
        glass.clipsToBounds = true
        addManaged(glass)
        glass.pinEdges(to: self)

        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 2
        glass.contentView.addManaged(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: glass.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor),
        ])

        style(wayBackButton)
        wayBackButton.addAction(UIAction { [weak self] _ in
            Haptics.selection()
            self?.onWayBack?()
        }, for: .touchUpInside)
        stack.addArrangedSubview(wayBackButton)

        divider.backgroundColor = DesignSystem.Color.separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.heightAnchor.constraint(equalToConstant: 24),
        ])
        stack.addArrangedSubview(divider)
        stack.setCustomSpacing(6, after: wayBackButton)
        stack.setCustomSpacing(6, after: divider)

        heightConstraint = heightAnchor.constraint(equalToConstant: 56)
        heightConstraint.isActive = true
        configure(actions: [])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The dock's height: the floating bar's own, so the two read as one family.
    func setHeight(_ height: CGFloat) {
        heightConstraint.constant = height
    }

    /// Shows the way back and the open screen's `actions` after it.
    func configure(actions: [Action]) {
        var config = wayBackButton.configuration ?? .plain()
        config.image = DesignSystem.icon("chevron.backward", pointSize: 18, weight: .semibold)
        wayBackButton.configuration = config
        wayBackButton.accessibilityLabel = "Back"

        for button in actionButtons { button.removeFromSuperview() }
        actionButtons = actions.map { action in
            let button = UIButton(type: .system)
            style(button)
            var config = button.configuration ?? .plain()
            config.image = DesignSystem.icon(action.isOn ? action.onSymbol ?? action.symbol : action.symbol,
                                             pointSize: 18, weight: .medium)
            config.baseForegroundColor = action.isOn ? action.onTint ?? DesignSystem.Color.accent
                : DesignSystem.Color.label
            button.configuration = config
            button.accessibilityLabel = action.title
            button.accessibilityTraits = action.isOn ? [.button, .selected] : .button
            button.largeContentTitle = action.title
            button.showsLargeContentViewer = true
            if let handler = action.handler {
                button.addAction(UIAction { _ in
                    Haptics.selection()
                    handler()
                }, for: .touchUpInside)
            }
            if let menu = action.menu {
                button.menu = menu
                button.showsMenuAsPrimaryAction = action.handler == nil
            }
            stack.addArrangedSubview(button)
            return button
        }
        divider.isHidden = actions.isEmpty
    }

    private func style(_ button: UIButton) {
        var config = UIButton.Configuration.plain()
        config.baseForegroundColor = DesignSystem.Color.label
        config.contentInsets = .zero
        config.cornerStyle = .capsule
        button.configuration = config
        button.translatesAutoresizingMaskIntoConstraints = false
        button.pointerStyleProvider = { button, _, _ in
            UIPointerStyle(effect: .highlight(UITargetedPreview(view: button)))
        }
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 48),
            button.heightAnchor.constraint(equalToConstant: 44),
        ])
    }
}
