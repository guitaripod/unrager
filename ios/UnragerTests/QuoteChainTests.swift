import Foundation
import Testing
import UIKit
import UnragerKit
@testable import Unrager

@Suite("Quote chains")
struct QuoteChainTests {
    /// A post by `@p<id>` quoting `quoting`, nested as the server sends it.
    private func post(_ id: Int, quoting: String = "") -> String {
        """
        {"rest_id":"\(id)","author":{"rest_id":"\(id)","handle":"p\(id)","name":"Poster \(id)","verified":false,
          "followers":0,"following":0},"created_at":"2026-06-19T12:00:00Z","text":"text \(id)",
          "reply_count":0,"retweet_count":0,"like_count":0,"quote_count":0,"bookmark_count":0,
          "in_reply_to_tweet_id":null,"url":"https://x.com/p\(id)/status/\(id)"\(quoting)}
        """
    }

    /// Post 1 quoting post 2 quoting … post `depth + 1`.
    private func chain(quotes depth: Int) throws -> Tweet {
        var json = post(depth + 1)
        for id in stride(from: depth, through: 1, by: -1) {
            json = post(id, quoting: #","quoted_tweet":\#(json)"#)
        }
        return try UnragerJSON.decode(Tweet.self, from: Data(json.utf8))
    }

    @Test("A row follows quotes three layers down and no further")
    func chainStopsAtThree() throws {
        #expect(try chain(quotes: 0).quoteChain.isEmpty)
        #expect(try chain(quotes: 1).quoteChain.map(\.restID) == ["2"])
        #expect(try chain(quotes: 3).quoteChain.map(\.restID) == ["2", "3", "4"])
        #expect(try chain(quotes: 6).quoteChain.map(\.restID) == ["2", "3", "4"])
    }

    @Test("Every layer is read aloud and can be opened on its own")
    @MainActor
    func everyLayerIsReachable() throws {
        let cell = TweetCell(frame: CGRect(x: 0, y: 0, width: 390, height: 300))
        var opened: [String] = []
        cell.onTapQuoted = { opened.append($0.restID) }
        cell.configure(with: try chain(quotes: 4), imagesEnabled: false, contentWidth: 390)
        let label = try #require(cell.accessibilityLabel)
        #expect(label.contains("Quoting Poster 2: text 2"))
        #expect(label.contains("Which quotes Poster 3: text 3"))
        #expect(label.contains("Which quotes Poster 4: text 4"))
        #expect(!label.contains("text 5"))
        let actions = try #require(cell.accessibilityCustomActions).filter { $0.name.contains("quoted") }
        #expect(actions.map(\.name) == [
            "Open quoted post", "Open post quoted by Poster 2", "Open post quoted by Poster 3",
        ])
        for action in actions { _ = action.actionHandler?(action) }
        #expect(opened == ["2", "3", "4"])
    }

    @Test("A recycled row drops the quote tree it showed")
    @MainActor
    func reuseClearsTheTree() throws {
        let cell = TweetCell(frame: CGRect(x: 0, y: 0, width: 390, height: 300))
        cell.configure(with: try chain(quotes: 3), imagesEnabled: false, contentWidth: 390)
        cell.prepareForReuse()
        cell.configure(with: try chain(quotes: 0), imagesEnabled: false, contentWidth: 390)
        let label = try #require(cell.accessibilityLabel)
        #expect(!label.contains("Quoting"))
        #expect(cell.accessibilityCustomActions?.contains { $0.name.contains("quoted") } == false)
    }
}
