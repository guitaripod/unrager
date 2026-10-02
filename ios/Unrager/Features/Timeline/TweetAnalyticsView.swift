import UIKit
import UnragerKit

/// The own-tweet "post analytics" block shown beneath the focal tweet in a
/// thread — a port of the TUI's `analytics_lines`. Lists views, likes, reposts,
/// replies, quotes and bookmarks (each with a tinted SF Symbol), then the
/// engagement rate `(likes+reposts+replies+quotes+bookmarks) / views`. Hidden
/// unless the focal tweet belongs to the signed-in user.
final class TweetAnalyticsView: UIView {
    private let heading = UILabel()
    private let statsGrid = UIStackView()
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

        statsGrid.axis = .vertical
        statsGrid.spacing = DesignSystem.Spacing.s

        rateLabel.font = DesignSystem.Typography.metric()
        rateLabel.textColor = DesignSystem.Color.secondaryLabel
        rateLabel.numberOfLines = 0

        column.axis = .vertical
        column.spacing = DesignSystem.Spacing.s
        column.isLayoutMarginsRelativeArrangement = true
        column.directionalLayoutMargins = .init(top: 12, leading: 14, bottom: 12, trailing: 14)
        column.addArrangedSubview(heading)
        column.addArrangedSubview(statsGrid)
        column.addArrangedSubview(rateLabel)
        addManaged(column)
        column.pinEdges(to: self)
        isAccessibilityElement = true
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: TweetAnalyticsView, _) in
            view.layer.borderColor = DesignSystem.Color.separator.cgColor
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private struct Stat {
        let symbol: String
        let name: String
        let count: Int
        let tint: UIColor
    }

    /// Three figures to a row, so the block wraps at large text sizes instead
    /// of running off the side.
    private static let columns = 3

    func configure(_ tweet: Tweet, visible: Bool) {
        isHidden = !visible
        guard visible else { return }
        statsGrid.arrangedSubviews.forEach { $0.removeFromSuperview() }

        var stats: [Stat] = []
        if let views = tweet.viewCount {
            stats.append(Stat(symbol: "chart.bar", name: "views", count: views, tint: DesignSystem.Color.secondaryLabel))
        }
        stats += [
            Stat(symbol: "heart.fill", name: "likes", count: tweet.likeCount, tint: DesignSystem.Color.like),
            Stat(symbol: "arrow.2.squarepath", name: "reposts", count: tweet.retweetCount, tint: DesignSystem.Color.retweet),
            Stat(symbol: "bubble.left", name: "replies", count: tweet.replyCount, tint: DesignSystem.Color.accent),
            Stat(symbol: "quote.bubble", name: "quotes", count: tweet.quoteCount, tint: DesignSystem.Color.quote),
            Stat(symbol: "bookmark", name: "bookmarks", count: tweet.bookmarkCount, tint: DesignSystem.Color.secondaryLabel),
        ]
        for start in stride(from: 0, to: stats.count, by: Self.columns) {
            let cells = stats[start..<min(start + Self.columns, stats.count)].map(statView)
            let row = UIStackView(arrangedSubviews: cells)
            row.axis = .horizontal
            row.distribution = .fillEqually
            row.spacing = DesignSystem.Spacing.l
            statsGrid.addArrangedSubview(row)
        }

        let engagements = tweet.likeCount + tweet.retweetCount + tweet.replyCount
            + tweet.quoteCount + tweet.bookmarkCount
        if let views = tweet.viewCount, views > 0 {
            let rate = Double(engagements) / Double(views) * 100
            let formatted = rate >= 10 ? String(format: "%.1f%%", rate) : String(format: "%.2f%%", rate)
            rateLabel.text = "Engagement rate \(formatted) · \(Format.count(engagements)) / \(Format.count(views)) views"
            rateLabel.numberOfLines = 0
            rateLabel.isHidden = false
        } else if engagements > 0 {
            rateLabel.text = "\(Format.count(engagements)) total engagements"
            rateLabel.isHidden = false
        } else {
            rateLabel.isHidden = true
        }

        let figures = stats.map { "\(Format.count($0.count)) \($0.name)" }.joined(separator: ", ")
        accessibilityLabel = "Post analytics. \(figures)." + (rateLabel.text.map { " \($0)." } ?? "")
    }

    private func statView(_ stat: Stat) -> UIView {
        let icon = UIImageView(image: DesignSystem.icon(stat.symbol, pointSize: 13))
        icon.tintColor = stat.tint
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let label = UILabel()
        label.text = Format.count(stat.count)
        label.font = DesignSystem.Typography.metric()
        label.textColor = DesignSystem.Color.label
        let row = UIStackView(arrangedSubviews: [icon, label, UIView()])
        row.axis = .horizontal
        row.spacing = 4
        row.alignment = .center
        return row
    }
}
