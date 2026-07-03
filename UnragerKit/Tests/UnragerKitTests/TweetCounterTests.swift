import Testing
@testable import UnragerKit

@Suite("Weighted tweet counter")
struct TweetCounterTests {
    @Test("Plain ASCII counts one per character")
    func ascii() {
        #expect(TweetCounter.weightedLength(of: "") == 0)
        #expect(TweetCounter.weightedLength(of: "hello world") == 11)
        #expect(TweetCounter.weightedLength(of: String(repeating: "a", count: 280)) == 280)
        #expect(TweetCounter.remaining(for: String(repeating: "a", count: 280)) == 0)
        #expect(TweetCounter.remaining(for: String(repeating: "a", count: 281)) == -1)
    }

    @Test("Any URL counts as a flat 23 regardless of length")
    func urls() {
        #expect(TweetCounter.weightedLength(of: "https://example.com") == 23)
        #expect(TweetCounter.weightedLength(
            of: "https://example.com/a/very/long/path/that/keeps/going?with=query&params=1") == 23)
        #expect(TweetCounter.weightedLength(of: "check this https://example.com/aaaa out") == 11 + 23 + 4)
        #expect(TweetCounter.weightedLength(of: "https://a.io https://b.io") == 23 + 1 + 23)
    }

    @Test("Bare domains are linkified and count 23")
    func bareDomain() {
        #expect(TweetCounter.weightedLength(of: "example.com") == 23)
    }

    @Test("Emails are plain text, not links")
    func email() {
        #expect(TweetCounter.weightedLength(of: "mail me at hi@example.com") == 25)
    }

    @Test("CJK weighs 2 per character")
    func cjk() {
        #expect(TweetCounter.weightedLength(of: "日本語") == 6)
        #expect(TweetCounter.weightedLength(of: "ツイート") == 8)
        #expect(TweetCounter.weightedLength(of: "hi 日本") == 3 + 4)
        #expect(TweetCounter.remaining(for: String(repeating: "あ", count: 140)) == 0)
    }

    @Test("Every emoji sequence weighs a flat 2")
    func emoji() {
        #expect(TweetCounter.weightedLength(of: "👍") == 2)
        #expect(TweetCounter.weightedLength(of: "❤️") == 2)
        #expect(TweetCounter.weightedLength(of: "👨‍👩‍👧‍👦") == 2)
        #expect(TweetCounter.weightedLength(of: "🇫🇮") == 2)
        #expect(TweetCounter.weightedLength(of: "1️⃣") == 2)
        #expect(TweetCounter.weightedLength(of: "👍🏽") == 2)
        #expect(TweetCounter.weightedLength(of: "hi 👍") == 3 + 2)
    }

    @Test("Bare digits and symbols that have emoji variants stay weight 1")
    func nonEmojiLookalikes() {
        #expect(TweetCounter.weightedLength(of: "123") == 3)
        #expect(TweetCounter.weightedLength(of: "#tag *star*") == 11)
    }

    @Test("Accented Latin composes to weight 1; other scripts weigh 2")
    func normalization() {
        #expect(TweetCounter.weightedLength(of: "héllo") == 5)
        #expect(TweetCounter.weightedLength(of: "cafe\u{0301}") == 4)
        #expect(TweetCounter.weightedLength(of: "안녕") == 4)
    }
}
