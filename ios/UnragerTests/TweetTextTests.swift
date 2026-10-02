import Testing
import UIKit
import UnragerKit
@testable import Unrager

@MainActor
@Suite("Tweet body styling")
struct TweetTextTests {
    private func render(_ text: String, urls: [TweetURL] = []) -> NSAttributedString {
        TweetText.attributed(for: text, urls: urls, seen: false, font: .systemFont(ofSize: 16))
    }

    private func link(in text: NSAttributedString, at fragment: String) -> URL? {
        let range = (text.string as NSString).range(of: fragment)
        return text.attribute(.link, at: range.location, effectiveRange: nil) as? URL
    }

    @Test("A mention is linked without the comma that follows it")
    func mentionStopsAtPunctuation() {
        let text = render("thanks @alice, see you")
        let comma = (text.string as NSString).range(of: ",")
        #expect(text.attribute(.link, at: comma.location, effectiveRange: nil) == nil)
        #expect(link(in: text, at: "@alice")?.absoluteString == "unrager://profile/alice")
    }

    @Test("A hashtag is linked without a trailing exclamation mark")
    func hashtagStopsAtPunctuation() {
        let text = render("big news #rustlang!")
        let bang = (text.string as NSString).range(of: "!")
        #expect(text.attribute(.link, at: bang.location, effectiveRange: nil) == nil)
        #expect(link(in: text, at: "#rustlang")?.absoluteString == "unrager://hashtag/rustlang")
    }

    @Test("A web address at the end of a sentence doesn't take the full stop into the link")
    func urlStopsAtPunctuation() {
        let text = render("read https://example.com/a. Then reply")
        #expect(link(in: text, at: "https://example.com/a")?.absoluteString == "https://example.com/a")
        let stop = (text.string as NSString).range(of: ". ")
        #expect(text.attribute(.link, at: stop.location, effectiveRange: nil) == nil)
    }

    @Test("An address keeps its own closing bracket")
    func urlKeepsBalancedBracket() {
        let text = render("see https://en.wikipedia.org/wiki/Rust_(language).")
        #expect(link(in: text, at: "https://en.wikipedia.org/wiki/Rust_(language)")?.absoluteString
                == "https://en.wikipedia.org/wiki/Rust_(language)")
    }

    @Test("A shortened display address opens the expanded URL even with punctuation after it")
    func displayAddressExpands() throws {
        let entry = try UnragerJSON.decode(TweetURL.self, from: Data(
            #"{"expanded_url":"https://example.com/long","display_url":"example.com/long"}"#.utf8))
        let text = render("worth a look: example.com/long.", urls: [entry])
        #expect(link(in: text, at: "example.com/long")?.absoluteString == "https://example.com/long")
    }

    @Test("Leading mentions are stripped from a reply")
    func stripsLeadingMentions() {
        #expect(ReplyContext.strippingLeadingMentions("@a @b hello @c") == "hello @c")
    }
}
