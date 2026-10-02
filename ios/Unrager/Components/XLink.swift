import Foundation

/// Where a link leads: a post or a profile on X, which open in the app, or
/// anywhere else on the web.
enum XLink: Equatable {
    case post(id: String)
    case profile(handle: String)
    case web(URL)

    private static let hosts: Set<String> = [
        "x.com", "www.x.com", "mobile.x.com", "twitter.com", "www.twitter.com", "mobile.twitter.com",
    ]

    /// First path segments that are X's own pages, never an account.
    private static let reservedPaths: Set<String> = [
        "home", "explore", "i", "search", "settings", "notifications", "messages", "compose", "hashtag",
        "intent", "share", "login", "logout", "signup", "tos", "privacy", "about", "account", "download",
        "jobs", "lists", "bookmarks", "communities", "premium", "help", "rules", "following", "followers",
        "who_to_follow", "connect_people", "topics", "display", "keyboard_shortcuts", "status", "web",
    ]

    /// Classifies `url`: `/<handle>/status/<id>` (with any suffix such as
    /// `/photo/1` or `/analytics`) and `/i/web/status/<id>` on x.com or
    /// twitter.com are posts, `/<handle>` is a profile, and everything else,
    /// t.co included, stays a web link. Query and fragment are ignored.
    static func classify(_ url: URL) -> XLink {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased(), hosts.contains(host) else { return .web(url) }
        let segments = url.path.split(separator: "/").map(String.init)
        if let id = postID(in: segments) { return .post(id: id) }
        if segments.count == 1, isHandle(segments[0]), !reservedPaths.contains(segments[0].lowercased()) {
            return .profile(handle: segments[0])
        }
        return .web(url)
    }

    /// The post or profile a pasted piece of text points at: a single
    /// `@handle`, or the first x.com / twitter.com post or profile address in
    /// it (with or without `https://`). Nil when it names neither, so the text
    /// can be searched as typed.
    static func reference(in text: String) -> XLink? {
        let tokens = text.split(whereSeparator: \.isWhitespace).map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "<>()[]\"'.,;!?"))
        }
        if tokens.count == 1, let token = tokens.first, token.hasPrefix("@"),
           isHandle(String(token.dropFirst())) {
            return .profile(handle: String(token.dropFirst()))
        }
        for token in tokens {
            guard let url = webURL(from: token) else { continue }
            switch classify(url) {
            case .web: continue
            case let found: return found
            }
        }
        return nil
    }

    /// `token` as an address, adding `https://` to a bare `x.com/…`.
    private static func webURL(from token: String) -> URL? {
        let lower = token.lowercased()
        if lower.hasPrefix("https://") || lower.hasPrefix("http://") { return URL(string: token) }
        guard hosts.contains(where: { lower.hasPrefix($0 + "/") }) else { return nil }
        return URL(string: "https://" + token)
    }

    /// The post id in `/<handle>/status/<id>/…` or `/i/web/status/<id>/…`.
    private static func postID(in segments: [String]) -> String? {
        let statusIndex: Int
        if segments.count >= 4, segments[0].lowercased() == "i", segments[1].lowercased() == "web",
           segments[2].lowercased() == "status" {
            statusIndex = 2
        } else if segments.count >= 3, isHandle(segments[0]),
                  ["status", "statuses"].contains(segments[1].lowercased()) {
            statusIndex = 1
        } else {
            return nil
        }
        let id = segments[statusIndex + 1]
        guard !id.isEmpty, id.count <= 20, id.allSatisfy(\.isASCIIDigit) else { return nil }
        return id
    }

    /// X's handle rule: 1 to 15 letters, digits or underscores.
    private static func isHandle(_ text: String) -> Bool {
        (1...15).contains(text.count) && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
