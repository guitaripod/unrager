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

/// Which parts of a post's stats card are on show, and with what: decided in
/// one place so the card's height never depends on what a previous post or a
/// previous state left visible, and testable without a view.
struct PostStatsLayout: Equatable {
    /// What fills the space under the headline.
    enum Plot: Equatable {
        /// Nothing the post has data for.
        case none
        /// The pulsing outline that holds the chart's place while X's numbers load.
        case outline
        case curve(EngagementCurve)
        case mix(EngagementMix)
    }

    let headline: PostStatsHeadline?
    let plot: Plot
    let figures: [PostStatCell]
    /// Whether the figures are placeholders until X's numbers arrive.
    let dimmed: Bool

    init(tweet: Tweet, content: PostStatsContent) {
        headline = PostStatsHeadline.make(for: tweet, content: content)
        var cells = PostStatsModel.cells(for: tweet, content: content)
        let pillShowsEngagement = headline?.engaged != nil
        switch content {
        case .loading:
            plot = .outline
            if pillShowsEngagement { cells.removeAll { $0.caption == "Engagement" } }
        case let .analytics(analytics):
            if let curve = EngagementCurve(hourly: analytics.hourlyImpressions) {
                plot = .curve(curve)
            } else {
                plot = EngagementMix(tweet: tweet).map(Plot.mix) ?? .none
            }
            cells = cells.dropFirst().map {
                PostStatCell(value: $0.value.components(separatedBy: " · ").first ?? $0.value,
                             caption: $0.caption, opensQuotes: $0.opensQuotes)
            }
        case .publicCounts:
            plot = EngagementMix(tweet: tweet).map(Plot.mix) ?? .none
            if pillShowsEngagement { cells.removeAll { $0.caption == "Engagement" } }
        }
        figures = cells
        dimmed = content == .loading
    }

    /// The sentence under a chart of the post's hours.
    var insight: String? {
        if case let .curve(curve) = plot { return curve.insight }
        return nil
    }

    /// The hairline between the plot and the figures, only when there is
    /// something above it to divide them from.
    var showsDivider: Bool {
        !figures.isEmpty && (headline != nil || plot != .none)
    }
}

/// The strip under a post's action bar, as one card: the big figure (impressions
/// on your own post, views on anyone's) with the share that engaged, a chart
/// under it (a post's first hours, with the reach building up, for your own;
/// how its engagement splits between likes, reposts and the rest for anyone's),
/// a line saying what the chart shows, and the smaller figures. The first time
/// it opens the card rises, the figure counts up and the chart draws itself; a
/// chart that was a pulsing outline while X's numbers loaded fills in when they
/// arrive.
final class PostStatsView: UIStackView {
    /// What the card last showed, so a redraw of the same thing stays still.
    private enum Presented: Equatable {
        case loading(String)
        case analytics(String)
        case publicCounts(String)
    }

    private let card = UIView()
    private let content = UIStackView()
    private let headline = UIStackView()
    private let figure = CountingLabel()
    private let figureCaption = UILabel()
    private let engaged = EngagedPill()
    private let chart = EngagementChartView()
    private let mix = EngagementMixView()
    private let insight = UILabel()
    private let divider = HairlineView()
    private let figures = UIStackView()
    private var presented: Presented?
    private var shown: PostStatsLayout?
    /// Fired by a tap on the "Quotes" figure when the post has any.
    var onTapQuotes: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        axis = .vertical
        isLayoutMarginsRelativeArrangement = true
        directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 4, trailing: 16)

        card.backgroundColor = DesignSystem.Color.surface
        card.layer.cornerRadius = DesignSystem.Radius.card
        card.layer.cornerCurve = .continuous

        figure.font = DesignSystem.Typography.system(26, weight: .bold)
        figure.textColor = DesignSystem.Color.label
        figure.format = { Format.count($0) }
        figure.setContentHuggingPriority(.required, for: .horizontal)
        figureCaption.font = DesignSystem.Typography.system(13, weight: .medium)
        figureCaption.textColor = DesignSystem.Color.secondaryLabel
        let headlineSpacer = UIView()
        headlineSpacer.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
        [figure, figureCaption, headlineSpacer, engaged].forEach(headline.addArrangedSubview)
        headline.alignment = .firstBaseline
        headline.spacing = DesignSystem.Spacing.xs + 2

        insight.font = DesignSystem.Typography.system(12, weight: .regular)
        insight.textColor = DesignSystem.Color.secondaryLabel
        insight.numberOfLines = 2

        figures.axis = .horizontal
        figures.distribution = .equalSpacing
        figures.alignment = .top

        [headline, chart, mix, insight, divider, figures].forEach(content.addArrangedSubview)
        content.axis = .vertical
        content.spacing = DesignSystem.Spacing.s + 2
        content.setCustomSpacing(DesignSystem.Spacing.m, after: insight)
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        addArrangedSubview(card)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
        ])
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    /// Forgets what the card showed, for a row about to show another post.
    func reset() {
        presented = nil
        shown = nil
    }

    /// Shows `content` for `tweet`. With `animate`, a card that is new on this
    /// post rises and draws itself, and one that changed (X's numbers arriving)
    /// fills in; without it the card is simply there. Returns whether a card
    /// already on screen changed shape, so its row can be measured again.
    @discardableResult
    func configure(tweet: Tweet, content: PostStatsContent, animate: Bool = false) -> Bool {
        let now: Presented
        switch content {
        case .loading: now = .loading(tweet.restID)
        case .analytics: now = .analytics(tweet.restID)
        case .publicCounts: now = .publicCounts(tweet.restID)
        }
        let first = presented == nil
        let changed = presented != now
        presented = now
        let reveal = animate && changed && window != nil && !UIAccessibility.isReduceMotionEnabled

        let layout = PostStatsLayout(tweet: tweet, content: content)
        let reshaped = shown != nil && shown != layout
        shown = layout
        configureHeadline(layout.headline, countFrom: reveal && first ? 0 : nil, animated: reveal)
        configurePlot(layout.plot)
        insight.text = layout.insight
        insight.isHidden = layout.insight == nil
        configureFigures(layout)
        if reveal { play(first: first, curve: layout.insight != nil) }
        return reshaped
    }

    private func configurePlot(_ plot: PostStatsLayout.Plot) {
        switch plot {
        case .none:
            chart.isHidden = true
            mix.isHidden = true
        case .outline:
            chart.show(nil)
            chart.isHidden = false
            mix.isHidden = true
        case let .curve(curve):
            chart.show(curve)
            chart.isHidden = false
            mix.isHidden = true
        case let .mix(breakdown):
            chart.isHidden = true
            mix.show(breakdown)
            mix.isHidden = false
        }
    }

    private func configureHeadline(_ model: PostStatsHeadline?, countFrom: Int?, animated: Bool) {
        guard let model else {
            headline.isHidden = true
            return
        }
        headline.isHidden = false
        figureCaption.text = model.caption
        if let countFrom {
            figure.setValue(model.figure, from: countFrom, delay: 0.1, duration: 0.8)
        } else {
            figure.setValue(model.figure, animated: animated)
        }
        engaged.set(model.engaged)
    }

    private func configureFigures(_ layout: PostStatsLayout) {
        figures.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for cell in layout.figures { figures.addArrangedSubview(makeCell(cell, dimmed: layout.dimmed)) }
        figures.isHidden = layout.figures.isEmpty
        divider.isHidden = !layout.showsDivider
    }

    /// The card settles in, and what is on it follows.
    private func play(first: Bool, curve: Bool) {
        if first {
            card.alpha = 0
            card.transform = CGAffineTransform(translationX: 0, y: 10)
            UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0,
                           options: [.allowUserInteraction]) {
                self.card.alpha = 1
                self.card.transform = .identity
            }
            for (index, tile) in figures.arrangedSubviews.enumerated() {
                tile.alpha = 0
                UIView.animate(withDuration: 0.4, delay: 0.35 + Double(index) * 0.05, options: [.allowUserInteraction]) {
                    tile.alpha = 1
                }
            }
        }
        if !chart.isHidden, chart.curve != nil { chart.play() }
        if !mix.isHidden { mix.play() }
        guard curve else { return }
        insight.alpha = 0
        UIView.animate(withDuration: 0.4, delay: 1.0, options: [.allowUserInteraction]) { self.insight.alpha = 1 }
    }

    private func makeCell(_ cell: PostStatCell, dimmed: Bool) -> UIView {
        let value = UILabel()
        value.text = cell.value
        value.font = DesignSystem.Typography.system(15, weight: .semibold)
        value.textColor = dimmed ? DesignSystem.Color.tertiaryLabel
            : cell.opensQuotes ? DesignSystem.Color.accent : DesignSystem.Color.label
        let caption = UILabel()
        caption.text = cell.caption
        caption.font = DesignSystem.Typography.system(11, weight: .regular)
        caption.textColor = DesignSystem.Color.secondaryLabel
        let column = UIStackView(arrangedSubviews: [value, caption])
        column.axis = .vertical
        column.spacing = 0
        column.isAccessibilityElement = true
        column.accessibilityLabel = "\(cell.caption): \(cell.value)"
        if cell.opensQuotes {
            column.isUserInteractionEnabled = true
            column.accessibilityTraits = .button
            column.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(quotesTapped)))
        }
        return column
    }

    @objc private func quotesTapped() {
        Haptics.selection()
        onTapQuotes?()
    }
}

/// The "6.5% engaged" capsule beside the big figure.
private final class EngagedPill: UIView {
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = DesignSystem.Typography.system(12, weight: .semibold)
        label.textColor = DesignSystem.Color.accent
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
        ])
        backgroundColor = DesignSystem.Color.accent.withAlphaComponent(0.13)
        layer.cornerCurve = .continuous
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }

    func set(_ text: String?) {
        label.text = text
        isHidden = text == nil
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
