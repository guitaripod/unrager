import UIKit

/// The tab bar on iPad, drawn as the system draws it: a rail down the leading
/// edge of a wide window, a floating glass bar at the bottom of a tall or narrow
/// one. It carries the same items as the phone's bar — the chosen tab tinted,
/// unread activity badged — and adds a post button at the foot of the rail,
/// where a sidebar has the room for one.
final class TabChromeBar: UIView {
    enum Form: Equatable {
        case rail
        case bottom
    }

    /// One line of the chrome: a tab, or a place inside a tab that normally
    /// takes several taps to reach. `depth` indents a line under its section,
    /// and a group carries a chevron the reader can fold.
    struct Row {
        var id: String
        var title: String
        var image: UIImage?
        var badge: String?
        var depth = 0
        var isGroup = false
        var isExpanded = false
        var chosen = false
    }

    var onSelect: ((Int) -> Void)?
    var onReselect: ((Int) -> Void)?
    var onCompose: (() -> Void)?
    /// What a long press on the rail's Post offers.
    var composeMenu: (() -> [UIMenuElement])?
    /// A row was tapped: a tab row, a row inside a section, or a section's own
    /// line, which folds and unfolds.
    var onRow: ((String) -> Void)?
    /// The sidebar's own close button, and the way back once it is closed.
    var onToggleSidebar: (() -> Void)?
    /// A drag on the sidebar's trailing edge, as the points it moved since the
    /// last report; the owner keeps the width.
    var onResize: ((CGFloat) -> Void)?

    private(set) var form: Form = .bottom
    private(set) var selectedIndex = 0

    /// The rail's own surface: a solid tint a step away from the page, so the
    /// sidebar and the feed read as two columns rather than one sheet.
    private let panel = UIView()
    private let glass = UIVisualEffectView.glass()
    private let edge = HairlineView()
    private let header = UIView()
    private let wordmark = UILabel()
    private let hideButton = UIButton(type: .system)
    private let grip = UIView()
    private let gripLine = UIView()
    private let stack = UIStackView()
    /// The rail's rows live in a scroll view whose content sits at its bottom,
    /// so the tabs gather just above Post — where the left thumb rests on an
    /// iPad held on its side — and only scroll when they outgrow the rail.
    private let railScroll = UIScrollView()
    private var railStackConstraints: [NSLayoutConstraint] = []
    private var barStackConstraints: [NSLayoutConstraint] = []
    private let postButton = UIButton(configuration: .unragerProminentGlass())
    private var rows: [Row] = []
    private var rowViews: [TabChromeRow] = []
    /// Where the last grip report left the finger, so each report is a step and
    /// not the whole drag again.
    private var lastGripTravel: CGFloat = 0
    private var metrics = PadLayout.metrics(for: .regular)

    private var edgeWidth: NSLayoutConstraint!
    private var headerHeight: NSLayoutConstraint!
    private var wordmarkLeading: NSLayoutConstraint!
    private var stackSide: NSLayoutConstraint!
    private var postHeight: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityContainerType = .semanticGroup
        isAccessibilityElement = false

        panel.backgroundColor = DesignSystem.Color.sidebar
        panel.isUserInteractionEnabled = false
        addManaged(panel)
        panel.pinEdges(to: self)

        glass.isUserInteractionEnabled = false
        glass.clipsToBounds = true
        addManaged(glass)
        glass.pinEdges(to: self)

        header.isHidden = true
        addManaged(header)
        wordmark.text = "Unrager"
        wordmark.font = DesignSystem.Typography.title()
        wordmark.textColor = DesignSystem.Color.label
        wordmark.adjustsFontSizeToFitWidth = true
        wordmark.minimumScaleFactor = 0.7
        header.addManaged(wordmark)
        hideButton.setImage(DesignSystem.icon("sidebar.leading", pointSize: 17), for: .normal)
        hideButton.tintColor = DesignSystem.Color.secondaryLabel
        hideButton.accessibilityLabel = "Hide sidebar"
        hideButton.addAction(UIAction { [weak self] _ in self?.onToggleSidebar?() }, for: .touchUpInside)
        header.addManaged(hideButton)

        addManaged(edge)
        edgeWidth = edge.widthAnchor.constraint(equalToConstant: 0)

        gripLine.backgroundColor = DesignSystem.Color.separator
        gripLine.setFixedCorners(1.5)
        gripLine.alpha = 0
        grip.addManaged(gripLine)
        grip.isHidden = true
        let pan = UIPanGestureRecognizer(target: self, action: #selector(gripPanned))
        grip.addGestureRecognizer(pan)
        addManaged(grip)

        stack.axis = .vertical
        stack.alignment = .fill
        railScroll.showsVerticalScrollIndicator = false
        railScroll.alwaysBounceVertical = false
        railScroll.contentInsetAdjustmentBehavior = .never
        addManaged(railScroll)
        addManaged(stack)

        var post = UIButton.Configuration.unragerProminentGlass()
        post.image = DesignSystem.icon("square.and.pencil", pointSize: 17, weight: .semibold)
        post.imagePadding = 8
        post.title = "Post"
        postButton.configuration = post
        postButton.isHidden = true
        postButton.accessibilityLabel = "New post"
        postButton.addAction(UIAction { [weak self] _ in self?.onCompose?() }, for: .touchUpInside)
        postButton.accessibilityHint = "Touch and hold for more."
        postButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.composeMenu?() ?? [])
            },
        ])
        addManaged(postButton)
        postHeight = postButton.heightAnchor.constraint(equalToConstant: 0)

        wordmarkLeading = wordmark.leadingAnchor.constraint(equalTo: header.leadingAnchor)
        headerHeight = header.heightAnchor.constraint(equalToConstant: 40)
        let content = railScroll.contentLayoutGuide
        let frameGuide = railScroll.frameLayoutGuide
        stackSide = stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10)
        railStackConstraints = [
            stackSide,
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -4),
            stack.topAnchor.constraint(greaterThanOrEqualTo: content.topAnchor, constant: 4),
            content.widthAnchor.constraint(equalTo: frameGuide.widthAnchor),
            content.heightAnchor.constraint(greaterThanOrEqualTo: frameGuide.heightAnchor),
            content.heightAnchor.constraint(equalTo: stack.heightAnchor, constant: 8).priority(.defaultLow),
        ]
        barStackConstraints = [
            stack.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
        ]
        // A window that isn't full screen keeps its controls in its top
        // leading corner, right where the wordmark sits: the header starts
        // after them.
        let corner = layoutGuide(for: .safeArea(cornerAdaptation: .horizontal))
        NSLayoutConstraint.activate([
            edgeWidth,
            header.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
            header.leadingAnchor.constraint(greaterThanOrEqualTo: corner.leadingAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20).priority(.defaultLow),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            header.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 6),
            headerHeight,
            wordmarkLeading,
            wordmark.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            wordmark.trailingAnchor.constraint(lessThanOrEqualTo: hideButton.leadingAnchor, constant: -8),
            hideButton.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            hideButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            hideButton.widthAnchor.constraint(equalToConstant: 32),
            hideButton.heightAnchor.constraint(equalToConstant: 32),
            grip.trailingAnchor.constraint(equalTo: trailingAnchor),
            grip.topAnchor.constraint(equalTo: topAnchor),
            grip.bottomAnchor.constraint(equalTo: bottomAnchor),
            grip.widthAnchor.constraint(equalToConstant: 18),
            gripLine.centerXAnchor.constraint(equalTo: grip.centerXAnchor),
            gripLine.centerYAnchor.constraint(equalTo: grip.centerYAnchor),
            gripLine.widthAnchor.constraint(equalToConstant: 3),
            gripLine.heightAnchor.constraint(equalToConstant: 44),
            edge.trailingAnchor.constraint(equalTo: trailingAnchor),
            edge.topAnchor.constraint(equalTo: topAnchor),
            edge.bottomAnchor.constraint(equalTo: bottomAnchor),
            railScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            railScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            railScroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            railScroll.bottomAnchor.constraint(equalTo: postButton.topAnchor, constant: -14),
            postButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            postButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            postButton.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -16),
            postHeight,
        ])
        install(form: .bottom)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Shows `rows` — the tabs, plus whatever a folded section is showing. The
    /// bar carries no idea of what a row means; the owner does, and hears about
    /// a tap through `onRow`. A bar at the bottom only ever shows the tabs
    /// themselves: a section's places are a sidebar's to hold.
    func setRows(_ newRows: [Row]) {
        rows = newRows
        rebuild()
    }

    /// How many tabs the bar carries, which is what its width is made of.
    var tabCount: Int { rows.filter { $0.depth == 0 }.count }

    private func rebuild() {
        let visible = form == .rail ? rows : rows.filter { $0.depth == 0 }
        if visible.count != rowViews.count {
            for row in rowViews {
                stack.removeArrangedSubview(row)
                row.removeFromSuperview()
            }
            rowViews = visible.map { _ in
                let row = TabChromeRow(form: form, dense: metrics.rail <= 220)
                stack.addArrangedSubview(row)
                return row
            }
        }
        for (view, row) in zip(rowViews, visible) {
            view.onTap = { [weak self] in self?.onRow?(row.id) }
            view.configure(row)
        }
        spaceOutSections(visible)
    }

    /// A little air above each top-level line, so the tabs read as groups rather
    /// than one long list of equally-related places.
    private func spaceOutSections(_ visible: [Row]) {
        guard form == .rail else { return }
        for (index, view) in rowViews.enumerated() {
            let next = visible.indices.contains(index + 1) ? visible[index + 1] : nil
            let gap: CGFloat = next?.depth == 0 ? 10 : 0
            stack.setCustomSpacing(gap, after: view)
        }
    }

    /// Switches between the rail and the bar, taking the window's measurements
    /// with it; returns whether anything moved, so the caller only animates a
    /// real change.
    @discardableResult
    func apply(form newForm: Form, metrics newMetrics: PadLayout.Metrics) -> Bool {
        let resized = newMetrics != metrics
        metrics = newMetrics
        guard newForm != form else {
            if resized { applyDensity() }
            return false
        }
        install(form: newForm)
        return true
    }

    private func install(form newForm: Form) {
        form = newForm
        let rail = newForm == .rail
        glass.setFixedCorners(rail ? 0 : metrics.barHeight / 2)
        edge.isHidden = !rail
        edgeWidth.constant = rail ? 1 / max(1, traitCollection.displayScale) : 0
        header.isHidden = !rail
        grip.isHidden = !rail
        panel.isHidden = !rail
        glass.isHidden = rail
        postButton.isHidden = !rail
        railScroll.isHidden = !rail
        NSLayoutConstraint.deactivate(railStackConstraints + barStackConstraints)
        stack.removeFromSuperview()
        if rail {
            railScroll.addManaged(stack)
        } else {
            addManaged(stack)
        }
        NSLayoutConstraint.activate(rail ? railStackConstraints : barStackConstraints)
        postHeight.constant = rail ? 50 : 0
        if rail {
            stack.axis = .vertical
            stack.distribution = .fill
        } else {
            stack.axis = .horizontal
            stack.distribution = .fillEqually
        }
        for row in rowViews { row.form = newForm }
        applyDensity()
        rebuild()
    }

    /// The rail's own spacing: a mini's 208 points hold the same words as a
    /// 13-inch window's 280, so its rows sit tighter and its title is a size
    /// down rather than clipped or wrapped.
    private func applyDensity() {
        let dense = metrics.rail <= 220
        stack.spacing = 2
        stackSide.constant = dense ? 8 : 10
        wordmarkLeading.constant = dense ? -4 : 0
        wordmark.font = .systemFont(ofSize: (dense ? 18 : 22) * DesignSystem.Typography.scale, weight: .bold)
        headerHeight.constant = dense ? 34 : 40
        for row in rowViews { row.dense = dense }
    }

    @objc private func gripPanned(_ gesture: UIPanGestureRecognizer) {
        let travelled = gesture.translation(in: superview).x
        switch gesture.state {
        case .began:
            gripLine.alpha = 1
            lastGripTravel = 0
        case .changed:
            gripLine.alpha = 1
            onResize?(travelled - lastGripTravel)
            lastGripTravel = travelled
        default:
            gripLine.alpha = 0
            lastGripTravel = 0
        }
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
    var onTap: (() -> Void)?

    private let button = UIButton(configuration: .plain())
    private let chevron = UIImageView()
    private let badge = BadgeCapsule()
    private var row = TabChromeBar.Row(id: "", title: "")
    private var badgeConstraints: [NSLayoutConstraint] = []
    private var chevronConstraints: [NSLayoutConstraint] = []

    var form: TabChromeBar.Form = .rail {
        didSet {
            guard oldValue != form else { return }
            build()
        }
    }

    /// A mini's rail is narrow enough that every row has to give a little.
    var dense = false {
        didSet {
            guard oldValue != dense else { return }
            build()
        }
    }

    init(form: TabChromeBar.Form, dense: Bool) {
        self.form = form
        self.dense = dense
        super.init(frame: .zero)
        addManaged(button)
        button.pinEdges(to: self)
        button.addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .touchUpInside)
        addManaged(badge)
        badge.isUserInteractionEnabled = false
        chevron.tintColor = DesignSystem.Color.secondaryLabel
        chevron.contentMode = .center
        addManaged(chevron)
        cheerPlacement()
        build()
    }

    private func cheerPlacement() {
        NSLayoutConstraint.activate([
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 16),
            chevron.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ newRow: TabChromeBar.Row) {
        guard newRow.title != row.title || newRow.badge != row.badge
            || newRow.chosen != row.chosen || newRow.isExpanded != row.isExpanded
            || newRow.depth != row.depth || newRow.image !== row.image else { return }
        row = newRow
        build()
    }

    /// Rebuilds the row around the current form, title and count. Cheap enough
    /// to run on a tab rename and on a rotation; never on a scroll.
    private func build() {
        let rail = form == .rail
        let child = rail && row.depth > 0
        var config = UIButton.Configuration.plain()
        config.title = row.title
        config.image = row.image?.applyingSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: rail ? (child ? (dense ? 14 : 15) : (dense ? 17 : 19)) : 19,
                                        weight: .regular))
        config.imagePlacement = rail ? .leading : .top
        config.titleLineBreakMode = .byTruncatingTail
        config.imagePadding = rail ? (child ? (dense ? 8 : 10) : (dense ? 9 : 12)) : 2
        button.contentHorizontalAlignment = rail ? .leading : .center
        config.contentInsets = rail
            ? NSDirectionalEdgeInsets(top: dense ? 8 : (child ? 7 : 10),
                                      leading: child ? (dense ? 30 : 38) : (dense ? 9 : 12),
                                      bottom: dense ? 8 : (child ? 7 : 10), trailing: 30)
            : NSDirectionalEdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var out = incoming
            out.font = rail
                ? (child ? DesignSystem.Typography.handle() : DesignSystem.Typography.rowName())
                : DesignSystem.Typography.tabLabel()
            return out
        }
        config.background.cornerRadius = rail ? 12 : 16
        button.configuration = config
        button.accessibilityLabel = row.badge.map { "\(row.title), \($0) new" } ?? row.title
        chevron.isHidden = !(rail && row.isGroup)
        chevron.image = DesignSystem.icon(row.isExpanded ? "chevron.down" : "chevron.right",
                                          pointSize: 11, weight: .semibold)
        badge.text = row.badge
        NSLayoutConstraint.deactivate(badgeConstraints)
        badgeConstraints = rail
            ? [badge.centerYAnchor.constraint(equalTo: centerYAnchor),
               badge.trailingAnchor.constraint(equalTo: trailingAnchor,
                                               constant: row.isGroup ? -34 : -12)]
            : [badge.centerXAnchor.constraint(equalTo: centerXAnchor, constant: 15),
               badge.topAnchor.constraint(equalTo: topAnchor, constant: 2)]
        NSLayoutConstraint.activate(badgeConstraints)
        style()
    }

    private func style() {
        var config = button.configuration ?? .plain()
        config.baseForegroundColor = row.chosen ? DesignSystem.Color.accent : DesignSystem.Color.label
        // One selection is filled — the tab itself. A place inside it is marked
        // in the accent colour alone, so a sidebar never shows two filled rows.
        config.background.backgroundColor = row.chosen && form == .rail && row.depth == 0
            ? DesignSystem.Color.accent.withAlphaComponent(0.16) : .clear
        button.configuration = config
        button.accessibilityTraits = row.chosen ? [.button, .selected] : .button
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
