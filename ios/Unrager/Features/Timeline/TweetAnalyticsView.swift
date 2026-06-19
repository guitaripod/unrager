import UIKit
import UnragerKit

/// The own-tweet "post analytics" block shown beneath the focal tweet in a
/// thread — a port of the TUI's `analytics_lines`. Lists views, likes, reposts,
/// replies, quotes and bookmarks (each with a tinted SF Symbol), then the
/// engagement rate `(likes+reposts+replies+quotes+bookmarks) / views`. Hidden
/// unless the focal tweet belongs to the signed-in user.
final class TweetAnalyticsView: UIView {
    private let heading = UILabel()
    private let statsRow = UIStackView()
    private let rateLabel = UILabel()
    private let column = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = DesignSystem.Radius.control
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = DesignSystem.Color.separator.cgColor

        heading.text = "Post analytics"
        heading.font = DesignSystem.Typography.caption()
        heading.textColor = DesignSystem.Color.secondaryLabel

        statsRow.axis = .horizontal
        statsRow.spacing = DesignSystem.Spacing.l
        statsRow.alignment = .center
        statsRow.distribution = .fillProportionally

        rateLabel.font = DesignSystem.Typography.metric()
        rateLabel.textColor = DesignSystem.Color.secondaryLabel
        rateLabel.numberOfLines = 1

        column.axis = .vertical
        column.spacing = DesignSystem.Spacing.s
        column.isLayoutMarginsRelativeArrangement = true
        column.directionalLayoutMargins = .init(top: 12, leading: 14, bottom: 12, trailing: 14)
        column.addArrangedSubview(heading)
        column.addArrangedSubview(statsRow)
        column.addArrangedSubview(rateLabel)
        addManaged(column)
        column.pinEdges(to: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ tweet: Tweet, visible: Bool) {
        isHidden = !visible
        guard visible else { return }
        statsRow.arrangedSubviews.forEach { $0.removeFromSuperview() }

        if let views = tweet.viewCount {
            statsRow.addArrangedSubview(stat("chart.bar", count: views, tint: DesignSystem.Color.secondaryLabel))
        }
        statsRow.addArrangedSubview(stat("heart.fill", count: tweet.likeCount, tint: DesignSystem.Color.like))
        statsRow.addArrangedSubview(stat("arrow.2.squarepath", count: tweet.retweetCount, tint: DesignSystem.Color.retweet))
        statsRow.addArrangedSubview(stat("bubble.left", count: tweet.replyCount, tint: DesignSystem.Color.accent))
        statsRow.addArrangedSubview(stat("quote.bubble", count: tweet.quoteCount, tint: DesignSystem.Color.quote))
        statsRow.addArrangedSubview(stat("bookmark", count: tweet.bookmarkCount, tint: DesignSystem.Color.secondaryLabel))

        let engagements = tweet.likeCount + tweet.retweetCount + tweet.replyCount
            + tweet.quoteCount + tweet.bookmarkCount
        if let views = tweet.viewCount, views > 0 {
            let rate = Double(engagements) / Double(views) * 100
            let formatted = rate >= 10 ? String(format: "%.1f%%", rate) : String(format: "%.2f%%", rate)
            rateLabel.text = "Engagement rate \(formatted) · \(Format.count(engagements)) / \(Format.count(views)) views"
            rateLabel.isHidden = false
        } else if engagements > 0 {
            rateLabel.text = "\(Format.count(engagements)) total engagements"
            rateLabel.isHidden = false
        } else {
            rateLabel.isHidden = true
        }
    }

    private func stat(_ symbol: String, count: Int, tint: UIColor) -> UIView {
        let icon = UIImageView(image: DesignSystem.icon(symbol, pointSize: 13))
        icon.tintColor = tint
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let label = UILabel()
        label.text = Format.count(count)
        label.font = DesignSystem.Typography.metric()
        label.textColor = DesignSystem.Color.label
        let row = UIStackView(arrangedSubviews: [icon, label])
        row.axis = .horizontal
        row.spacing = 4
        row.alignment = .center
        return row
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        layer.borderColor = DesignSystem.Color.separator.cgColor
    }
}
