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

    /// The tweet's display body, with leading `@mentions` stripped when shown as
    /// a reply (the TUI's `strip_leading_mentions`), mirroring X's clean reply
    /// rendering.
    static func displayText(for tweet: Tweet, stripLeadingMentions: Bool) -> String {
        guard stripLeadingMentions, tweet.inReplyToTweetID != nil else { return tweet.text }
        return strippingLeadingMentions(tweet.text)
    }

    @MainActor
    static func attributed(
        for tweet: Tweet, stripLeadingMentions: Bool, seen: Bool, font: UIFont
    ) -> NSAttributedString {
        let text = displayText(for: tweet, stripLeadingMentions: stripLeadingMentions)
        let baseColor = seen ? DesignSystem.Color.secondaryLabel : DesignSystem.Color.label
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: baseColor,
        ])
        let display = expandedDisplayMap(tweet.urls)
        let ranges = tokenRanges(in: text)
        for token in ranges {
            let substring = (text as NSString).substring(with: token)
            guard let (color, route) = classify(substring, display: display) else { continue }
            result.addAttribute(.foregroundColor, value: color, range: token)
            if let route, let link = link(for: route) {
                result.addAttribute(.link, value: link, range: token)
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

    /// Classifies a whitespace-delimited word the way the TUI's `push_word` does.
    @MainActor
    private static func classify(_ word: String, display: [String: URL]) -> (UIColor, Route?)? {
        if word.hasPrefix("@"), word.count > 1 {
            let handle = String(word.dropFirst()).prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            guard !handle.isEmpty else { return nil }
            return (DesignSystem.handleColor(String(handle)), .profile(handle: String(handle)))
        }
        if word.hasPrefix("#"), word.count > 1 {
            let tag = String(word.dropFirst()).prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            guard !tag.isEmpty else { return nil }
            return (DesignSystem.Color.hashtag, .hashtag(query: String(tag)))
        }
        if word.hasPrefix("http://") || word.hasPrefix("https://") {
            return (DesignSystem.Color.accent, URL(string: word).map(Route.url))
        }
        if let url = display[word] {
            return (DesignSystem.Color.accent, .url(url))
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
        for token in tokenRanges(in: text) {
            let substring = (text as NSString).substring(with: token)
            guard let (color, route) = classify(substring, display: display) else { continue }
            result.addAttribute(.foregroundColor, value: color, range: token)
            if let route, let link = link(for: route) {
                result.addAttribute(.link, value: link, range: token)
            }
        }
        TwemojiText.substituteCachedEmoji(in: result, font: font)
        return result
    }

    static func strippingLeadingMentions(_ text: String) -> String {
        var slice = Substring(text).drop { $0 == " " || $0 == "\n" || $0 == "\t" }
        while slice.first == "@" {
            let afterAt = slice.dropFirst()
            let handle = afterAt.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            if handle.isEmpty { break }
            slice = afterAt.dropFirst(handle.count).drop { $0 == " " || $0 == "\n" || $0 == "\t" }
        }
        return String(slice)
    }
}
