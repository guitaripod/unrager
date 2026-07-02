import Foundation
import Testing
@testable import UnragerKit

@Suite("Tweet engagement write-back")
struct TweetEngagementTests {
    private func fixture() throws -> Tweet {
        let json = """
        {"rest_id":"42","author":{"rest_id":"2","handle":"a","name":"A","verified":false,
          "followers":0,"following":0},"created_at":"2026-06-19T12:00:00Z","text":"hi @b",
          "reply_count":3,"retweet_count":4,"like_count":10,"quote_count":1,"view_count":99,
          "favorited":false,"lang":"en",
          "urls":[{"expanded_url":"https://example.com/a","display_url":"example.com/a"}],
          "url":"https://x.com/a/status/42"}
        """
        return try UnragerJSON.decode(Tweet.self, from: Data(json.utf8))
    }

    @Test("withLike flips only the like state and count")
    func withLikeFlipsLikeState() throws {
        let tweet = try fixture()
        let liked = tweet.withLike(favorited: true, likeCount: tweet.likeCount + 1)
        #expect(liked.favorited)
        #expect(liked.likeCount == 11)
        #expect(liked.restID == tweet.restID)
        #expect(liked.text == tweet.text)
        #expect(liked.author == tweet.author)
        #expect(liked.createdAt == tweet.createdAt)
        #expect(liked.replyCount == tweet.replyCount)
        #expect(liked.retweetCount == tweet.retweetCount)
        #expect(liked.quoteCount == tweet.quoteCount)
        #expect(liked.viewCount == tweet.viewCount)
        #expect(liked.urls.count == tweet.urls.count)
        #expect(liked.displayDiffers(from: tweet))

        let unliked = liked.withLike(favorited: false, likeCount: liked.likeCount - 1)
        #expect(!unliked.favorited)
        #expect(unliked.likeCount == 10)
    }

    @Test("withLike floors the count at zero")
    func withLikeFloorsAtZero() throws {
        let tweet = try fixture()
        let unliked = tweet.withLike(favorited: false, likeCount: -1)
        #expect(unliked.likeCount == 0)
    }

    @Test("togglingLike applies the ±1 delta and round-trips")
    func togglingLikeAppliesDelta() throws {
        let tweet = try fixture()
        let liked = try #require(tweet.togglingLike(to: true))
        #expect(liked.favorited)
        #expect(liked.likeCount == 11)

        let unliked = try #require(liked.togglingLike(to: false))
        #expect(!unliked.favorited)
        #expect(unliked.likeCount == 10)
    }

    @Test("togglingLike is nil when the tweet is already in that state")
    func togglingLikeGuardsDuplicates() throws {
        let tweet = try fixture()
        #expect(tweet.togglingLike(to: false) == nil)
        let liked = try #require(tweet.togglingLike(to: true))
        #expect(liked.togglingLike(to: true) == nil)
    }

    @Test("togglingLike never drops the count below zero")
    func togglingLikeFloorsAtZero() throws {
        let tweet = try fixture()
        let zeroed = tweet.withLike(favorited: true, likeCount: 0)
        let unliked = try #require(zeroed.togglingLike(to: false))
        #expect(unliked.likeCount == 0)
    }
}
