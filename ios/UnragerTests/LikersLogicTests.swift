import Foundation
import Testing
import UIKit
import UnragerKit
@testable import Unrager

@Suite("Liked-by list")
struct LikersLogicTests {
    private func tweet(text: String, likes: Int) throws -> Tweet {
        let json = """
        {"rest_id":"1","author":{"rest_id":"2","handle":"ada","name":"Ada","verified":false,
          "followers":0,"following":0},"created_at":"2026-06-19T12:00:00Z","text":"\(text)",
          "reply_count":0,"retweet_count":0,"like_count":\(likes),"quote_count":0,
          "bookmark_count":0,"url":"https://x.com/ada/status/1"}
        """
        return try UnragerJSON.decode(Tweet.self, from: Data(json.utf8))
    }

    @Test("The heading counts the likes and names the post they are on")
    @MainActor
    func heading() throws {
        let heading = LikersViewController.heading(for: try tweet(text: "two   lines of text", likes: 14_800))
        #expect(heading.title == "\(14_800.formatted()) likes")
        #expect(heading.subtitle == "@ada: two lines of text")
        #expect(LikersViewController.heading(for: try tweet(text: "x", likes: 1)).title == "1 like")
    }

    @Test("A post with no text is named by its author")
    @MainActor
    func headingWithoutText() throws {
        let heading = LikersViewController.heading(for: try tweet(text: "", likes: 3))
        #expect(heading.subtitle == "A post by @ada")
    }

    @Test("A short list is flagged only when X lists fewer people than the likes")
    func endNote() {
        #expect(LikersViewController.endNote(shown: 5, of: 14_800) == "X lists 5 of the \(14_800.formatted()) people who liked this.")
        #expect(LikersViewController.endNote(shown: 20, of: 20) == nil)
        #expect(LikersViewController.endNote(shown: 20, of: nil) == nil)
        #expect(LikersViewController.endNote(shown: 0, of: 12) == nil)
    }

    @Test("A row follows what the list says, and a notification actor says nothing")
    func rowFollowState() throws {
        let json = #"{"rest_id":"7","handle":"bob","name":"Bob","verified":true,"followers":1,"following":2,"description":"Builds things","followed_by_me":false}"#
        let user = try UnragerJSON.decode(User.self, from: Data(json.utf8))
        let row = UserRow(user)
        #expect(row.following == false)
        #expect(row.bio == "Builds things")
    }
}
