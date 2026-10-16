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
    /// the follow-back row a button.
    func configure(post: LikedPost, summary: LikersSummary, width: CGFloat, offersLenses: Bool) {
        card.isHidden = post.isEmpty
        card.configure(post: post, contentWidth: LikedPostCardView.contentWidth(rowWidth: width))

        let tally = summary.tally
        ring.configure(likeCount: summary.likeCount, tally: tally, spoken: summary.spokenLegend)
        scopeLabel.text = summary.scope
        titleLabel.text = summary.likeCount.map(LikersSummary.likesTitle)
        titleLabel.isHidden = tally.hasStandings || summary.likeCount == nil
        legend.isHidden = !tally.hasStandings
        for (standing, row) in rows {
            row.configure(count: tally.count(of: standing), faces: standing == .followsYou ? summary.followBackFaces : [],
                          isButton: standing == .followsYou && offersLenses && tally.followsYou > 0)
        }
    }
}

/// One line of the legend: a dot in the standing's colour, how many, and what
/// they are. The follow-back line is set in amber type and is the only one that
/// is ever a button.
private final class LegendRow: UIControl {
    private let dot = UIView()
    private let countLabel = UILabel()
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
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
        ])
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

    func configure(count: Int, faces people: [UserRow], isButton: Bool) {
        countLabel.text = count.formatted()
        faces.configure(people: people, tint: standing.tint)
        faces.isHidden = people.isEmpty
        chevron.isHidden = !isButton
        isEnabled = isButton
        isUserInteractionEnabled = isButton
        accessibilityLabel = "\(count.formatted()) \(Self.title(for: standing).lowercased())"
        accessibilityTraits = isButton ? .button : .staticText
        accessibilityHint = isButton ? "Shows only these people" : nil
    }
}
