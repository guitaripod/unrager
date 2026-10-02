import Foundation
import Testing
import UnragerKit
@testable import Unrager

@Suite("Timeline engagement write-backs")
struct EngagementTests {
    private func tweet(id: String) throws -> Tweet {
        let json = """
        {"rest_id":"\(id)","author":{"rest_id":"2","handle":"a","name":"A","verified":false,
          "followers":0,"following":0},"created_at":"2026-06-19T12:00:00Z","text":"hi",
          "reply_count":0,"retweet_count":4,"like_count":10,"quote_count":0,
          "bookmark_count":1,"retweeted":false,"bookmarked":false,
          "url":"https://x.com/a/status/\(id)"}
        """
        return try UnragerJSON.decode(Tweet.self, from: Data(json.utf8))
    }

    @Test("applyRetweet writes the confirmed repost into the published tweets")
    @MainActor
    func applyRetweetWritesBack() throws {
        let model = TimelineViewModel(source: .user(handle: "a"))
        model.tweets.send([try tweet(id: "1"), try tweet(id: "2")])
        model.applyRetweet(id: "1", retweeted: true)
        let first = try #require(model.tweets.value.first)
        #expect(first.retweeted)
        #expect(first.retweetCount == 5)
        #expect(!model.tweets.value[1].retweeted)
        model.applyRetweet(id: "1", retweeted: true)
        #expect(model.tweets.value[0].retweetCount == 5)
    }

    @Test("applyBookmark writes the confirmed bookmark into the published tweets")
    @MainActor
    func applyBookmarkWritesBack() throws {
        let model = TimelineViewModel(source: .bookmarks(query: ""))
        model.tweets.send([try tweet(id: "9")])
        model.applyBookmark(id: "9", bookmarked: true)
        #expect(model.tweets.value[0].bookmarked)
        #expect(model.tweets.value[0].bookmarkCount == 2)
        model.applyBookmark(id: "9", bookmarked: false)
        #expect(!model.tweets.value[0].bookmarked)
        #expect(model.tweets.value[0].bookmarkCount == 1)
    }

    @Test("markAllRead optimistically marks every loaded tweet seen and clears the unread count")
    @MainActor
    func markAllReadOptimistic() throws {
        let model = TimelineViewModel(source: .home(following: true, originals: false))
        model.tweets.send([try tweet(id: "1"), try tweet(id: "2"), try tweet(id: "3")])
        #expect(model.unreadCount == 3)
        model.markAllRead()
        #expect(model.isSeen("1"))
        #expect(model.isSeen("2"))
        #expect(model.isSeen("3"))
        #expect(model.unreadCount == 0)
    }

    @Test("A refresh keeps the posts hidden before it, moves one hidden again to the end and drops one now shown")
    func hiddenPostsSurviveRefresh() throws {
        let earlier = try ["1", "2", "3"].map { HiddenPost(tweet: try tweet(id: $0), reason: "rule") }
        let refreshed = try ["2", "4"].map { HiddenPost(tweet: try tweet(id: $0), reason: "rule") }
        let merged = TimelineViewModel.mergedHidden(earlier, adding: refreshed, shown: ["3"], cap: 200)
        #expect(merged.map(\.id) == ["1", "2", "4"])
        let capped = TimelineViewModel.mergedHidden(earlier, adding: refreshed, shown: [], cap: 2)
        #expect(capped.map(\.id) == ["2", "4"])
    }

    @Test("Bookmarks with no query is the full timeline, not an awaiting-query state")
    @MainActor
    func bookmarksNeverAwaitQuery() {
        #expect(!TimelineViewModel(source: .bookmarks(query: "")).awaitingQuery)
        #expect(!TimelineViewModel(source: .bookmarks(query: "rust")).awaitingQuery)
        #expect(TimelineViewModel(source: .search(query: "", product: .top)).awaitingQuery)
    }

    @Test("The full bookmarks timeline gets its own cache seed key")
    func bookmarksCacheKey() {
        #expect(TimelineViewModel.Source.bookmarks(query: "").cacheKey == "bookmarks-all")
        #expect(TimelineViewModel.Source.home(following: false, originals: false).cacheKey == "home-foryou")
        #expect(TimelineViewModel.Source.home(following: false, originals: true).cacheKey == "home-foryou-originals")
        #expect(TimelineViewModel.Source.home(following: true, originals: false).cacheKey == "home-following")
        #expect(TimelineViewModel.Source.bookmarks(query: "Rust").cacheKey == "bookmarks-rust")
    }
}
