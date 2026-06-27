import UIKit
import UnragerKit

/// A tweet poll rendered as labeled horizontal bars: each option shows its
/// label, a fill proportional to its share of the total vote, and a percentage;
/// a footer gives the total count plus "Final results" or "ends …". The winning
/// option is accented. No images, no network — pure layout from the decoded
/// `PollOption`s.
final class PollView: UIView {
    private let optionsStack = UIStackView()
    private let footer = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        optionsStack.axis = .vertical
        optionsStack.spacing = DesignSystem.Spacing.s

        footer.font = DesignSystem.Typography.caption()
        footer.textColor = DesignSystem.Color.secondaryLabel
        footer.numberOfLines = 1

        let column = UIStackView(arrangedSubviews: [optionsStack, footer])
        column.axis = .vertical
        column.spacing = DesignSystem.Spacing.s
        addManaged(column)
        column.pinEdges(to: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(options: [PollOption], endsAt: Date?, countsFinal: Bool) {
        optionsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let total = max(1, options.reduce(0) { $0 + $1.count })
        let leader = options.max(by: { $0.count < $1.count })?.count
        for option in options {
            let fraction = Double(option.count) / Double(total)
            let isLeader = option.count == leader
            optionsStack.addArrangedSubview(PollBar(label: option.label, fraction: fraction, leading: isLeader))
        }
        footer.text = Self.footerText(total: options.reduce(0) { $0 + $1.count }, endsAt: endsAt, countsFinal: countsFinal)

        isAccessibilityElement = true
        accessibilityLabel = "Poll. " + options.map {
            "\($0.label), \(Int((Double($0.count) / Double(total) * 100).rounded())) percent"
        }.joined(separator: ". ")
    }

    /// Mirrors the TUI's `poll_footer`: "<n> votes · 5h left" while open,
    /// "· ended" once the clock runs out, "· final" once results are locked.
    private static func footerText(total: Int, endsAt: Date?, countsFinal: Bool) -> String {
        let votes = "\(Format.count(total)) vote\(total == 1 ? "" : "s")"
        if countsFinal { return "\(votes) · final" }
        if let endsAt {
            let remaining = endsAt.timeIntervalSinceNow
            if remaining <= 0 { return "\(votes) · ended" }
            return "\(votes) · \(Self.countdown(remaining)) left"
        }
        return votes
    }

    /// Minute-granularity countdown capped at days ("5h", "3d", "12m"), matching
    /// the TUI's `poll_footer` — never overflows into an absolute date the way
    /// the date-capable `Format.relativeTime` does past a week out.
    private static func countdown(_ remaining: TimeInterval) -> String {
        let mins = max(0, Int(remaining / 60))
        if mins >= 24 * 60 { return "\(mins / (24 * 60))d" }
        if mins >= 60 { return "\(mins / 60)h" }
        return "\(mins)m"
    }
}

/// One poll option row: label + percent over a proportional fill track.
private final class PollBar: UIView {
    private let fill = UIView()
    private let labelView = UILabel()
    private let percentView = UILabel()
    private let fraction: Double

    init(label: String, fraction: Double, leading: Bool) {
        self.fraction = fraction
        super.init(frame: .zero)
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        backgroundColor = DesignSystem.Color.surface

        fill.backgroundColor = (leading ? DesignSystem.Color.accent : DesignSystem.Color.secondaryLabel)
            .withAlphaComponent(leading ? 0.30 : 0.18)
        fill.layer.cornerRadius = 8
        fill.layer.cornerCurve = .continuous
        addManaged(fill)

        labelView.text = label
        labelView.font = leading ? DesignSystem.Typography.name() : DesignSystem.Typography.handle()
        labelView.textColor = DesignSystem.Color.label
        labelView.numberOfLines = 1

        percentView.text = "\(Int((fraction * 100).rounded()))%"
        percentView.font = DesignSystem.Typography.metric()
        percentView.textColor = DesignSystem.Color.secondaryLabel
        percentView.setContentHuggingPriority(.required, for: .horizontal)

        addManaged(labelView)
        addManaged(percentView)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),
            fill.leadingAnchor.constraint(equalTo: leadingAnchor),
            fill.topAnchor.constraint(equalTo: topAnchor),
            fill.bottomAnchor.constraint(equalTo: bottomAnchor),
            fillWidth,
            labelView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            labelView.centerYAnchor.constraint(equalTo: centerYAnchor),
            percentView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            percentView.centerYAnchor.constraint(equalTo: centerYAnchor),
            labelView.trailingAnchor.constraint(lessThanOrEqualTo: percentView.leadingAnchor, constant: -8),
        ])
    }

    private lazy var fillWidth: NSLayoutConstraint =
        fill.widthAnchor.constraint(equalTo: widthAnchor, multiplier: max(0.001, fraction))

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
