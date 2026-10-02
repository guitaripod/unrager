import Foundation
import Testing
import UnragerKit
@testable import Unrager

@Suite("Post stats")
struct PostStatsTests {
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

    @Test("A public post lists quotes and three rates of its views")
    func publicCells() throws {
        let post = try tweet(views: 10_000, likes: 200, reposts: 50, replies: 30, quotes: 10, bookmarks: 10)
        let cells = PostStatsModel.cells(for: post, content: .publicCounts)
        #expect(cells.map(\.caption) == ["Quotes", "Engagement", "Like rate", "Repost rate"])
        #expect(cells.map(\.value) == ["10", "3.0%", "2.0%", "0.5%"])
    }

    @Test("Without a view count only the quotes are known")
    func noViews() throws {
        let cells = PostStatsModel.cells(for: try tweet(views: nil, quotes: 4), content: .publicCounts)
        #expect(cells == [PostStatCell(value: "4", caption: "Quotes")])
    }

    @Test("X's analytics lead with impressions and engagements, and add link clicks and follows only when there are some")
    func analyticsCells() throws {
        let post = try tweet(views: 155)
        let base = PostAnalytics(impressions: 155, engagements: 8, detailExpands: 5, profileVisits: 1)
        let plain = PostStatsModel.cells(for: post, content: .analytics(base))
        #expect(plain.map(\.caption) == ["Impressions", "Engagements", "Expands", "Profile visits"])
        #expect(plain[0].value == "155")
        #expect(plain[1].value == "8 · 5.2%")
        let busy = PostAnalytics(impressions: 155, engagements: 8, detailExpands: 5, profileVisits: 1,
                                 linkClicks: 3, follows: 2)
        let all = PostStatsModel.cells(for: post, content: .analytics(busy))
        #expect(all.suffix(2).map(\.caption) == ["Link clicks", "Follows"])
    }

    @Test("Percentages round to one decimal under ten percent and none above")
    func percentages() {
        #expect(PostStatsModel.percent(0) == "0%")
        #expect(PostStatsModel.percent(0.0004) == "<0.1%")
        #expect(PostStatsModel.percent(0.0123) == "1.2%")
        #expect(PostStatsModel.percent(0.456) == "46%")
    }

    @Test("The setting's modes are all there, tap first")
    func modes() {
        #expect(PostStatsMode.allCases.map(\.title) == ["Tap views", "Always", "Off"])
        #expect(PostStatsMode(rawValue: 0) == .onTap)
    }
}
