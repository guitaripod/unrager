import Foundation
import Testing
import UnragerKit
@testable import Unrager

@Suite("Engagement chart")
struct EngagementCurveTests {
    private func tweet(views: Int?, likes: Int = 0, reposts: Int = 0, replies: Int = 0, quotes: Int = 0,
                       bookmarks: Int = 0) throws -> Tweet {
        let viewField = views.map { "\"view_count\":\($0)," } ?? ""
        let json = """
        {"rest_id":"1","author":{"rest_id":"2","handle":"a","name":"A","verified":false,
          "followers":0,"following":0},"created_at":"2026-06-19T12:00:00Z","text":"hi",
          "reply_count":\(replies),"retweet_count":\(reposts),"like_count":\(likes),"quote_count":\(quotes),
          \(viewField)"bookmark_count":\(bookmarks),"url":"https://x.com/a/status/1"}
        """
        return try UnragerJSON.decode(Tweet.self, from: Data(json.utf8))
    }

    @Test("A curve needs six hours and some impressions")
    func needsSomething() {
        #expect(EngagementCurve(hourly: [1, 2, 3, 4, 5]) == nil)
        #expect(EngagementCurve(hourly: [0, 0, 0, 0, 0, 0, 0]) == nil)
        #expect(EngagementCurve(hourly: [0, 0, 0, 0, 0, 1]) != nil)
    }

    @Test("It finds the peak, adds the reach up to one and says when half of it had arrived")
    func shape() throws {
        let curve = try #require(EngagementCurve(hourly: [10, 40, 100, 30, 10, 5, 3, 2]))
        #expect(curve.peakIndex == 2 && curve.peak == 100)
        #expect(curve.total == 200)
        #expect(curve.cumulative.last == 1)
        #expect(curve.cumulative[2] == 0.75)
        #expect(curve.halfLife == 3)
        #expect(curve.share(at: 1) == 0.2)
        #expect(curve.share(at: 99) == 0)
    }

    @Test("Negative figures count as nothing")
    func negatives() throws {
        let curve = try #require(EngagementCurve(hourly: [-5, 10, 10, 10, 10, 10]))
        #expect(curve.total == 50)
    }

    @Test("The insight names how fast the reach came")
    func insight() throws {
        let fast = try #require(EngagementCurve(hourly: [900, 50, 20, 10, 10, 10]))
        #expect(fast.insight == "Half of the impressions arrived in the first hour.")
        let steady = try #require(EngagementCurve(hourly: [10, 10, 10, 10, 10, 10, 10, 10]))
        #expect(steady.insight == "Half of the impressions arrived in the first 4 hours.")
        let slow = try #require(EngagementCurve(hourly: Array(repeating: 0, count: 30) + [5, 5]))
        #expect(slow.insight == "Half of the impressions took 31 hours to arrive.")
    }

    @Test("Hour marks follow the length of the chart")
    func ticks() {
        #expect(EngagementCurve.axisTicks(hours: 48) == [0, 12, 24, 36, 48])
        #expect(EngagementCurve.axisTicks(hours: 28) == [0, 6, 12, 18, 24])
        #expect(EngagementCurve.axisTicks(hours: 9) == [0, 3, 6, 9])
        #expect(EngagementCurve.hourRange(5) == "5–6h")
    }

    @Test("The mix lists only what anyone did, biggest first, as shares of the whole")
    func mix() throws {
        let post = try tweet(views: 1_000, likes: 60, reposts: 30, replies: 10)
        let mix = try #require(EngagementMix(tweet: post))
        #expect(mix.slices.map { $0.kind } == [.likes, .reposts, .replies])
        #expect(mix.slices.map { $0.share } == [0.6, 0.3, 0.1])
        #expect(EngagementMix(tweet: try tweet(views: 5)) == nil)
        #expect(EngagementMix.percent(0.004) == "<1%")
        #expect(EngagementMix.percent(0.58) == "58%")
    }

    @Test("The headline is impressions for your post and views for anyone's, with the share that engaged")
    func headline() throws {
        let post = try tweet(views: 10_000, likes: 200, reposts: 50, replies: 30, quotes: 10, bookmarks: 10)
        let publicLine = try #require(PostStatsHeadline.make(for: post, content: .publicCounts))
        #expect(publicLine == PostStatsHeadline(figure: 10_000, caption: "views", engaged: "3.0% engaged"))
        let analytics = PostAnalytics(impressions: 155, engagements: 8)
        let own = try #require(PostStatsHeadline.make(for: post, content: .analytics(analytics)))
        #expect(own == PostStatsHeadline(figure: 155, caption: "impressions", engaged: "5.2% engaged"))
        #expect(PostStatsHeadline.make(for: try tweet(views: nil), content: .publicCounts) == nil)
        let quiet = try #require(PostStatsHeadline.make(for: try tweet(views: 40), content: .publicCounts))
        #expect(quiet.engaged == nil)
    }
}
