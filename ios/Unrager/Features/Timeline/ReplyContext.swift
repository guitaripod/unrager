import Foundation
import UnragerKit

/// How a reply says whom it answers. X puts "@a @b " in front of a reply's
/// text; here that prefix is taken out of the text and, only where the layout
/// doesn't already show who the reply is to, summed up in a short caption.
enum ReplyContext {
    /// The caption above a reply's text: a lead-in, the people it names, and how
    /// many more there are.
    struct Caption: Equatable {
        static let namedLimit = 2

        var lead: String
        var handles: [String] = []
        var others = 0
    }

    /// The handles at the very start of `text`, in order: the part X adds for
    /// you when you reply.
    static func leadingMentions(in text: String) -> [String] {
        splitLeadingMentions(text).handles
    }

    /// `text` without its leading mentions.
    static func strippingLeadingMentions(_ text: String) -> String {
        splitLeadingMentions(text).rest
    }

    private static func splitLeadingMentions(_ text: String) -> (handles: [String], rest: String) {
        var handles: [String] = []
        var slice = Substring(text).drop(while: \.isWhitespace)
        while slice.first == "@" {
            let afterAt = slice.dropFirst()
            let handle = afterAt.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            if handle.isEmpty { break }
            handles.append(String(handle))
            slice = afterAt.dropFirst(handle.count).drop(while: \.isWhitespace)
        }
        return (handles, String(slice))
    }

    /// Everyone a reply is addressed to: the account it answers first, then any
    /// others tagged at the start, each once.
    static func addressees(of tweet: Tweet) -> [String] {
        guard tweet.inReplyToTweetID != nil else { return [] }
        var seen = Set<String>()
        return ([tweet.inReplyToHandle].compactMap { $0 } + leadingMentions(in: tweet.text))
            .filter { seen.insert($0.lowercased()).inserted }
    }

    /// What to show as the post's text: for a reply, without the leading
    /// mentions. A reply that is nothing but mentions keeps them unless it has
    /// media to show, so it never reads as empty.
    static func body(of tweet: Tweet) -> String {
        guard tweet.inReplyToTweetID != nil else { return tweet.text }
        let stripped = strippingLeadingMentions(tweet.text)
        return stripped.isEmpty && tweet.media.isEmpty ? tweet.text : stripped
    }

    /// The caption for `tweet`, or nil when none is needed.
    ///
    /// `implied` holds the handles (lower case) whose posts the layout already
    /// shows this reply under — the post above it in a thread — or is nil when
    /// the reply stands alone, as in a feed or on a profile. A reply under its
    /// parent needs nothing but anyone else it tags; a lone reply names
    /// everyone, or says it continues the author's own thread.
    static func caption(for tweet: Tweet, implied: Set<String>?) -> Caption? {
        guard tweet.inReplyToTweetID != nil else { return nil }
        let author = tweet.author.handle.lowercased()
        let addressees = addressees(of: tweet)
        let others = addressees.filter { $0.lowercased() != author }
        if let implied {
            let extra = others.filter { !implied.contains($0.lowercased()) }
            return extra.isEmpty ? nil : naming(extra, lead: "Also replying to")
        }
        if others.isEmpty {
            return Caption(lead: addressees.isEmpty ? "Reply" : "Continuing thread")
        }
        return naming(others, lead: "Replying to")
    }

    private static func naming(_ handles: [String], lead: String) -> Caption {
        Caption(lead: lead, handles: Array(handles.prefix(Caption.namedLimit)),
                others: max(0, handles.count - Caption.namedLimit))
    }

    /// The caption as plain words: "Replying to @a and @b", "Replying to @a, @b
    /// and 2 others".
    static func sentence(for caption: Caption) -> String {
        guard !caption.handles.isEmpty else { return caption.lead }
        let names = caption.handles.map { "@\($0)" }
        let list: String
        if caption.others > 0 {
            list = names.joined(separator: ", ") + " and \(caption.others) other\(caption.others == 1 ? "" : "s")"
        } else if names.count == 2 {
            list = "\(names[0]) and \(names[1])"
        } else {
            list = names[0]
        }
        return "\(caption.lead) \(list)"
    }
}
