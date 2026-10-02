import Foundation
import Testing
@testable import Unrager

@Suite("In-app links")
struct XLinkTests {
    private func classify(_ address: String) throws -> XLink {
        XLink.classify(try #require(URL(string: address)))
    }

    @Test("Post addresses on every X host open the post", arguments: [
        "https://x.com/mirakoski/status/2110000000000008192",
        "https://twitter.com/mirakoski/status/2110000000000008192",
        "https://www.x.com/mirakoski/status/2110000000000008192",
        "https://mobile.twitter.com/mirakoski/status/2110000000000008192",
        "http://X.COM/MiraKoski/status/2110000000000008192",
        "https://x.com/mirakoski/status/2110000000000008192/",
        "https://x.com/mirakoski/status/2110000000000008192?s=20&t=abc",
        "https://x.com/mirakoski/status/2110000000000008192#reply",
        "https://x.com/mirakoski/status/2110000000000008192/photo/1",
        "https://x.com/mirakoski/status/2110000000000008192/video/1",
        "https://x.com/mirakoski/status/2110000000000008192/analytics",
        "https://x.com/i/web/status/2110000000000008192",
        "https://twitter.com/mirakoski/statuses/2110000000000008192",
    ])
    func posts(address: String) throws {
        #expect(try classify(address) == .post(id: "2110000000000008192"))
    }

    @Test("Profile addresses open the profile, keeping the handle as written")
    func profiles() throws {
        #expect(try classify("https://x.com/mirakoski") == .profile(handle: "mirakoski"))
        #expect(try classify("https://twitter.com/MiraKoski/") == .profile(handle: "MiraKoski"))
        #expect(try classify("https://mobile.x.com/kit_wren?lang=en") == .profile(handle: "kit_wren"))
    }

    @Test("X's own pages, other hosts, t.co and odd shapes stay web links", arguments: [
        "https://x.com/home", "https://x.com/explore", "https://x.com/i/bookmarks", "https://x.com/search?q=a",
        "https://x.com/settings", "https://x.com/notifications", "https://x.com/messages",
        "https://x.com/compose/post", "https://x.com/hashtag/swift", "https://x.com/intent/post?text=hi",
        "https://x.com/share", "https://x.com/login", "https://x.com/tos", "https://x.com/privacy",
        "https://x.com/", "https://x.com", "https://x.com/mirakoski/media", "https://x.com/mirakoski/status/abc",
        "https://x.com/mirakoski/status/", "https://x.com/this_handle_is_too_long",
        "https://t.co/AbC123", "https://example.com/mirakoski/status/1", "https://notx.com/mirakoski",
        "https://x.com.evil.example/mirakoski", "ftp://x.com/mirakoski", "mailto:hi@x.com",
    ])
    func web(address: String) throws {
        let url = try #require(URL(string: address))
        #expect(XLink.classify(url) == .web(url))
    }

    @Test("Pasted text names a post or profile, or nothing to search for")
    func pasted() {
        #expect(XLink.reference(in: "  https://x.com/mirakoski/status/42?s=20  ") == .post(id: "42"))
        #expect(XLink.reference(in: "x.com/mirakoski/status/42") == .post(id: "42"))
        #expect(XLink.reference(in: "look at this (https://twitter.com/kitwren/status/7)") == .post(id: "7"))
        #expect(XLink.reference(in: "@kitwren") == .profile(handle: "kitwren"))
        #expect(XLink.reference(in: "twitter.com/KitWren") == .profile(handle: "KitWren"))
        #expect(XLink.reference(in: "@kitwren bread") == nil)
        #expect(XLink.reference(in: "sourdough starter") == nil)
        #expect(XLink.reference(in: "https://example.com/a/status/1") == nil)
        #expect(XLink.reference(in: "") == nil)
    }
}
