import Foundation
import Testing
@testable import UnragerKit

@Suite("Twemoji stem derivation and emoji detection")
struct TwemojiTests {
    @Test("Country flags map to two regional-indicator codepoints")
    func flagStems() {
        #expect(TwemojiCache.twemojiStem(for: "🇫🇷") == "1f1eb-1f1f7")
        #expect(TwemojiCache.twemojiStem(for: "🇺🇸") == "1f1fa-1f1f8")
        #expect(TwemojiCache.twemojiStem(for: "🇯🇵") == "1f1ef-1f1f5")
    }

    @Test("Single-codepoint emoji map to one lowercase-hex scalar")
    func singleStems() {
        #expect(TwemojiCache.twemojiStem(for: "🔥") == "1f525")
        #expect(TwemojiCache.twemojiStem(for: "👍") == "1f44d")
    }

    @Test("FE0F is stripped when there is no ZWJ")
    func stripsVariationSelector() {
        #expect(TwemojiCache.twemojiStem(for: "❤️") == "2764")
        #expect(TwemojiCache.twemojiStem(for: "☺️") == "263a")
    }

    @Test("Keycap keeps the enclosing keycap but strips FE0F")
    func keycapStem() {
        #expect(TwemojiCache.twemojiStem(for: "1️⃣") == "31-20e3")
    }

    @Test("Skin-tone modifier is preserved")
    func skinToneStem() {
        #expect(TwemojiCache.twemojiStem(for: "👍🏿") == "1f44d-1f3ff")
    }

    @Test("ZWJ sequences keep every joiner")
    func zwjStem() {
        #expect(TwemojiCache.twemojiStem(for: "👨‍👩‍👧‍👦")
            == "1f468-200d-1f469-200d-1f467-200d-1f466")
    }

    @Test("Emoji are detected, plain text is not")
    func detection() {
        #expect(TwemojiCache.isEmoji("🔥"))
        #expect(TwemojiCache.isEmoji("🇺🇸"))
        #expect(TwemojiCache.isEmoji("❤️"))
        #expect(TwemojiCache.isEmoji("👨‍👩‍👧‍👦"))
        #expect(TwemojiCache.isEmoji("1️⃣"))
        #expect(!TwemojiCache.isEmoji("a"))
        #expect(!TwemojiCache.isEmoji("1"))
        #expect(!TwemojiCache.isEmoji("#"))
        #expect(!TwemojiCache.isEmoji("*"))
        #expect(!TwemojiCache.isEmoji(" "))
        #expect(!TwemojiCache.isEmoji("漢"))
    }

    @Test("Emoji graphemes are extracted in order across mixed text")
    func extraction() {
        let graphemes = "hi 🔥 there 🇯🇵 and #tag 123".emojiGraphemes()
        #expect(graphemes == ["🔥", "🇯🇵"])
        #expect("just words and #hashtags 123".emojiGraphemes().isEmpty)
    }
}
