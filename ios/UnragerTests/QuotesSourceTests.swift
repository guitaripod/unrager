import Foundation
import Testing
import UIKit
import UnragerKit
@testable import Unrager

@Suite("Quotes feed")
struct QuotesSourceTests {
    private func tweet(quotes: Int) throws -> Tweet {
        let json = """
        {"rest_id":"1","author":{"rest_id":"2","handle":"a","name":"Ada","verified":false,
          "followers":0,"following":0},"created_at":"2026-06-19T12:00:00Z","text":"hi",
          "reply_count":0,"retweet_count":0,"like_count":0,"quote_count":\(quotes),"bookmark_count":0,
          "url":"https://x.com/a/status/1"}
        """
        return try UnragerJSON.decode(Tweet.self, from: Data(json.utf8))
    }

    @Test("A post's quotes are their own cached, unfiltered feed with its own empty state")
    @MainActor
    func source() {
        let source = TimelineViewModel.Source.quotes(tweetID: "42")
        #expect(source.cacheKey == "quotes-42")
        #expect(source != .quotes(tweetID: "43"))
        let model = TimelineViewModel(source: source)
        #expect(!model.usesFilterCollect)
        #expect(!model.supportsSeenTracking)
        #expect(!model.awaitingQuery)
        #expect(model.emptyContent.title == "No quotes yet")
    }

    @Test("VoiceOver offers View quotes only for a quoted post on a screen that can list them")
    @MainActor
    func spokenAction() throws {
        let cell = TweetCell(frame: CGRect(x: 0, y: 0, width: 390, height: 300))
        cell.onViewQuotes = {}
        cell.configure(with: try tweet(quotes: 3), imagesEnabled: false, contentWidth: 390)
        #expect(cell.accessibilityCustomActions?.contains { $0.name == "View quotes" } == true)
        cell.configure(with: try tweet(quotes: 0), imagesEnabled: false, contentWidth: 390)
        #expect(cell.accessibilityCustomActions?.contains { $0.name == "View quotes" } == false)
        cell.prepareForReuse()
        cell.configure(with: try tweet(quotes: 3), imagesEnabled: false, contentWidth: 390)
        #expect(cell.accessibilityCustomActions?.contains { $0.name == "View quotes" } == false)
    }
}
