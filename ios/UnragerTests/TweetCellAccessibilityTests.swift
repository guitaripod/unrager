import Foundation
import Testing
import UIKit
import UnragerKit
@testable import Unrager

@Suite("Tweet row accessibility")
struct TweetCellAccessibilityTests {
    private func tweet(text: String, quoted: String? = nil) throws -> Tweet {
        let quote = quoted.map { """
        "quoted_tweet":{"rest_id":"7","author":{"rest_id":"8","handle":"q","name":"Quoter","verified":false,
          "followers":0,"following":0},"created_at":"2026-06-19T12:00:00Z","text":"\($0)",
          "reply_count":0,"retweet_count":0,"like_count":0,"quote_count":0,"bookmark_count":0,
          "in_reply_to_tweet_id":"6","url":"https://x.com/q/status/7"},
        """ } ?? ""
        let json = """
        {"rest_id":"1","author":{"rest_id":"2","handle":"a","name":"Ada","verified":false,
          "followers":0,"following":0},"created_at":"2026-06-19T12:00:00Z","text":"\(text)",\(quote)
          "reply_count":0,"retweet_count":4,"like_count":10,"quote_count":0,
          "bookmark_count":1,"retweeted":false,"bookmarked":false,
          "url":"https://x.com/a/status/1"}
        """
        return try UnragerJSON.decode(Tweet.self, from: Data(json.utf8))
    }

    @Test("The row's spoken label and actions follow an optimistic like without a rebind")
    @MainActor
    func labelFollowsLike() throws {
        let cell = TweetCell(frame: CGRect(x: 0, y: 0, width: 390, height: 300))
        cell.configure(with: try tweet(text: "hello world"), imagesEnabled: false, contentWidth: 390)
        let before = try #require(cell.accessibilityLabel)
        #expect(before.contains("Ada"))
        #expect(before.contains("hello world"))
        #expect(before.contains("10 likes"))
        #expect(!before.hasSuffix("liked"))
        #expect(cell.accessibilityCustomActions?.contains { $0.name == "Like" } == true)
        cell.applyLike(favorited: true, count: 11)
        let after = try #require(cell.accessibilityLabel)
        #expect(after.contains("11 likes"))
        #expect(after.hasSuffix("liked"))
        #expect(cell.accessibilityCustomActions?.contains { $0.name == "Unlike" } == true)
    }

    @Test("A quoted reply is shown and read without X's leading @mentions")
    @MainActor
    func quotedReplyDropsMentions() throws {
        let cell = TweetCell(frame: CGRect(x: 0, y: 0, width: 390, height: 300))
        cell.configure(with: try tweet(text: "look", quoted: "@a @b fair point"), imagesEnabled: false,
                       contentWidth: 390)
        let label = try #require(cell.accessibilityLabel)
        #expect(label.contains("Quoting Quoter: fair point"))
    }
}
