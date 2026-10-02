import UIKit
import UnragerKit

/// Where a profile's header stands: still loading, shown, or failed, and if
/// failed, whether trying again could help. An account X won't show at all
/// (suspended, gone, hidden) is final: the header says so and offers no
/// Retry, though a pull-to-refresh still asks again.
enum ProfileLoadState: Equatable {
    case loading
    case loaded
    case gone(message: String)
    case failed(message: String)

    /// The state a failed profile request leaves the header in.
    static func failure(_ error: Error) -> ProfileLoadState {
        switch error as? APIError {
        case .notFound:
            return .gone(message: "This account doesn't exist.")
        case let .unavailable(reason, _):
            return .gone(message: goneMessage(reason: reason))
        case .rateLimited:
            return .failed(message: error.localizedDescription)
        default:
            return .failed(message: "Couldn't load this profile.")
        }
    }

    private static func goneMessage(reason: String?) -> String {
        switch reason {
        case "suspended": return "This account is suspended."
        case "protected": return "This account is protected."
        case "deleted", "deactivated": return "This account doesn't exist."
        default: return "This account isn't available."
        }
    }

    var isFinal: Bool {
        if case .gone = self { return true }
        return false
    }

    /// What the header says in place of the account, if anything.
    var message: String? {
        switch self {
        case .loading, .loaded: return nil
        case let .gone(message), let .failed(message): return message
        }
    }

    var offersRetry: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// The viewer's mute and block of one account, flipped at once when asked
/// and put back if the server refuses. Each kind takes one request at a time.
@MainActor
final class ProfileModeration {
    enum Kind: Hashable {
        case mute
        case block
    }

    private(set) var muting = false
    private(set) var blocking = false
    private var inFlight = Set<Kind>()
    var onChange: (() -> Void)?

    func isOn(_ kind: Kind) -> Bool {
        kind == .mute ? muting : blocking
    }

    func isPending(_ kind: Kind) -> Bool {
        inFlight.contains(kind)
    }

    /// Takes what a profile load reported; a kind with a request in flight
    /// keeps its optimistic value, and an unknown one (nil) is left as is.
    func update(muting: Bool?, blocking: Bool?) {
        if let muting, !inFlight.contains(.mute) { self.muting = muting }
        if let blocking, !inFlight.contains(.block) { self.blocking = blocking }
        onChange?()
    }

    /// Flips `kind` now, asks `request` to make it so, and keeps what the
    /// server confirms, or rolls back when it throws. Nil when a request for
    /// `kind` is already running.
    func toggle(_ kind: Kind, request: (Bool) async throws -> Bool) async -> Result<Bool, Error>? {
        guard !inFlight.contains(kind) else { return nil }
        let previous = isOn(kind)
        inFlight.insert(kind)
        set(kind, !previous)
        defer {
            inFlight.remove(kind)
            onChange?()
        }
        do {
            let confirmed = try await request(!previous)
            set(kind, confirmed)
            return .success(confirmed)
        } catch {
            set(kind, previous)
            return .failure(error)
        }
    }

    private func set(_ kind: Kind, _ value: Bool) {
        switch kind {
        case .mute: muting = value
        case .block: blocking = value
        }
        onChange?()
    }

    /// The menu title for the action that flips `kind` from `isOn`.
    static func title(for kind: Kind, isOn: Bool, handle: String) -> String {
        switch kind {
        case .mute: return isOn ? "Unmute @\(handle)" : "Mute @\(handle)"
        case .block: return isOn ? "Unblock @\(handle)" : "Block @\(handle)"
        }
    }

    /// What a successful flip says.
    static func confirmation(for kind: Kind, isOn: Bool, handle: String) -> String {
        switch kind {
        case .mute: return isOn ? "Muted @\(handle)" : "Unmuted @\(handle)"
        case .block: return isOn ? "Blocked @\(handle)" : "Unblocked @\(handle)"
        }
    }
}

/// The text a profile header shows about an account beyond its name: the
/// linked bio, and the location, website and join date line.
enum ProfileText {
    /// "Joined March 2019", with the month and year in `locale`'s words and
    /// order.
    static func joined(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let style = Date.FormatStyle(locale: locale, calendar: locale.calendar, timeZone: timeZone)
            .month(.wide).year()
        return "Joined \(date.formatted(style))"
    }

    private static let longestWebsite = 40

    /// A website as X shows it: host and path, without the scheme, a leading
    /// "www." or a trailing slash, cut short when long.
    static func websiteLabel(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = websiteURL(trimmed), let host = url.host(), !host.isEmpty else { return trimmed }
        var label = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        var path = url.path(percentEncoded: false)
        while path.hasSuffix("/") { path.removeLast() }
        label += path
        guard label.count > longestWebsite else { return label }
        return String(label.prefix(longestWebsite - 1)) + "…"
    }

    /// The address a website opens: as given, or over https when it came
    /// without a scheme. Nil for anything that isn't a web address.
    static func websiteURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host() != nil else { return nil }
        return url
    }

    /// The bio with its `@mentions`, `#hashtags` and links tappable (the same
    /// runs a post's text gets), each web address shown as its short label.
    @MainActor
    static func bio(_ text: String, font: UIFont) -> NSAttributedString {
        let attributed = NSMutableAttributedString(
            attributedString: TweetText.attributed(for: text, urls: [], seen: false, font: font))
        var replacements: [(NSRange, String)] = []
        attributed.enumerateAttribute(TweetText.linkKey, in: NSRange(location: 0, length: attributed.length)) {
            value, range, _ in
            guard let url = value as? URL, url.scheme == "http" || url.scheme == "https" else { return }
            let shown = (attributed.string as NSString).substring(with: range)
            let label = websiteLabel(shown)
            if label != shown { replacements.append((range, label)) }
        }
        for (range, label) in replacements.reversed() {
            attributed.replaceCharacters(in: range, with: label)
        }
        unhyphenated(attributed)
        return attributed
    }

    /// The tap targets in a bio, in reading order, with what VoiceOver calls
    /// each: "@handle", "#tag" or the address's label.
    static func links(in text: NSAttributedString) -> [(name: String, url: URL)] {
        var links: [(String, URL)] = []
        text.enumerateAttribute(TweetText.linkKey, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let url = value as? URL else { return }
            links.append(((text.string as NSString).substring(with: range), url))
        }
        return links
    }

    /// The location, website and join date as one wrapping line, each after
    /// its symbol; the website is a link. Nil when the account gives none.
    @MainActor
    static func meta(location: String?, website: String?, joinedAt: Date?, font: UIFont) -> NSAttributedString? {
        let color = DesignSystem.Color.secondaryLabel
        var items: [NSAttributedString] = []
        if let location = location?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty {
            items.append(item("mappin.and.ellipse", location, font: font, color: color))
        }
        if let website, let url = websiteURL(website) {
            let link = NSMutableAttributedString(attributedString: item(
                "link", websiteLabel(website), font: font, color: DesignSystem.Color.accent))
            link.addAttribute(TweetText.linkKey, value: url, range: NSRange(location: 0, length: link.length))
            items.append(link)
        }
        if let joinedAt {
            items.append(item("calendar", joined(joinedAt), font: font, color: color))
        }
        guard !items.isEmpty else { return nil }
        let line = NSMutableAttributedString()
        for (index, item) in items.enumerated() {
            if index > 0 { line.append(NSAttributedString(string: "   ", attributes: [.font: font])) }
            line.append(item)
        }
        unhyphenated(line)
        return line
    }

    /// What VoiceOver reads for the meta line, which its symbols can't say.
    static func metaAccessibilityLabel(location: String?, website: String?, joinedAt: Date?) -> String {
        var parts: [String] = []
        if let location = location?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty {
            parts.append("Location: \(location)")
        }
        if let website, websiteURL(website) != nil { parts.append("Website: \(websiteLabel(website))") }
        if let joinedAt { parts.append(joined(joinedAt)) }
        return parts.joined(separator: ". ")
    }

    /// Wraps at word boundaries only: at large text sizes a label would
    /// otherwise hyphenate addresses and handles ("exam-ple.com").
    private static func unhyphenated(_ text: NSMutableAttributedString) {
        let style = NSMutableParagraphStyle()
        style.hyphenationFactor = 0
        style.usesDefaultHyphenation = false
        style.lineBreakMode = .byWordWrapping
        text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
    }

    /// One symbol and its text, held together so a wrap never parts them.
    private static func item(_ symbol: String, _ text: String, font: UIFont, color: UIColor) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let config = UIImage.SymbolConfiguration(font: font, scale: .small)
        if let image = UIImage(systemName: symbol, withConfiguration: config)?
            .withTintColor(color, renderingMode: .alwaysOriginal) {
            out.append(NSAttributedString(attachment: NSTextAttachment(image: image)))
            out.append(NSAttributedString(string: "\u{00A0}"))
        }
        out.append(NSAttributedString(string: text))
        out.addAttributes([.font: font, .foregroundColor: color], range: NSRange(location: 0, length: out.length))
        return out
    }
}
