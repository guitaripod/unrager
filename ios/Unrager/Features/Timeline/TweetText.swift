import UIKit
import UnragerKit

/// Builds the rich body string for a tweet: `@mentions` color-hashed to match
/// each author's header tint, `#hashtags` accented, and links tinted and made
/// tappable. Ported from the TUI's `highlight_text`/`push_word` tokenizer so the
/// native body reads with the same affordances. Tappable targets use the
/// `unrager://` scheme for in-app routing (profiles / search) and the real
/// expanded URL for links; a `UITextView` host routes them via its delegate.
enum TweetText {
    /// In-app routing schemes emitted as `.link` attributes on body runs.
    enum Route {
        case profile(handle: String)
        case hashtag(query: String)
        case url(URL)

        /// Decodes a tapped link back into a route, or nil for anything foreign.
        static func from(_ url: URL) -> Route? {
            guard url.scheme == "unrager" else { return .url(url) }
            switch url.host {
            case "profile":
                let handle = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                return handle.isEmpty ? nil : .profile(handle: handle)
            case "hashtag":
                let tag = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                return tag.isEmpty ? nil : .hashtag(query: "#" + tag)
            default:
                return nil
            }
        }
    }

    /// The tweet's display body: for a reply, without the leading `@mentions`
    /// X adds, which a caption sums up instead (see `ReplyContext`).
    static func displayText(for tweet: Tweet) -> String {
        ReplyContext.body(of: tweet)
    }

    @MainActor
    static func attributed(for tweet: Tweet, seen: Bool, font: UIFont) -> NSAttributedString {
        attributed(for: displayText(for: tweet), urls: tweet.urls, seen: seen, font: font)
    }

    /// Colours and links the `@mentions`, `#hashtags` and URLs in `text`. Only
    /// the mention, tag or address itself is styled: a comma or full stop that
    /// follows it stays plain, and out of the link.
    @MainActor
    static func attributed(
        for text: String, urls: [TweetURL], seen: Bool, font: UIFont
    ) -> NSAttributedString {
        let baseColor = seen ? DesignSystem.Color.secondaryLabel : DesignSystem.Color.label
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: baseColor,
        ])
        let display = expandedDisplayMap(urls)
        let ns = text as NSString
        for token in tokenRanges(in: text) {
            let word = ns.substring(with: token)
            guard let match = classify(word, display: display) else { continue }
            let range = NSRange(location: token.location, length: match.length)
            result.addAttribute(.foregroundColor, value: match.color, range: range)
            if let route = match.route, let link = link(for: route) {
                result.addAttribute(.link, value: link, range: range)
            }
        }
        TwemojiText.substituteCachedEmoji(in: result, font: font)
        return result
    }

    /// Maps a `t.co` display string (e.g. `example.com/x`) to its expanded URL so
    /// in-body link runs open the real destination.
    private static func expandedDisplayMap(_ urls: [TweetURL]) -> [String: URL] {
        var map: [String: URL] = [:]
        for entry in urls where !entry.displayURL.isEmpty {
            if let url = URL(string: entry.expandedURL) { map[entry.displayURL] = url }
        }
        return map
    }

    private static func tokenRanges(in text: String) -> [NSRange] {
        let ns = text as NSString
        var ranges: [NSRange] = []
        var start = 0
        var index = 0
        func flush(end: Int) {
            if start < end { ranges.append(NSRange(location: start, length: end - start)) }
        }
        while index < ns.length {
            let scalar = ns.character(at: index)
            if scalar == 0x20 || scalar == 0x09 || scalar == 0x0A {
                flush(end: index)
                start = index + 1
            }
            index += 1
        }
        flush(end: ns.length)
        return ranges
    }

    private struct Match {
        let color: UIColor
        let route: Route?
        /// How much of the word is styled, in UTF-16 units: the whole word for
        /// an address, `@handle` or `#tag` without what trails it.
        let length: Int
    }

    private static let trailingPunctuation = CharacterSet(charactersIn: ".,;:!?)]}'\"”’…")

    /// `word` without the sentence punctuation that followed it. A closing
    /// bracket stays when the word opened one, as in a wiki-style address.
    private static func trimmingTrailingPunctuation(_ word: String) -> String {
        var trimmed = Substring(word)
        while let last = trimmed.unicodeScalars.last, trailingPunctuation.contains(last) {
            if last == ")", trimmed.contains("(") { break }
            trimmed = trimmed.dropLast()
        }
        return String(trimmed)
    }

    /// Classifies a whitespace-delimited word the way the TUI's `push_word` does.
    @MainActor
    private static func classify(_ word: String, display: [String: URL]) -> Match? {
        if word.hasPrefix("@"), word.count > 1 {
            let handle = String(word.dropFirst()).prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            guard !handle.isEmpty else { return nil }
            return Match(color: DesignSystem.handleColor(String(handle)),
                         route: .profile(handle: String(handle)), length: 1 + handle.utf16.count)
        }
        if word.hasPrefix("#"), word.count > 1 {
            let tag = String(word.dropFirst()).prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            guard !tag.isEmpty else { return nil }
            return Match(color: DesignSystem.Color.hashtag, route: .hashtag(query: "#" + tag),
                         length: 1 + tag.utf16.count)
        }
        let address = trimmingTrailingPunctuation(word)
        if address.hasPrefix("http://") || address.hasPrefix("https://") {
            return Match(color: DesignSystem.Color.accent, route: URL(string: address).map(Route.url),
                         length: address.utf16.count)
        }
        if let url = display[address] ?? display[word] {
            return Match(color: DesignSystem.Color.accent, route: .url(url),
                         length: display[address] != nil ? address.utf16.count : word.utf16.count)
        }
        return nil
    }

    private static func link(for route: Route) -> URL? {
        switch route {
        case let .profile(handle):
            return URL(string: "unrager://profile/\(handle)")
        case let .hashtag(query):
            let tag = query.dropFirst()
            return URL(string: "unrager://hashtag/\(tag)")
        case let .url(url):
            return url
        }
    }
}
