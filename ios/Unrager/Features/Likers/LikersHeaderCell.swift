import UIKit
import UnragerKit

/// The top of the Liked by list: the post the likes are on, and under it the
/// like count wrapped in a ring that splits the people by how they stand with
/// the viewer, with a legend beside it. The legend row for followers the
/// viewer hasn't followed back wears their faces and, once the list can be
/// narrowed, jumps to them.
final class LikersHeaderCell: UICollectionViewListCell {
    var onOpenPost: (() -> Void)?
    var onShowFollowBack: (() -> Void)?

    private let card = LikedPostCardView()
    private let ring = HeartRingView()
    private let titleLabel = UILabel()
    private let scopeLabel = UILabel()
    private let legend = UIStackView()
    private var rows: [Standing: LegendRow] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundConfiguration = .clear()
        isUserInteractionEnabled = true

        card.onOpen = { [weak self] in self?.onOpenPost?() }

        titleLabel.font = DesignSystem.Typography.system(22, weight: .bold)
        titleLabel.textColor = DesignSystem.Color.label
        titleLabel.accessibilityTraits = .header
        scopeLabel.font = DesignSystem.Typography.metric()
        scopeLabel.textColor = DesignSystem.Color.secondaryLabel
        scopeLabel.numberOfLines = 2

        legend.axis = .vertical
        legend.spacing = 2
        for standing in [Standing.mutual, .followsYou, .youFollow, .stranger] {
            let row = LegendRow(standing: standing)
            rows[standing] = row
            legend.addArrangedSubview(row)
        }
        rows[.followsYou]?.addAction(UIAction { [weak self] _ in self?.onShowFollowBack?() }, for: .touchUpInside)

        let side = UIStackView(arrangedSubviews: [titleLabel, scopeLabel, legend])
        side.axis = .vertical
        side.spacing = DesignSystem.Spacing.xs
        side.setCustomSpacing(DesignSystem.Spacing.s, after: scopeLabel)

        let figures = UIStackView(arrangedSubviews: [ring, side])
        figures.alignment = .center
        figures.spacing = DesignSystem.Spacing.l

        let root = UIStackView(arrangedSubviews: [card, figures])
        root.axis = .vertical
        root.spacing = DesignSystem.Spacing.l + 2
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)
        let bottom = root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -DesignSystem.Spacing.l)
        bottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: contentView.topAnchor, constant: DesignSystem.Spacing.s),
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: DesignSystem.Spacing.l),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -DesignSystem.Spacing.l),
            bottom,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        card.prepareForReuse()
        onOpenPost = nil
        onShowFollowBack = nil
    }

    /// Draws `post` and `summary` for a row `width` wide. `offersLenses` makes
    /// the follow-back row a button. `reveal` is for the first time the people
    /// are known: the ring sweeps in and the counts climb to their figures.
    /// While the first page loads the legend holds its place with bars, so
    /// nothing moves when the figures arrive.
    func configure(post: LikedPost, summary: LikersSummary, width: CGFloat, offersLenses: Bool, reveal: Bool) {
        card.isHidden = post.isEmpty
        card.configure(post: post, contentWidth: LikedPostCardView.contentWidth(rowWidth: width))

        let tally = summary.tally
        let placeholder = summary.isPlaceholder
        ring.configure(likeCount: summary.likeCount, tally: tally, loading: placeholder, reveal: reveal,
                       spoken: summary.spokenLegend)
        setScope(summary.scope)
        titleLabel.text = summary.likeCount.map(LikersSummary.likesTitle)
        titleLabel.isHidden = tally.hasStandings || placeholder || summary.likeCount == nil
        legend.isHidden = !(tally.hasStandings || placeholder)
        for (index, standing) in [Standing.mutual, .followsYou, .youFollow, .stranger].enumerated() {
            rows[standing]?.configure(
                count: placeholder ? nil : tally.count(of: standing),
                faces: standing == .followsYou ? summary.followBackFaces : [],
                isButton: standing == .followsYou && offersLenses && tally.followsYou > 0,
                reveal: reveal, delay: 0.12 + Double(index) * 0.07)
        }
    }

    /// Swaps the scope line with a quick dissolve once the cell is on screen.
    private func setScope(_ text: String) {
        guard scopeLabel.text != text else { return }
        guard window != nil, !UIAccessibility.isReduceMotionEnabled else {
            scopeLabel.text = text
            return
        }
        UIView.transition(with: scopeLabel, duration: 0.22, options: [.transitionCrossDissolve, .allowUserInteraction]) {
            self.scopeLabel.text = text
        }
    }
}

/// One line of the legend: a dot in the standing's colour, how many, and what
/// they are. The follow-back line is set in amber type and is the only one that
/// is ever a button.
private final class LegendRow: UIControl {
    private let dot = UIView()
    private let countLabel = CountingLabel()
    private let placeholder = UIView()
    private let titleLabel = UILabel()
    private let faces = FacePileView()
    private let chevron = UIImageView(image: DesignSystem.icon("chevron.right", pointSize: 10, weight: .bold))
    private let standing: Standing

    init(standing: Standing) {
        self.standing = standing
        super.init(frame: .zero)
        let emphasised = standing == .followsYou
        dot.backgroundColor = standing.tint
        dot.layer.cornerRadius = 5
        dot.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = UIFont.monospacedDigitSystemFont(
            ofSize: 14 * DesignSystem.Typography.scale, weight: .bold)
        countLabel.textColor = emphasised ? standing.tint : DesignSystem.Color.label
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        placeholder.backgroundColor = .secondarySystemFill
        placeholder.layer.cornerRadius = 5
        placeholder.layer.cornerCurve = .continuous
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = Self.title(for: standing)
        titleLabel.font = DesignSystem.Typography.system(14, weight: emphasised ? .semibold : .regular)
        titleLabel.textColor = emphasised ? DesignSystem.Color.label : DesignSystem.Color.secondaryLabel
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        chevron.tintColor = standing.tint
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        faces.setContentHuggingPriority(.required, for: .horizontal)
        faces.setContentCompressionResistancePriority(.required, for: .horizontal)

        let spacer = UIView()
        spacer.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
        let stack = UIStackView(arrangedSubviews: [dot, countLabel, titleLabel, spacer, faces, chevron])
        stack.spacing = DesignSystem.Spacing.s
        stack.alignment = .center
        stack.isUserInteractionEnabled = false
        stack.setCustomSpacing(DesignSystem.Spacing.xs, after: faces)
        addManaged(stack)
        stack.pinEdges(to: self)
        addSubview(placeholder)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
            countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 24),
            placeholder.leadingAnchor.constraint(equalTo: countLabel.leadingAnchor),
            placeholder.centerYAnchor.constraint(equalTo: countLabel.centerYAnchor),
            placeholder.widthAnchor.constraint(equalToConstant: 18),
            placeholder.heightAnchor.constraint(equalToConstant: 10),
        ])
        placeholder.isHidden = true
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }

    static func title(for standing: Standing) -> String {
        switch standing {
        case .mutual: return "Mutuals"
        case .followsYou: return "Follow back"
        case .youFollow: return "Only you follow"
        case .stranger: return "No connection"
        }
    }

    private var isPlaceholder = false

    /// Shows `count`, or a pulsing bar where it will be when it is nil. `reveal`
    /// climbs the figure from zero, `delay` after the row appears.
    func configure(count: Int?, faces people: [UserRow], isButton: Bool, reveal: Bool, delay: TimeInterval) {
        setPlaceholder(count == nil)
        if let count {
            if reveal {
                countLabel.setValue(count, from: 0, delay: delay)
            } else {
                countLabel.setValue(count)
            }
        }
        setFaces(people, delay: reveal ? delay : 0)
        chevron.isHidden = !isButton
        isEnabled = isButton
        isUserInteractionEnabled = isButton
        let spokenCount = count.map { $0.formatted() } ?? "Loading"
        accessibilityLabel = "\(spokenCount) \(Self.title(for: standing).lowercased())"
        accessibilityTraits = isButton ? .button : .staticText
        accessibilityHint = isButton ? "Shows only these people" : nil
    }

    /// A bar that breathes in place of the count while the people load; when
    /// they land it dissolves into the figure.
    private func setPlaceholder(_ on: Bool) {
        guard on != isPlaceholder || (on && placeholder.isHidden) else { return }
        isPlaceholder = on
        let animated = window != nil && !UIAccessibility.isReduceMotionEnabled
        placeholder.layer.removeAnimation(forKey: "breathe")
        if on {
            countLabel.alpha = 0
            placeholder.isHidden = false
            placeholder.alpha = 1
            if animated {
                let breathe = CABasicAnimation(keyPath: "opacity")
                breathe.fromValue = 0.4
                breathe.toValue = 1
                breathe.duration = 0.8
                breathe.autoreverses = true
                breathe.repeatCount = .infinity
                breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                placeholder.layer.add(breathe, forKey: "breathe")
            }
            return
        }
        let finish = {
            self.placeholder.alpha = 0
            self.countLabel.alpha = 1
        }
        guard animated else {
            finish()
            placeholder.isHidden = true
            return
        }
        UIView.animate(withDuration: 0.2, delay: 0, options: [.allowUserInteraction], animations: finish) { _ in
            if !self.isPlaceholder { self.placeholder.isHidden = true }
        }
    }

    /// Fades the faces in when they first appear.
    private func setFaces(_ people: [UserRow], delay: TimeInterval) {
        let appearing = faces.isHidden && !people.isEmpty
        faces.configure(people: people, tint: standing.tint)
        faces.isHidden = people.isEmpty
        guard appearing, window != nil, !UIAccessibility.isReduceMotionEnabled else {
            faces.alpha = 1
            return
        }
        faces.alpha = 0
        faces.transform = CGAffineTransform(translationX: 10, y: 0)
        UIView.animate(withDuration: 0.4, delay: delay, usingSpringWithDamping: 0.85, initialSpringVelocity: 0,
                       options: [.allowUserInteraction]) {
            self.faces.alpha = 1
            self.faces.transform = .identity
        }
    }
}
