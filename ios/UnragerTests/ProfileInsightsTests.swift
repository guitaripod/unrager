import Foundation
import Testing
import UnragerKit
@testable import Unrager

@MainActor
@Suite("Profile insights")
struct ProfileInsightsTests {
    private func tweet(_ id: String, likes: Int, reposts: Int = 0, replies: Int = 0, views: Int? = nil,
                       reply: Bool = false, repost: Bool = false, text: String = "t") throws -> Tweet {
        let user = #"{"rest_id":"1","handle":"a","name":"A","verified":false,"followers":0,"following":0}"#
        let json = """
        {"rest_id":"\(id)","author":\(user),"created_at":"2026-01-01T00:00:00Z","text":"\(text)",
         "reply_count":\(replies),"retweet_count":\(reposts),"like_count":\(likes),"quote_count":0,
         "bookmark_count":0,"favorited":false,"retweeted":false,"bookmarked":false,"media":[],
         "url":"https://x.com/a/status/\(id)","urls":[]
         \(views.map { ",\"view_count\":\($0)" } ?? "")
         \(reply ? #","in_reply_to_tweet_id":"9""# : "")
         \(repost ? ",\"retweeted_by\":\(user)" : "")}
        """
        return try UnragerJSON.decode(Tweet.self, from: Data(json.utf8))
    }

    @Test("Totals cover the account's own original posts and the best one is picked by views")
    func totals() throws {
        let tweets = [
            try tweet("1", likes: 10, reposts: 1, replies: 2, views: 1_000, text: "first"),
            try tweet("2", likes: 5, reposts: 0, replies: 1, views: 4_000, text: "second"),
            try tweet("3", likes: 1, reposts: 3, replies: 0, views: 500),
            try tweet("4", likes: 999, reply: true),
            try tweet("5", likes: 999, repost: true),
        ]
        let insights = try #require(ProfileInsights.make(from: tweets))
        #expect(insights.postCount == 3)
        #expect(insights.views == 5_500)
        #expect(insights.likes == 16)
        #expect(insights.reposts == 4)
        #expect(insights.replies == 3)
        #expect(insights.top == .init(tweetID: "2", text: "second", metric: "4K views"))
    }

    @Test("Without view counts the most liked post wins and says likes")
    func likesFallback() throws {
        let tweets = [try tweet("1", likes: 3), try tweet("2", likes: 9), try tweet("3", likes: 1)]
        let insights = try #require(ProfileInsights.make(from: tweets))
        #expect(insights.views == nil)
        #expect(insights.top.tweetID == "2")
        #expect(insights.top.metric == "9 likes")
    }

    @Test("Too few posts say nothing, and only the last twenty count")
    func limits() throws {
        #expect(ProfileInsights.make(from: [try tweet("1", likes: 1), try tweet("2", likes: 1)]) == nil)
        let many = try (0..<30).map { try tweet("\($0)", likes: 1) }
        #expect(ProfileInsights.make(from: many)?.postCount == ProfileInsights.window)
    }
}
