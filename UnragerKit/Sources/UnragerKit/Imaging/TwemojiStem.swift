import Foundation
import CoreGraphics

extension TwemojiCache {
    /// Maps an emoji grapheme to its Twemoji PNG filename stem, replicating
    /// Twemoji's `grabTheRightIcon` rule (ported from the TUI's `twemoji_stem`):
    ///
    /// - if the sequence contains a ZWJ (U+200D), keep every codepoint;
    /// - otherwise strip every variation selector U+FE0F;
    /// - then lowercase-hex each remaining scalar (no zero-padding) and join
    ///   with `-`.
    ///
    /// A flag is just the no-ZWJ, no-FE0F case (`🇺🇸` → `1f1fa-1f1f8`); a family
    /// keeps its ZWJ joins; `❤️` strips FE0F to `2764`.
    public static func twemojiStem(for grapheme: String) -> String {
        let scalars = Array(grapheme.unicodeScalars)
        let hasZWJ = scalars.contains { $0.value == zeroWidthJoiner }
        return scalars
            .filter { hasZWJ || $0.value != variationSelector16 }
            .map { String($0.value, radix: 16) }
            .joined(separator: "-")
    }

    /// True when `grapheme` is a real emoji that should be image-composited
    /// rather than drawn as a native glyph. Mirrors the TUI's
    /// `is_emoji_grapheme`: false-positive-safe so bare ASCII digits, `#`, `*`,
    /// and lone text-presentation symbols are *not* treated as emoji.
    ///
    /// A single scalar must carry `isEmoji && isEmojiPresentation` (rules out
    /// bare digits / `#` / `*`, which are emoji-*capable* only with a keycap or
    /// FE0F). Multi-scalar clusters qualify when they're a flag (two regional
    /// indicators), a ZWJ sequence, a keycap, a skin-tone/variation-qualified
    /// emoji, or a tag sequence — the shapes Twemoji ships a single asset for.
    public static func isEmoji(_ grapheme: String) -> Bool {
        let scalars = Array(grapheme.unicodeScalars)
        guard let first = scalars.first else { return false }
        if scalars.count == 1 {
            return first.properties.isEmoji && first.properties.isEmojiPresentation
        }
        if scalars.allSatisfy({ regionalIndicators.contains($0.value) }) {
            return scalars.count == 2
        }
        if scalars.contains(where: { $0.value == zeroWidthJoiner }) { return true }
        if scalars.contains(where: { $0.value == combiningEnclosingKeycap }) {
            return first.properties.isEmoji
        }
        if scalars.contains(where: { $0.value == variationSelector16 }) {
            return first.properties.isEmoji
        }
        if scalars.contains(where: { skinToneModifiers.contains($0.value) }) {
            return first.properties.isEmoji
        }
        if scalars.contains(where: { tagSequenceRange.contains($0.value) }) {
            return first.properties.isEmoji
        }
        return false
    }

    static let zeroWidthJoiner: UInt32 = 0x200D
    static let variationSelector16: UInt32 = 0xFE0F
    static let combiningEnclosingKeycap: UInt32 = 0x20E3
    static let regionalIndicators: ClosedRange<UInt32> = 0x1F1E6...0x1F1FF
    static let skinToneModifiers: ClosedRange<UInt32> = 0x1F3FB...0x1F3FF
    static let tagSequenceRange: ClosedRange<UInt32> = 0xE0020...0xE007F
}

extension StringProtocol {
    /// Every grapheme cluster in the string that ``TwemojiCache/isEmoji(_:)``
    /// recognizes as an emoji, in order (duplicates included).
    public func emojiGraphemes() -> [String] {
        var result: [String] = []
        for character in self {
            let grapheme = String(character)
            if TwemojiCache.isEmoji(grapheme) { result.append(grapheme) }
        }
        return result
    }
}

/// Thread-safe in-memory stem → `CGImage` store backing the synchronous
/// `cachedImage` hot path (the owning ``TwemojiCache`` is an actor, but the feed
/// reads the cache without awaiting). `CGImage` is immutable and `Sendable`.
final class TwemojiMemoryCache: @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: CGImage] = [:]

    func image(forStem stem: String) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        return store[stem]
    }

    func set(_ image: CGImage, forStem stem: String) {
        lock.lock()
        store[stem] = image
        lock.unlock()
    }
}
