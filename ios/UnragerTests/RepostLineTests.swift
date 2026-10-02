import Foundation
import Testing
import UIKit
import UnragerKit
@testable import Unrager

@Suite("Repost line")
struct RepostLineTests {
    private func tweet(id: String = "1", reposter: (handle: String, name: String)? = nil,
                       author: String = "mira") throws -> Tweet {
        let repost = reposter.map { """
        "retweeted_by":{"rest_id":"9","handle":"\($0.handle)","name":"\($0.name)","verified":false,
          "followers":0,"following":0},
        """ } ?? ""
        let json = """
        {"rest_id":"\(id)","author":{"rest_id":"2","handle":"\(author)","name":"Mira Koski","verified":false,
          "followers":0,"following":0},"created_at":"2026-06-19T12:00:00Z","text":"two directions",\(repost)
          "reply_count":0,"retweet_count":11,"like_count":482,"quote_count":0,"bookmark_count":0,
          "retweeted":true,"url":"https://x.com/\(author)/status/\(id)"}
        """
        return try UnragerJSON.decode(Tweet.self, from: Data(json.utf8))
    }

    @Test("A repost names who reposted it; a plain post has no line")
    func names() throws {
        let repost = try tweet(reposter: ("kitwren", "Kit Wren"))
        #expect(RepostLine.text(for: repost, viewerHandle: "noralind") == "Kit Wren reposted")
        #expect(RepostLine.text(for: repost, viewerHandle: nil) == "Kit Wren reposted")
        #expect(RepostLine.text(for: try tweet(), viewerHandle: "noralind") == nil)
    }

    @Test("The signed-in account's own repost reads \"You reposted\", whatever the handle's case")
    func ownRepost() throws {
        let mine = try tweet(reposter: ("NoraLind", "Nora Lind"))
        #expect(RepostLine.text(for: mine, viewerHandle: "noralind") == "You reposted")
        #expect(RepostLine.text(for: mine, viewerHandle: "") == "Nora Lind reposted")
    }

    @Test("VoiceOver reads the repost first and offers the reposter's profile")
    @MainActor
    func spokenRepost() throws {
        let cell = TweetCell(frame: CGRect(x: 0, y: 0, width: 390, height: 300))
        cell.configure(with: try tweet(reposter: ("kitwren", "Kit Wren")), imagesEnabled: false,
                       contentWidth: 390, viewerHandle: "noralind")
        let label = try #require(cell.accessibilityLabel)
        #expect(label.hasPrefix("Kit Wren reposted. Mira Koski, @mira"))
        #expect(label.contains("11 reposts, 482 likes"))
        let names = cell.accessibilityCustomActions?.map(\.name) ?? []
        #expect(names.contains("Open Kit Wren's profile"))
        #expect(names.contains("Open Mira Koski's profile"))
    }

    @Test("A reused row drops the repost line and its action")
    @MainActor
    func reuse() throws {
        let cell = TweetCell(frame: CGRect(x: 0, y: 0, width: 390, height: 300))
        cell.configure(with: try tweet(reposter: ("noralind", "Nora Lind")), imagesEnabled: false,
                       contentWidth: 390, viewerHandle: "noralind")
        #expect(cell.accessibilityLabel?.hasPrefix("You reposted. ") == true)
        cell.prepareForReuse()
        cell.configure(with: try tweet(id: "5"), imagesEnabled: false, contentWidth: 390, viewerHandle: "noralind")
        let label = try #require(cell.accessibilityLabel)
        #expect(label.hasPrefix("Mira Koski, @mira"))
        #expect(!label.contains("reposted."))
        #expect(cell.accessibilityCustomActions?.contains { $0.name == "Open Nora Lind's profile" } == false)
    }
}
