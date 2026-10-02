import UIKit
import UnragerKit

/// The Recent posts card in a profile's header: what the last posts added up to
/// (views, likes, reposts, replies) and the one that did best, which opens when
/// tapped.
final class ProfileInsightsView: UIView {
    var onTapTop: ((String) -> Void)?

    private let titleLabel = UILabel()
    private let tiles = UIStackView()
    private let topButton = UIButton(type: .system)
    private let topLabel = UILabel()
    private let topMetric = UILabel()
    private var topID: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = DesignSystem.Color.surface
        layer.cornerRadius = DesignSystem.Radius.card
        layer.cornerCurve = .continuous

        titleLabel.font = DesignSystem.Typography.system(13, weight: .semibold)
        titleLabel.textColor = DesignSystem.Color.secondaryLabel
        tiles.distribution = .fillEqually
        tiles.spacing = DesignSystem.Spacing.s

        let rule = HairlineView()
        topLabel.font = DesignSystem.Typography.handle()
        topLabel.textColor = DesignSystem.Color.label
        topLabel.numberOfLines = 2
        topMetric.font = DesignSystem.Typography.metric()
        topMetric.textColor = DesignSystem.Color.secondaryLabel
        let chevron = UIImageView(image: DesignSystem.icon("chevron.right", pointSize: 12, weight: .semibold))
        chevron.tintColor = DesignSystem.Color.tertiaryLabel
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        let topTitle = UILabel()
        topTitle.font = DesignSystem.Typography.system(12, weight: .semibold)
        topTitle.textColor = DesignSystem.Color.accent
        topTitle.text = "TOP POST"
        let topText = UIStackView(arrangedSubviews: [topTitle, topLabel, topMetric])
        topText.axis = .vertical
        topText.spacing = 2
        topText.isUserInteractionEnabled = false
        let topRow = UIStackView(arrangedSubviews: [topText, chevron])
        topRow.alignment = .center
        topRow.spacing = DesignSystem.Spacing.s
        topRow.isUserInteractionEnabled = false
        topRow.translatesAutoresizingMaskIntoConstraints = false
        topButton.addSubview(topRow)
        topButton.addAction(UIAction { [weak self] _ in
            guard let id = self?.topID else { return }
            Haptics.selection()
            self?.onTapTop?(id)
        }, for: .touchUpInside)
        NSLayoutConstraint.activate([
            topRow.topAnchor.constraint(equalTo: topButton.topAnchor),
            topRow.bottomAnchor.constraint(equalTo: topButton.bottomAnchor),
            topRow.leadingAnchor.constraint(equalTo: topButton.leadingAnchor),
            topRow.trailingAnchor.constraint(equalTo: topButton.trailingAnchor),
        ])

        let column = UIStackView(arrangedSubviews: [titleLabel, tiles, rule, topButton])
        column.axis = .vertical
        column.spacing = DesignSystem.Spacing.m
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            topButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(with insights: ProfileInsights) {
        titleLabel.text = "Your last \(insights.postCount) posts"
        tiles.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var stats: [(String, String, String, UIColor)] = []
        if let views = insights.views { stats.append((Format.count(views), "Views", "eye.fill", DesignSystem.Color.secondaryLabel)) }
        stats.append((Format.count(insights.likes), "Likes", "heart.fill", DesignSystem.Color.like))
        stats.append((Format.count(insights.reposts), "Reposts", "arrow.2.squarepath", DesignSystem.Color.retweet))
        stats.append((Format.count(insights.replies), "Replies", "bubble.left.fill", DesignSystem.Color.accent))
        for stat in stats { tiles.addArrangedSubview(makeTile(value: stat.0, caption: stat.1, symbol: stat.2, tint: stat.3)) }
        topID = insights.top.tweetID
        topLabel.text = insights.top.text.trimmingCharacters(in: .whitespacesAndNewlines)
        topMetric.text = insights.top.metric
        topButton.accessibilityLabel = "Top post: \(insights.top.text). \(insights.top.metric)"
        topButton.accessibilityHint = "Opens the post"
    }

    private func makeTile(value: String, caption: String, symbol: String, tint: UIColor) -> UIView {
        let number = UILabel()
        number.font = DesignSystem.Typography.system(22, weight: .bold)
        number.textColor = DesignSystem.Color.label
        number.text = value
        number.adjustsFontSizeToFitWidth = true
        number.minimumScaleFactor = 0.7
        let icon = UIImageView(image: DesignSystem.icon(symbol, pointSize: 10, weight: .bold))
        icon.tintColor = tint
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let label = UILabel()
        label.font = DesignSystem.Typography.caption()
        label.textColor = DesignSystem.Color.secondaryLabel
        label.text = caption
        let captionRow = UIStackView(arrangedSubviews: [icon, label, UIView()])
        captionRow.spacing = 4
        captionRow.alignment = .center
        let tile = UIStackView(arrangedSubviews: [number, captionRow])
        tile.axis = .vertical
        tile.spacing = 2
        tile.isAccessibilityElement = true
        tile.accessibilityLabel = "\(caption): \(value)"
        return tile
    }
}
