import UIKit

/// The tab bar on iPad, drawn as the system draws it: a rail down the leading
/// edge of a landscape window, a floating glass bar at the bottom of a portrait
/// or narrow one. It carries the same items as the phone's bar — the chosen tab
/// tinted, unread activity badged — and adds a post button at the foot of the
/// rail, where a sidebar has the room for one.
final class TabChromeBar: UIView {
    enum Form: Equatable {
        case rail
        case bottom
    }

    struct Item {
        var title: String
        var image: UIImage?
        var badge: String?
    }

    var onSelect: ((Int) -> Void)?
    var onReselect: ((Int) -> Void)?
    var onCompose: (() -> Void)?

    private(set) var form: Form = .bottom
    private(set) var selectedIndex = 0

    private let glass = UIVisualEffectView.glass()
    private let edge = HairlineView()
    private let stack = UIStackView()
    private let postButton = UIButton(configuration: .unragerProminentGlass())
    private var rows: [TabChromeRow] = []

    private var edgeWidth: NSLayoutConstraint!
    private var stackTop: NSLayoutConstraint!
    private var stackSide: NSLayoutConstraint!
    private var stackBottom: NSLayoutConstraint!
    private var postHeight: NSLayoutConstraint!

    static let bottomHeight: CGFloat = 62
    /// How much of the bottom a screen under the bar has to keep clear.
    static let bottomClearance: CGFloat = bottomHeight + 22

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityContainerType = .semanticGroup
        isAccessibilityElement = false

        glass.isUserInteractionEnabled = false
        glass.clipsToBounds = true
        addManaged(glass)
        glass.pinEdges(to: self)

        addManaged(edge)
        edgeWidth = edge.widthAnchor.constraint(equalToConstant: 0)

        stack.axis = .vertical
        stack.alignment = .fill
        addManaged(stack)

        var post = UIButton.Configuration.unragerProminentGlass()
        post.image = DesignSystem.icon("square.and.pencil", pointSize: 17, weight: .semibold)
        post.imagePadding = 8
        post.title = "Post"
        postButton.configuration = post
        postButton.isHidden = true
        postButton.accessibilityLabel = "New post"
        postButton.addAction(UIAction { [weak self] _ in self?.onCompose?() }, for: .touchUpInside)
        addManaged(postButton)
        postHeight = postButton.heightAnchor.constraint(equalToConstant: 0)

        stackTop = stack.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 0)
        stackSide = stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10)
        stackBottom = stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        NSLayoutConstraint.activate([
            edgeWidth,
            edge.trailingAnchor.constraint(equalTo: trailingAnchor),
            edge.topAnchor.constraint(equalTo: topAnchor),
            edge.bottomAnchor.constraint(equalTo: bottomAnchor),
            stackTop,
            stackSide,
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            postButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            postButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            postButton.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -16),
            postHeight,
        ])
        install(form: .bottom)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Shows `items`, chosen at `selected`. Rows are reused while the tabs keep
    /// their count, so a retitled Home tab (For You ↔ Following) updates in
    /// place instead of being rebuilt under a finger.
    func setItems(_ items: [Item], selected: Int) {
        if items.count != rows.count {
            for row in rows {
                stack.removeArrangedSubview(row)
                row.removeFromSuperview()
            }
            rows = items.indices.map { index in
                let row = TabChromeRow(index: index, form: form)
                row.onTap = { [weak self] in self?.choose(index) }
                stack.addArrangedSubview(row)
                return row
            }
        }
        update(items, selected: selected)
    }

    func update(_ items: [Item], selected: Int) {
        selectedIndex = selected
        for (row, item) in zip(rows, items) {
            row.configure(item, chosen: row.index == selected)
        }
    }

    /// Switches between the rail and the bar; returns whether anything moved, so
    /// the caller only animates a real change.
    @discardableResult
    func apply(form newForm: Form) -> Bool {
        guard newForm != form else { return false }
        install(form: newForm)
        return true
    }

    private func install(form newForm: Form) {
        form = newForm
        let rail = newForm == .rail
        glass.setFixedCorners(rail ? 0 : Self.bottomHeight / 2)
        edge.isHidden = !rail
        edgeWidth.constant = rail ? 1 / max(1, traitCollection.displayScale) : 0
        postButton.isHidden = !rail
        postHeight.constant = rail ? 50 : 0
        stackTop.isActive = rail
        stackBottom.isActive = !rail
        if rail {
            stackTop.constant = 24
            stackSide.constant = 16
            stack.axis = .vertical
            stack.spacing = 2
            stack.distribution = .fill
        } else {
            stackSide.constant = 10
            stack.axis = .horizontal
            stack.spacing = 2
            stack.distribution = .fillEqually
        }
        for row in rows { row.form = newForm }
    }

    private func choose(_ index: Int) {
        guard index != selectedIndex else {
            onReselect?(index)
            return
        }
        guard rows.indices.contains(index) else { return }
        selectedIndex = index
        for row in rows { row.setChosen(row.index == index) }
        onSelect?(index)
    }
}

extension TabChromeBar.Form {
    /// The rail and the bar are the same choice `PadLayout` makes, named for
    /// where it is drawn.
    init(_ chrome: PadLayout.Chrome) {
        self = chrome == .rail ? .rail : .bottom
    }
}

/// One row of the chrome: an icon and a title side by side in the rail, stacked
/// in the bottom bar, with an unread badge where the form leaves room for one.
/// A real button, so VoiceOver, hover and the highlight all behave.
private final class TabChromeRow: UIView {
    let index: Int
    var onTap: (() -> Void)?

    private let button = UIButton(configuration: .plain())
    private let badge = BadgeCapsule()
    private var chosen = false
    private var item = TabChromeBar.Item(title: "", image: nil, badge: nil)
    private var badgeConstraints: [NSLayoutConstraint] = []

    var form: TabChromeBar.Form = .rail {
        didSet {
            guard oldValue != form else { return }
            build()
        }
    }

    init(index: Int, form: TabChromeBar.Form) {
        self.index = index
        self.form = form
        super.init(frame: .zero)
        addManaged(button)
        button.pinEdges(to: self)
        button.addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .touchUpInside)
        addManaged(badge)
        badge.isUserInteractionEnabled = false
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ item: TabChromeBar.Item, chosen: Bool) {
        guard chosen != self.chosen
            || item.title != self.item.title
            || item.badge != self.item.badge
            || item.image !== self.item.image else { return }
        self.item = item
        self.chosen = chosen
        build()
    }

    func setChosen(_ chosen: Bool) {
        guard chosen != self.chosen else { return }
        self.chosen = chosen
        style()
    }

    /// Rebuilds the row around the current form, title and count. Cheap enough
    /// to run on a tab rename and on a rotation; never on a scroll.
    private func build() {
        let rail = form == .rail
        var config = UIButton.Configuration.plain()
        config.title = item.title
        config.image = item.image?.applyingSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: rail ? 19 : 20, weight: .regular))
        config.imagePlacement = rail ? .leading : .top
        config.imagePadding = rail ? 12 : 2
        config.contentInsets = rail
            ? NSDirectionalEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
            : NSDirectionalEdgeInsets(top: 4, leading: 2, bottom: 4, trailing: 2)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var out = incoming
            out.font = rail ? DesignSystem.Typography.rowName() : DesignSystem.Typography.tabLabel()
            return out
        }
        config.background.cornerRadius = rail ? 12 : 16
        button.configuration = config
        button.accessibilityLabel = item.badge.map { "\(item.title), \($0) new" } ?? item.title
        button.accessibilityTraits = chosen ? [.button, .selected] : .button
        badge.text = item.badge
        NSLayoutConstraint.deactivate(badgeConstraints)
        badgeConstraints = rail
            ? [badge.centerYAnchor.constraint(equalTo: centerYAnchor),
               badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14)]
            : [badge.centerXAnchor.constraint(equalTo: centerXAnchor, constant: 15),
               badge.topAnchor.constraint(equalTo: topAnchor, constant: 2)]
        NSLayoutConstraint.activate(badgeConstraints)
        style()
    }

    private func style() {
        var config = button.configuration ?? .plain()
        config.baseForegroundColor = chosen ? DesignSystem.Color.accent : DesignSystem.Color.label
        config.background.backgroundColor = chosen && form == .rail
            ? DesignSystem.Color.accent.withAlphaComponent(0.16) : .clear
        button.configuration = config
        button.accessibilityTraits = chosen ? [.button, .selected] : .button
    }
}

/// The unread count on a chrome row: a small capsule that disappears when the
/// count does, so a quiet tab shows a bare icon.
private final class BadgeCapsule: UIView {
    private let label = UILabel()

    var text: String? {
        didSet {
            guard text != oldValue else { return }
            label.text = text
            isHidden = text?.isEmpty != false
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = DesignSystem.Color.badge
        setCapsuleCorners()
        label.font = DesignSystem.Typography.system(10, weight: .bold)
        label.textColor = .white
        label.textAlignment = .center
        addManaged(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            heightAnchor.constraint(equalToConstant: 17),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 17),
        ])
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
