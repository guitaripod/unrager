import Foundation

/// X's weighted tweet-length rules (twitter-text v3): the composer's
/// 280-character budget counts every URL as a flat 23, most Western scripts as
/// 1 per NFC code point, CJK and other wide scripts as 2, and any emoji
/// sequence (ZWJ families, flags, keycaps, variation selectors) as a flat 2 —
/// so a link-heavy draft isn't falsely over-limit and a CJK draft isn't
/// falsely under it.
public enum TweetCounter {
    public static let maxWeightedLength = 280

    static let urlWeight = 23

    /// The code-point ranges twitter-text weighs at 1; everything else weighs 2.
    private static let lightRanges: [ClosedRange<UInt32>] = [
        0...4351, 8192...8205, 8208...8223, 8242...8247,
    ]

    public static func weightedLength(of text: String) -> Int {
        let normalized = text.precomposedStringWithCanonicalMapping
        var total = 0
        var cursor = normalized.startIndex
        for range in urlRanges(in: normalized) {
            total += weight(of: normalized[cursor..<range.lowerBound])
            total += urlWeight
            cursor = range.upperBound
        }
        total += weight(of: normalized[cursor...])
        return total
    }

    public static func remaining(for text: String) -> Int {
        maxWeightedLength - weightedLength(of: text)
    }

    /// Detected URL ranges, in order. Emails are excluded — X renders them as
    /// plain text, not t.co links.
    private static func urlRanges(in text: String) -> [Range<String.Index>] {
        guard !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return [] }
        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector.matches(in: text, options: [], range: full).compactMap { match in
            guard match.url?.scheme?.lowercased() != "mailto" else { return nil }
            return Range(match.range, in: text)
        }
    }

    private static func weight(of text: Substring) -> Int {
        var total = 0
        for character in text {
            if isEmoji(character) {
                total += 2
            } else {
                for scalar in character.unicodeScalars {
                    total += lightRanges.contains { $0.contains(scalar.value) } ? 1 : 2
                }
            }
        }
        return total
    }

    /// Whether a grapheme cluster is an emoji sequence (weighed as a flat 2).
    /// A lone default-text scalar like `1` or `#` is not, but the same scalar
    /// followed by a variation selector / combining keycap / ZWJ partner is.
    private static func isEmoji(_ character: Character) -> Bool {
        let scalars = character.unicodeScalars
        if scalars.contains(where: { $0.properties.isEmojiPresentation }) { return true }
        return scalars.count > 1 && scalars.first?.properties.isEmoji == true
    }
}
