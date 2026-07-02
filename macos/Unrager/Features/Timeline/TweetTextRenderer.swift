import AppKit
import UnragerKit

/// Builds the attributed body string for a tweet, mirroring the TUI's
/// `highlight_text` / `push_word` tokenizer: `@handle` runs get the author's
/// deterministic `handleColor`, `#hashtag` runs get the accent, and bare URLs
/// become tappable `.link` attributes resolved through the tweet's `urls`
/// (t.co → expanded). Plain text is left untinted. Whitespace is preserved
/// exactly so wrapping matches the unstyled string.
enum TweetTextRenderer {
    /// Renders `tweet.text` into an attributed string. When `stripLeadingMentions`
    /// is set (reply rows), the leading `@a @b ` run is dropped so the body reads
    /// cleanly — matching the TUI's `strip_leading_mentions`.
    static func body(for tweet: Tweet, font: NSFont, color: NSColor,
                     stripLeadingMentions: Bool = false) -> NSAttributedString {
        let text = stripLeadingMentions ? self.stripLeadingMentions(tweet.text) : tweet.text
        return attributed(text, font: font, color: color, urls: tweet.urls)
    }

    /// Renders an arbitrary body string (e.g. a quoted tweet) with the same
    /// tokenizer but no link resolution beyond bare `http(s)://` URLs.
    static func plain(_ text: String, font: NSFont, color: NSColor,
                      urls: [TweetURL] = []) -> NSAttributedString {
        attributed(text, font: font, color: color, urls: urls)
    }

    private static func attributed(_ text: String, font: NSFont, color: NSColor,
                                   urls: [TweetURL]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let expansion = expansionMap(urls)

        var wordStart = text.startIndex
        var i = text.startIndex
        func flushWord(_ end: String.Index) {
            guard wordStart < end else { return }
            result.append(styledWord(String(text[wordStart..<end]), base: base,
                                     font: font, expansion: expansion))
        }
        while i < text.endIndex {
            let ch = text[i]
            if ch == " " || ch == "\t" || ch == "\n" {
                flushWord(i)
                result.append(NSAttributedString(string: String(ch), attributes: base))
                wordStart = text.index(after: i)
            }
            i = text.index(after: i)
        }
        flushWord(text.endIndex)
        TwemojiText.substituteCachedEmoji(in: result, font: font)
        return result
    }

    private static func styledWord(_ word: String, base: [NSAttributedString.Key: Any],
                                   font: NSFont, expansion: [String: String]) -> NSAttributedString {
        if word.hasPrefix("@"), word.count > 1 {
            let handle = trailingTrim(String(word.dropFirst()))
            let tint = handle.isEmpty ? DesignSystem.Color.accent : DesignSystem.handleColor(handle)
            return NSAttributedString(string: word, attributes: [.font: font, .foregroundColor: tint])
        }
        if word.hasPrefix("#"), word.count > 1 {
            return NSAttributedString(string: word, attributes: [.font: font, .foregroundColor: DesignSystem.Color.hashtag])
        }
        if word.hasPrefix("http://") || word.hasPrefix("https://") {
            return linkWord(word, target: expansion[word] ?? word, font: font)
        }
        if let target = expansion[word] {
            return linkWord(word, target: target, font: font)
        }
        return NSAttributedString(string: word, attributes: base)
    }

    /// A tinted, tappable link run. `word` is usually a scheme-less display URL
    /// — the server rewrites every t.co link in the body to X's display form
    /// (`example.com/article…`), so matching only `http(s)://` prefixes would
    /// leave every in-body link dead. The display token resolves to its expanded
    /// target through the tweet's url entities, mirroring iOS `TweetText.classify`.
    private static func linkWord(_ word: String, target: String, font: NSFont) -> NSAttributedString {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: DesignSystem.Color.link,
        ]
        if let url = URL(string: target) { attrs[.link] = url }
        return NSAttributedString(string: word, attributes: attrs)
    }

    /// Drops a trailing run of characters that aren't part of a handle/hashtag
    /// token (e.g. punctuation following `@user,`).
    private static func trailingTrim(_ s: String) -> String {
        String(s.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
    }

    /// Maps each t.co URL the model carries to its expanded target so a tapped
    /// link opens the real destination rather than the shortener.
    private static func expansionMap(_ urls: [TweetURL]) -> [String: String] {
        var map: [String: String] = [:]
        for url in urls where !url.expandedURL.isEmpty {
            map[url.displayURL] = url.expandedURL
            map[url.expandedURL] = url.expandedURL
        }
        return map
    }

    /// Drops leading `@handle` runs from the start of a reply body so it reads
    /// without the addressed-to prefix. Mirrors the TUI's `strip_leading_mentions`.
    static func stripLeadingMentions(_ text: String) -> String {
        var s = Substring(text).drop { $0 == " " || $0 == "\t" || $0 == "\n" }
        while s.first == "@" {
            let rest = s.dropFirst()
            let handle = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            if handle.isEmpty { break }
            s = rest.dropFirst(handle.count).drop { $0 == " " || $0 == "\t" || $0 == "\n" }
        }
        return String(s)
    }
}
