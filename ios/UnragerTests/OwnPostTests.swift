import Foundation
import Testing
import UIKit
import UnragerKit
@testable import Unrager

@Suite("Own posts and deleting them")
struct OwnPostTests {
    private func tweet(id: String = "1", author: String, reposter: String? = nil) throws -> Tweet {
        let repost = reposter.map { """
        "retweeted_by":{"rest_id":"9","handle":"\($0)","name":"R","verified":false,"followers":0,"following":0},
        """ } ?? ""
        let json = """
        {"rest_id":"\(id)","author":{"rest_id":"2","handle":"\(author)","name":"A","verified":false,
          "followers":0,"following":0},"created_at":"2026-06-19T12:00:00Z","text":"hi",\(repost)
          "reply_count":0,"retweet_count":0,"like_count":0,"quote_count":0,"bookmark_count":0,
          "url":"https://x.com/\(author)/status/\(id)"}
        """
        return try UnragerJSON.decode(Tweet.self, from: Data(json.utf8))
    }

    @Test("Only the account's own posts offer Delete, matched without case")
    func ownPosts() throws {
        #expect(OwnPost.canDelete(try tweet(author: "NoraLind"), viewerHandle: "noralind"))
        #expect(!OwnPost.canDelete(try tweet(author: "mira"), viewerHandle: "noralind"))
        #expect(!OwnPost.canDelete(try tweet(author: "noralind"), viewerHandle: nil))
    }

    @Test("The account's own repost offers Undo repost, not Delete; someone else's repost of an own post can be deleted")
    func reposts() throws {
        #expect(!OwnPost.canDelete(try tweet(author: "noralind", reposter: "noralind"), viewerHandle: "noralind"))
        #expect(!OwnPost.canDelete(try tweet(author: "mira", reposter: "noralind"), viewerHandle: "noralind"))
        #expect(OwnPost.canDelete(try tweet(author: "noralind", reposter: "kitwren"), viewerHandle: "noralind"))
    }

    @Test("Removing a deleted post drops it from the feed and marks it deleted for later loads")
    @MainActor
    func removal() throws {
        let model = TimelineViewModel(source: .search(query: "", product: .top))
        let kept = try tweet(id: "own-keep-1", author: "a")
        let gone = try tweet(id: "own-gone-1", author: "noralind")
        model.tweets.send([kept, gone])
        model.hiddenPosts.send([HiddenPost(tweet: gone, reason: nil)])
        model.remove(id: "own-gone-1")
        #expect(model.tweets.value.map(\.restID) == ["own-keep-1"])
        #expect(model.hiddenPosts.value.isEmpty)
        #expect(TimelineViewModel.wasDeleted("own-gone-1"))
        #expect(!TimelineViewModel.wasDeleted("own-keep-1"))
        model.remove(id: "own-absent-1")
        #expect(model.tweets.value.map(\.restID) == ["own-keep-1"])
    }

    @Test("VoiceOver offers Delete only where the screen allows it")
    @MainActor
    func spokenDelete() throws {
        let cell = TweetCell(frame: CGRect(x: 0, y: 0, width: 390, height: 300))
        cell.configure(with: try tweet(author: "noralind"), imagesEnabled: false, contentWidth: 390)
        #expect(cell.accessibilityCustomActions?.contains { $0.name == "Delete" } == false)
        cell.onDelete = {}
        #expect(cell.accessibilityCustomActions?.last?.name == "Delete")
        cell.prepareForReuse()
        cell.configure(with: try tweet(author: "noralind"), imagesEnabled: false, contentWidth: 390)
        #expect(cell.accessibilityCustomActions?.contains { $0.name == "Delete" } == false)
    }
}
