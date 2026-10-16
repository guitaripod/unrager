import Foundation
import Testing
import UIKit
import UnragerKit
@testable import Unrager

@Suite("Liked-by list")
struct LikersLogicTests {
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
        #expect(row.followsMe == nil)
        #expect(row.bio == "Builds things")
        #expect(row.followers == 1)
    }

    @Test("A post is quoted on one line, and a blank one is not quoted at all")
    func postLine() {
        #expect(LikersViewController.post(from: "two   lines\nof text") == "two lines of text")
        #expect(LikersViewController.post(from: "  \n ") == nil)
    }
}
