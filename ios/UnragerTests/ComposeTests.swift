import Foundation
import Testing
import UIKit
import UnragerKit
@testable import Unrager

@Suite("Composer")
struct ComposeTests {
    private func tweet(id: String) throws -> Tweet {
        let json = """
        {"rest_id":"\(id)","author":{"rest_id":"2","handle":"a","name":"A","verified":false,
          "followers":0,"following":0},"created_at":"2026-06-19T12:00:00Z","text":"hi",
          "reply_count":0,"retweet_count":0,"like_count":0,"quote_count":0,
          "bookmark_count":0,"url":"https://x.com/a/status/\(id)"}
        """
        return try UnragerJSON.decode(Tweet.self, from: Data(json.utf8))
    }

    private func store() throws -> ComposeDraftStore {
        let defaults = try #require(UserDefaults(suiteName: "compose-tests-\(UUID().uuidString)"))
        return ComposeDraftStore(defaults: defaults)
    }

    @Test("A swipe or Cancel while a post is sending leaves the composer up")
    @MainActor
    func noDismissWhilePosting() {
        #expect(ComposeViewController.dismissal(hasContent: true, isPosting: true) == .stay)
        #expect(ComposeViewController.dismissal(hasContent: false, isPosting: true) == .stay)
        #expect(ComposeViewController.dismissal(hasContent: true, isPosting: false) == .confirm)
        #expect(ComposeViewController.dismissal(hasContent: false, isPosting: false) == .close)
    }

    @Test("Drafts come back for the same place they were written for, and only there")
    @MainActor
    func draftsBySlot() throws {
        let drafts = try store()
        let post = try tweet(id: "42")
        let reply = ComposeDraftStore.slot(for: .reply(to: post))
        drafts.save("thinking about it", for: reply)
        #expect(drafts.draft(for: reply) == "thinking about it")
        #expect(drafts.draft(for: ComposeDraftStore.slot(for: .quote(of: post))) == nil)
        #expect(drafts.draft(for: ComposeDraftStore.slot(for: .new)) == nil)
        drafts.save("second go", for: reply)
        #expect(drafts.draft(for: reply) == "second go")
        drafts.clear(reply)
        #expect(drafts.draft(for: reply) == nil)
    }

    @Test("Blank text clears a draft, and only the newest drafts are kept")
    func draftCapacity() throws {
        let drafts = try store()
        drafts.save("keep", for: "new")
        drafts.save("   ", for: "new")
        #expect(drafts.draft(for: "new") == nil)
        for index in 0...ComposeDraftStore.capacity { drafts.save("draft \(index)", for: "reply-\(index)") }
        #expect(drafts.draft(for: "reply-0") == nil)
        #expect(drafts.draft(for: "reply-\(ComposeDraftStore.capacity)") == "draft \(ComposeDraftStore.capacity)")
    }

    @Test("The composer says post, not tweet")
    @MainActor
    func wording() {
        let compose = ComposeViewController(mode: .new)
        compose.loadViewIfNeeded()
        #expect(compose.title == "New Post")
        #expect(compose.navigationItem.rightBarButtonItems?.first?.title == "Post")
    }
}
