import UIKit
import UnragerKit

/// Substitutes Twemoji images for emoji graphemes in an attributed body so the
/// iPhone app renders X's flat Twemoji art (most visibly country flags) instead
/// of Apple's system color-emoji glyphs, matching the TUI.
///
/// The feed builds bodies synchronously on the main thread during cell
/// configuration, which must never block on the network. The synchronous entry
/// point substitutes **cache hits only** (``TwemojiCache/cachedImage(for:)`` —
/// pure memory, no I/O) and kicks off background fetches for misses, leaving the
/// native glyph in place until the image lands. ``TwemojiCache/imagesDidLoad``
/// then fires so the owning view can re-render the affected rows off the scroll
/// path. Prewarm during prefetch with ``TwemojiCache/prewarm(graphemesIn:)`` so
/// most cells hit on first display.
enum TwemojiText {
    /// Walks `string`, replacing every emoji grapheme that has a cached Twemoji
    /// image with an inline `NSTextAttachment` sized to `font`'s line, and
    /// schedules a background fetch for the misses. Mutates in place. Runs back
    /// to front so each replacement leaves the not-yet-processed prefix ranges
    /// valid.
    @MainActor
    static func substituteCachedEmoji(in string: NSMutableAttributedString, font: UIFont) {
        let ns = string.string as NSString
        guard ns.length > 0, !isPlainASCII(string.string) else { return }
        var replacements: [(NSRange, CGImage)] = []
        var misses: Set<String> = []

        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                               options: .byComposedCharacterSequences) { substring, range, _, _ in
            guard let substring, TwemojiCache.isEmoji(substring) else { return }
            if let image = TwemojiCache.shared.cachedImage(for: substring) {
                replacements.append((range, image))
            } else {
                misses.insert(substring)
            }
        }

        for (range, image) in replacements.reversed() {
            string.replaceCharacters(in: range, with: attachmentString(image, font: font))
        }

        guard !misses.isEmpty else { return }
        let pending = misses.joined()
        Task { await TwemojiCache.shared.prewarm(graphemesIn: pending) }
    }

    /// The emoji graphemes in `texts` whose Twemoji art is not in memory yet, so
    /// a view knows which arrivals would change what it shows.
    @MainActor
    static func uncachedEmoji(in texts: [String]) -> Set<String> {
        var missing: Set<String> = []
        for text in texts where !text.isEmpty && !isPlainASCII(text) {
            for character in text {
                let grapheme = String(character)
                guard TwemojiCache.isEmoji(grapheme), TwemojiCache.shared.cachedImage(for: grapheme) == nil else { continue }
                missing.insert(grapheme)
            }
        }
        return missing
    }

    /// Whether any of `graphemes` now has its Twemoji art in memory.
    @MainActor
    static func anyCached(_ graphemes: Set<String>) -> Bool {
        graphemes.contains { TwemojiCache.shared.cachedImage(for: $0) != nil }
    }

    /// Whether `text` is plain ASCII, which holds no emoji: most posts, and
    /// walking their graphemes one by one would be the bulk of building them.
    private static func isPlainASCII(_ text: String) -> Bool {
        var text = text
        return text.withUTF8 { $0.allSatisfy { $0 < 0x80 } }
    }

    /// `text` in `font` and `color` with every emoji whose Twemoji art is cached
    /// shown as that art, like post bodies, so a name or flag matches X's own
    /// rendering instead of the system glyphs.
    @MainActor
    static func attributed(_ text: String, font: UIFont, color: UIColor) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        substituteCachedEmoji(in: result, font: font)
        return result
    }

    /// An attributed string holding a single emoji attachment sized so the
    /// glyph's height matches the surrounding text's cap-to-descender box and
    /// sits on the baseline like a native emoji.
    @MainActor
    private static func attachmentString(_ image: CGImage, font: UIFont) -> NSAttributedString {
        let attachment = NSTextAttachment()
        let screenScale = UITraitCollection.current.displayScale
        attachment.image = UIImage(cgImage: image, scale: screenScale > 0 ? screenScale : 3, orientation: .up)
        let side = font.lineHeight * 0.92
        let descent = font.descender
        attachment.bounds = CGRect(x: 0, y: descent, width: side, height: side)
        return NSAttributedString(attachment: attachment)
    }
}
