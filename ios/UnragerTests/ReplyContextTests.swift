import Foundation
import Testing
import UnragerKit
@testable import Unrager

@Suite("Reply context")
struct ReplyContextTests {
    private func tweet(
        text: String, handle: String = "me", replyTo: String? = nil, replyHandle: String? = nil,
        media: Bool = false
    ) throws -> Tweet {
        var fields = """
        "rest_id":"5","author":{"rest_id":"2","handle":"\(handle)","name":"A","verified":false,
          "followers":0,"following":0},"created_at":"2026-06-19T12:00:00Z","text":"\(text)",
        "reply_count":0,"retweet_count":0,"like_count":0,"quote_count":0,
        "url":"https://x.com/a/status/5"
        """
        if let replyTo { fields += ",\"in_reply_to_tweet_id\":\"\(replyTo)\"" }
        if let replyHandle { fields += ",\"in_reply_to_handle\":\"\(replyHandle)\"" }
        if media {
            fields += ",\"media\":[{\"kind\":\"photo\",\"url\":\"https://pbs.twimg.com/m.jpg\"}]"
        }
        return try UnragerJSON.decode(Tweet.self, from: Data("{\(fields)}".utf8))
    }

    @Test("A reply's leading mentions come out of its text, mentions further in stay")
    func stripsOnlyTheLeadingRun() throws {
        let reply = try tweet(text: "@a @b thanks, cc @c", replyTo: "1", replyHandle: "a")
        #expect(ReplyContext.body(of: reply) == "thanks, cc @c")
    }

    @Test("A post that is not a reply keeps a mention at its start")
    func plainPostIsUntouched() throws {
        let post = try tweet(text: "@a look at this")
        #expect(ReplyContext.body(of: post) == "@a look at this")
        #expect(ReplyContext.caption(for: post, implied: nil) == nil)
    }

    @Test("A reply of nothing but mentions keeps them, unless it has media")
    func nothingButMentions() throws {
        #expect(ReplyContext.body(of: try tweet(text: "@a @b", replyTo: "1")) == "@a @b")
        #expect(ReplyContext.body(of: try tweet(text: "@a @b", replyTo: "1", media: true)) == "")
    }

    @Test("Addressees list the account answered first, then others tagged, each once")
    func addresseeOrder() throws {
        let reply = try tweet(text: "@B @a @c hi", replyTo: "1", replyHandle: "a")
        #expect(ReplyContext.addressees(of: reply) == ["a", "B", "c"])
    }

    @Test("A reply on its own names who it answers")
    func standaloneNamesTheAddressee() throws {
        let reply = try tweet(text: "@alice agreed", replyTo: "1", replyHandle: "alice")
        let caption = try #require(ReplyContext.caption(for: reply, implied: nil))
        #expect(ReplyContext.sentence(for: caption) == "Replying to @alice")
    }

    @Test("Two, then more, are summed up")
    func severalAddressees() throws {
        let two = try tweet(text: "@a @b hi", replyTo: "1", replyHandle: "a")
        #expect(ReplyContext.sentence(for: try #require(ReplyContext.caption(for: two, implied: nil)))
                == "Replying to @a and @b")
        let four = try tweet(text: "@a @b @c @d hi", replyTo: "1", replyHandle: "a")
        #expect(ReplyContext.sentence(for: try #require(ReplyContext.caption(for: four, implied: nil)))
                == "Replying to @a, @b and 2 others")
        let three = try tweet(text: "@a @b @c hi", replyTo: "1", replyHandle: "a")
        #expect(ReplyContext.sentence(for: try #require(ReplyContext.caption(for: three, implied: nil)))
                == "Replying to @a, @b and 1 other")
    }

    @Test("A reply to your own post says it continues a thread")
    func selfThread() throws {
        let reply = try tweet(text: "and another thing", handle: "me", replyTo: "1", replyHandle: "me")
        #expect(ReplyContext.caption(for: reply, implied: nil)?.lead == "Continuing thread")
    }

    @Test("A reply with no known addressee is still marked as a reply")
    func unknownAddressee() throws {
        let reply = try tweet(text: "no tags here", replyTo: "1")
        #expect(ReplyContext.caption(for: reply, implied: nil)?.lead == "Reply")
    }

    @Test("Under its parent in a thread a reply needs no caption")
    func underItsParent() throws {
        let reply = try tweet(text: "@alice agreed", replyTo: "1", replyHandle: "alice")
        #expect(ReplyContext.caption(for: reply, implied: ["alice"]) == nil)
    }

    @Test("Under its parent, a reply still names anyone else it tags")
    func underItsParentWithExtraPeople() throws {
        let reply = try tweet(text: "@alice @bob agreed", replyTo: "1", replyHandle: "alice")
        let caption = try #require(ReplyContext.caption(for: reply, implied: ["alice"]))
        #expect(ReplyContext.sentence(for: caption) == "Also replying to @bob")
    }

    @Test("A reply to your own post in a thread needs no caption either")
    func selfThreadInAThread() throws {
        let reply = try tweet(text: "more", handle: "me", replyTo: "1", replyHandle: "me")
        #expect(ReplyContext.caption(for: reply, implied: ["me"]) == nil)
    }
}
