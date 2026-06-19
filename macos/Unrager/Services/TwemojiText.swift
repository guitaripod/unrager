import AppKit
import UnragerKit

/// Substitutes Twemoji images for emoji graphemes in an attributed body so the
/// Mac app renders X's flat Twemoji art (most visibly country flags) instead of
/// Apple's system color-emoji glyphs, matching the TUI and the iOS client.
///
/// The synchronous entry point substitutes **cache hits only**
/// (``TwemojiCache/cachedImage(for:)`` — pure memory, no I/O) and kicks off
/// background fetches for misses, leaving the native glyph in place until the
/// image lands. ``TwemojiCache/imagesDidLoad`` fires when a batch arrives so the
/// owning view can re-render off the scroll path.
enum TwemojiText {
    /// Walks `string`, replacing every emoji grapheme that has a cached Twemoji
    /// image with an inline `NSTextAttachment` sized to `font`'s line, and
    /// schedules a background fetch for the misses. Mutates in place, back to
    /// front so unprocessed ranges stay valid.
    static func substituteCachedEmoji(in string: NSMutableAttributedString, font: NSFont) {
        let ns = string.string as NSString
        guard ns.length > 0 else { return }
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
        let pending = misses
        Task {
            for grapheme in pending {
                _ = await TwemojiCache.shared.image(for: grapheme)
            }
        }
    }

    /// A single emoji attachment sized so the glyph's height matches the
    /// surrounding text's line box and sits on the baseline.
    private static func attachmentString(_ image: CGImage, font: NSFont) -> NSAttributedString {
        let attachment = NSTextAttachment()
        let side = (font.ascender - font.descender) * 0.92
        let nsImage = NSImage(cgImage: image, size: NSSize(width: side, height: side))
        attachment.image = nsImage
        attachment.bounds = CGRect(x: 0, y: font.descender, width: side, height: side)
        return NSAttributedString(attachment: attachment)
    }
}
