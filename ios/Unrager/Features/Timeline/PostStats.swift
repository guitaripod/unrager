import UIKit
import UnragerKit

/// What a post's stats strip shows, worked out from the post and, for the
/// signed-in account's own posts, X's analytics.
enum PostStatsContent: Equatable {
    /// A post anyone can see: the public counts, as rates.
    case publicCounts
    /// An own post whose analytics are on their way.
    case loading
    /// An own post with X's own numbers.
    case analytics(PostAnalytics)
}

/// One figure in the strip: a value over a short caption.
struct PostStatCell: Equatable {
    let value: String
    let caption: String
    /// Whether tapping the figure lists the posts quoting this one.
    var opensQuotes = false
}

/// The figures a strip lists, as plain data so the choice of what to show and
/// how to round it can be tested without a view.
enum PostStatsModel {
    static func cells(for tweet: Tweet, content: PostStatsContent) -> [PostStatCell] {
        switch content {
        case .publicCounts, .loading:
            return publicCells(for: tweet)
        case let .analytics(analytics):
            return analyticsCells(analytics)
        }
    }

    /// Quotes (the one count the action bar doesn't show), and what share of
    /// the views turned into each kind of engagement.
    private static func publicCells(for tweet: Tweet) -> [PostStatCell] {
        var cells = [PostStatCell(value: Format.count(tweet.quoteCount), caption: "Quotes",
                                  opensQuotes: tweet.quoteCount > 0)]
        guard let views = tweet.viewCount, views > 0 else { return cells }
        let engagements = tweet.likeCount + tweet.retweetCount + tweet.replyCount + tweet.quoteCount
            + tweet.bookmarkCount
        cells.append(PostStatCell(value: percent(Double(engagements) / Double(views)), caption: "Engagement"))
        cells.append(PostStatCell(value: percent(Double(tweet.likeCount) / Double(views)), caption: "Like rate"))
        cells.append(PostStatCell(value: percent(Double(tweet.retweetCount) / Double(views)), caption: "Repost rate"))
        return cells
    }

    /// X's own numbers: impressions, engagements with their rate, detail
    /// expands and profile visits always; link clicks and follows only once
    /// they are anything but zero, so the row stays short.
    private static func analyticsCells(_ analytics: PostAnalytics) -> [PostStatCell] {
        var cells = [
            PostStatCell(value: Format.count(analytics.impressions), caption: "Impressions"),
            PostStatCell(value: Format.count(analytics.engagements)
                + (analytics.engagementRate.map { " · " + percent($0) } ?? ""), caption: "Engagements"),
            PostStatCell(value: Format.count(analytics.detailExpands), caption: "Expands"),
            PostStatCell(value: Format.count(analytics.profileVisits), caption: "Profile visits"),
        ]
        if analytics.linkClicks > 0 {
            cells.append(PostStatCell(value: Format.count(analytics.linkClicks), caption: "Link clicks"))
        }
        if analytics.follows > 0 {
            cells.append(PostStatCell(value: Format.count(analytics.follows), caption: "Follows"))
        }
        return cells
    }

    /// A share as a percentage with one decimal under 10% and none above, "0%"
    /// for nothing and "<0.1%" for a sliver.
    static func percent(_ share: Double) -> String {
        let value = share * 100
        if value <= 0 { return "0%" }
        if value < 0.1 { return "<0.1%" }
        if value < 10 { return String(format: "%.1f%%", value) }
        return String(format: "%.0f%%", value)
    }
}

/// Remembers X's analytics for the account's own posts for a few minutes, so
/// opening a post's stats twice costs one request, and says so when it learns
/// something.
@MainActor
final class PostStatsStore {
    static let shared = PostStatsStore(fetch: fetchFromServer, now: currentDate)

    private static func fetchFromServer(_ id: String) async throws -> PostAnalytics? {
        try await AppEnvironment.shared.api.postAnalytics(tweetID: id)
    }

    private nonisolated static func currentDate() -> Date { Date() }

    enum Entry: Equatable {
        case loading
        case loaded(PostAnalytics)
        /// X sent none for this post.
        case unavailable
        /// The request failed (offline, or an error from the server); the strip
        /// shows the public counts until a retry is due.
        case failed(Date)
    }

    private static let freshFor: TimeInterval = 300
    /// How long a failed request rests before a redraw may ask again, so a
    /// failure can't turn every re-render of the row into another request.
    static let retryAfter: TimeInterval = 60

    private let fetch: @MainActor (String) async throws -> PostAnalytics?
    private let now: () -> Date
    private var entries: [String: (entry: Entry, at: Date)] = [:]

    init(fetch: @escaping @MainActor (String) async throws -> PostAnalytics?, now: @escaping () -> Date) {
        self.fetch = fetch
        self.now = now
    }

    func entry(for id: String) -> Entry? {
        guard let stored = entries[id] else { return nil }
        let age = now().timeIntervalSince(stored.at)
        switch stored.entry {
        case .loading: return .loading
        case .failed: return age < Self.retryAfter ? stored.entry : nil
        case .loaded, .unavailable: return age < Self.freshFor ? stored.entry : nil
        }
    }

    /// Lets the next draw ask again for a post whose last request failed — the
    /// user opening its stats is a fresh request, not a redraw.
    func retryIfFailed(_ id: String) {
        guard case .failed? = entries[id]?.entry else { return }
        entries[id] = nil
    }

    /// Fetches the analytics for `id` unless they are fresh, on their way or
    /// recently failed; `changed` runs once an answer lands.
    func load(_ id: String, changed: @escaping @MainActor () -> Void) {
        guard entry(for: id) == nil else { return }
        entries[id] = (.loading, now())
        Task { [weak self, fetch] in
            let result: Entry
            do {
                result = try await fetch(id).map(Entry.loaded) ?? .unavailable
            } catch {
                AppLogger.shared.warn("post analytics failed for \(id): \(error)", category: .timeline)
                guard let self else { return }
                let failedAt = self.now()
                self.entries[id] = (.failed(failedAt), failedAt)
                changed()
                return
            }
            guard let self else { return }
            self.entries[id] = (result, self.now())
            changed()
        }
    }
}

/// The compact strip under a post's action bar: a row of figures, and for an
/// own post a small bar chart of its first 48 hours of impressions.
final class PostStatsView: UIStackView {
    private let figures = UIStackView()
    private let chart = SparklineView()
    private let chartCaption = UILabel()
    private let chartRow = UIStackView()
    /// Fired by a tap on the "Quotes" figure when the post has any.
    var onTapQuotes: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        axis = .vertical
        spacing = DesignSystem.Spacing.xs
        isLayoutMarginsRelativeArrangement = true
        directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
        figures.axis = .horizontal
        figures.distribution = .fillProportionally
        figures.spacing = DesignSystem.Spacing.m
        chartCaption.font = DesignSystem.Typography.system(10, weight: .regular)
        chartCaption.textColor = DesignSystem.Color.tertiaryLabel
        chartCaption.text = "First 48 hours"
        chartCaption.setContentHuggingPriority(.required, for: .horizontal)
        chart.heightAnchor.constraint(equalToConstant: 18).isActive = true
        chartRow.axis = .horizontal
        chartRow.spacing = DesignSystem.Spacing.s
        chartRow.alignment = .bottom
        chartRow.addArrangedSubview(chart)
        chartRow.addArrangedSubview(chartCaption)
        addArrangedSubview(figures)
        addArrangedSubview(chartRow)
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    func configure(tweet: Tweet, content: PostStatsContent) {
        let cells = PostStatsModel.cells(for: tweet, content: content)
        figures.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for cell in cells { figures.addArrangedSubview(makeCell(cell, dimmed: content == .loading)) }
        figures.addArrangedSubview(UIView())
        if case let .analytics(analytics) = content, analytics.hourlyImpressions.count >= 6 {
            chart.values = analytics.hourlyImpressions
            chartRow.isHidden = false
        } else {
            chartRow.isHidden = true
        }
    }

    private func makeCell(_ cell: PostStatCell, dimmed: Bool) -> UIView {
        let value = UILabel()
        value.text = cell.value
        value.font = DesignSystem.Typography.system(14, weight: .semibold)
        value.textColor = dimmed ? DesignSystem.Color.tertiaryLabel
            : cell.opensQuotes ? DesignSystem.Color.accent : DesignSystem.Color.label
        let caption = UILabel()
        caption.text = cell.caption
        caption.font = DesignSystem.Typography.system(11, weight: .regular)
        caption.textColor = DesignSystem.Color.secondaryLabel
        let column = UIStackView(arrangedSubviews: [value, caption])
        column.axis = .vertical
        column.spacing = 0
        if cell.opensQuotes {
            column.isUserInteractionEnabled = true
            column.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(quotesTapped)))
        }
        return column
    }

    @objc private func quotesTapped() {
        Haptics.selection()
        onTapQuotes?()
    }
}

/// A row of thin bars, one per value, tallest for the largest.
final class SparklineView: UIView {
    var values: [Int] = [] {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: SparklineView, _) in
            view.setNeedsDisplay()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let peak = values.max(), peak > 0, !values.isEmpty else { return }
        let gap: CGFloat = 1.5
        let width = min(5, max(1, (rect.width - gap * CGFloat(values.count - 1)) / CGFloat(values.count)))
        DesignSystem.Color.accent.withAlphaComponent(0.55).setFill()
        for (index, value) in values.enumerated() {
            let height = max(1.5, rect.height * CGFloat(value) / CGFloat(peak))
            let bar = CGRect(x: CGFloat(index) * (width + gap), y: rect.height - height, width: width, height: height)
            UIBezierPath(roundedRect: bar, cornerRadius: min(width / 2, 1.5)).fill()
        }
    }
}

/// Decides, for a post a screen is about to draw, whether its stats strip is
/// open and with what: nothing when the setting is off or the strip is closed,
/// the public counts for anyone's post, and X's own numbers for the signed-in
/// account's (asking for them the first time).
@MainActor
enum PostStatsPolicy {
    static func content(
        for tweet: Tweet, expanded: Bool, isOwn: Bool, changed: @escaping @MainActor () -> Void
    ) -> PostStatsContent? {
        switch AppSettings.postStatsMode {
        case .off: return nil
        case .onTap: guard expanded else { return nil }
        case .always: break
        }
        guard isOwn else { return .publicCounts }
        return ownContent(for: tweet, store: .shared, changed: changed)
    }

    /// An own post's strip from `store`: X's numbers once they are in, the
    /// public counts when X has none or the request failed, and a request the
    /// first time (or once a failure's rest is over).
    static func ownContent(
        for tweet: Tweet, store: PostStatsStore, changed: @escaping @MainActor () -> Void
    ) -> PostStatsContent {
        switch store.entry(for: tweet.restID) {
        case let .loaded(analytics)?: return .analytics(analytics)
        case .unavailable?, .failed?: return .publicCounts
        case .loading?: return .loading
        case nil:
            store.load(tweet.restID, changed: changed)
            return .loading
        }
    }
}
