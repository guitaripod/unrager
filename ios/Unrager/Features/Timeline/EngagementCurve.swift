import Foundation
import UnragerKit

/// The shape of a post's first hours, worked out from X's impressions per hour:
/// where it peaked, how its reach built up and how long half of it took to
/// arrive. Plain numbers, so what the chart says can be tested without a view.
struct EngagementCurve: Equatable {
    /// The fewest hours worth drawing a curve for.
    static let minimumHours = 6

    let hourly: [Int]
    let total: Int
    let peakIndex: Int
    /// The share of the impressions that had arrived by the end of each hour,
    /// 0 to 1, rising to 1.
    let cumulative: [Double]

    init?(hourly: [Int]) {
        let values = hourly.map { max(0, $0) }
        let sum = values.reduce(0, +)
        guard values.count >= Self.minimumHours, sum > 0,
              let peak = values.indices.max(by: { values[$0] < values[$1] }) else { return nil }
        self.hourly = values
        total = sum
        peakIndex = peak
        var running = 0
        cumulative = values.map {
            running += $0
            return Double(running) / Double(sum)
        }
    }

    var peak: Int { hourly[peakIndex] }

    /// How many hours it took for half of the impressions to arrive (1 means
    /// within the first hour).
    var halfLife: Int {
        (cumulative.firstIndex { $0 >= 0.5 } ?? hourly.count - 1) + 1
    }

    /// The hour at `index` as a share of all the impressions.
    func share(at index: Int) -> Double {
        guard hourly.indices.contains(index) else { return 0 }
        return Double(hourly[index]) / Double(total)
    }

    /// "5–6h" for the sixth hour.
    static func hourRange(_ index: Int) -> String {
        "\(index)–\(index + 1)h"
    }

    /// One sentence on how fast the reach came.
    var insight: String {
        switch halfLife {
        case 1: return "Half of the impressions arrived in the first hour."
        case ..<24: return "Half of the impressions arrived in the first \(halfLife) hours."
        default: return "Half of the impressions took \(halfLife) hours to arrive."
        }
    }

    /// What VoiceOver says for the chart.
    var spoken: String {
        "Impressions by hour. Peak of \(Format.count(peak)) in hour \(peakIndex + 1). \(insight)"
    }

    /// The hours to label along the bottom of a chart of `hours`: every 3, 6 or
    /// 12 hours depending on how long it is, starting at 0.
    static func axisTicks(hours: Int) -> [Int] {
        let step = hours <= 12 ? 3 : hours <= 30 ? 6 : 12
        return Array(stride(from: 0, through: hours, by: step))
    }
}

/// How a post's engagement splits between likes, reposts, replies, quotes and
/// bookmarks, for the public counts of anyone's post.
struct EngagementMix: Equatable {
    enum Kind: CaseIterable {
        case likes, reposts, replies, quotes, bookmarks

        var title: String {
            switch self {
            case .likes: return "Likes"
            case .reposts: return "Reposts"
            case .replies: return "Replies"
            case .quotes: return "Quotes"
            case .bookmarks: return "Saves"
            }
        }
    }

    struct Slice: Equatable {
        let kind: Kind
        let count: Int
        let share: Double
    }

    /// The kinds anyone did at all, most common first.
    let slices: [Slice]
    let total: Int

    init?(tweet: Tweet) {
        let counts: [(Kind, Int)] = [
            (.likes, tweet.likeCount), (.reposts, tweet.retweetCount), (.replies, tweet.replyCount),
            (.quotes, tweet.quoteCount), (.bookmarks, tweet.bookmarkCount),
        ]
        let sum = counts.reduce(0) { $0 + max(0, $1.1) }
        guard sum > 0 else { return nil }
        total = sum
        slices = counts
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .map { Slice(kind: $0.0, count: $0.1, share: Double($0.1) / Double(sum)) }
    }

    /// "58%" for a share, "<1%" for a sliver.
    static func percent(_ share: Double) -> String {
        let value = share * 100
        return value < 1 ? "<1%" : String(format: "%.0f%%", value)
    }
}

/// The big figure at the top of a post's stats: impressions for the account's
/// own post, views for anyone's, with the share of them that turned into some
/// engagement.
struct PostStatsHeadline: Equatable {
    let figure: Int
    let caption: String
    let engaged: String?

    static func make(for tweet: Tweet, content: PostStatsContent) -> PostStatsHeadline? {
        switch content {
        case let .analytics(analytics):
            return PostStatsHeadline(
                figure: analytics.impressions, caption: "impressions",
                engaged: analytics.engagementRate.map { PostStatsModel.percent($0) + " engaged" })
        case .publicCounts, .loading:
            guard let views = tweet.viewCount, views > 0 else { return nil }
            let engagements = tweet.likeCount + tweet.retweetCount + tweet.replyCount + tweet.quoteCount
                + tweet.bookmarkCount
            return PostStatsHeadline(
                figure: views, caption: "views",
                engaged: engagements > 0 ? PostStatsModel.percent(Double(engagements) / Double(views)) + " engaged" : nil)
        }
    }
}
