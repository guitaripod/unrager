import UIKit
import UnragerKit

/// What a notification is about, read from the server's raw `type` string
/// (case and underscores vary between X's surfaces).
enum NotificationType: Equatable {
    case like, repost, reply, mention, follow, quote
    case communityNote, recommendation, trending
    case other(String)

    init(raw: String) {
        switch raw.lowercased().replacingOccurrences(of: "_", with: "") {
        case "like", "favorite": self = .like
        case "retweet", "repost": self = .repost
        case "reply": self = .reply
        case "mention": self = .mention
        case "follow": self = .follow
        case "quote": self = .quote
        case "communitynote": self = .communityNote
        case "recommendation": self = .recommendation
        case "trending": self = .trending
        default: self = .other(raw.replacingOccurrences(of: "_", with: " "))
        }
    }

    /// Someone said something: the notification's snippet is their own words,
    /// not the user's post they reacted to.
    var isConversation: Bool {
        switch self {
        case .reply, .mention, .quote: return true
        default: return false
        }
    }

    /// Engagement with the user's own post: the snippet is that post.
    var isEngagement: Bool { self == .like || self == .repost }

    var style: NotificationStyle {
        switch self {
        case .like:
            return .init(color: DesignSystem.Color.like, symbol: "heart.fill", verb: "liked your post")
        case .repost:
            return .init(color: DesignSystem.Color.retweet, symbol: "arrow.2.squarepath", verb: "reposted your post")
        case .reply:
            return .init(color: DesignSystem.Color.accent, symbol: "arrowshape.turn.up.left.fill", verb: "replied to you")
        case .mention:
            return .init(color: DesignSystem.Color.quote, symbol: "at", verb: "mentioned you")
        case .follow:
            return .init(color: DesignSystem.Color.follow, symbol: "person.fill.badge.plus", verb: "followed you")
        case .quote:
            return .init(color: DesignSystem.Color.quote, symbol: "quote.bubble.fill", verb: "quoted your post")
        case .communityNote:
            return .init(color: DesignSystem.Color.spark, symbol: "note.text", verb: "added a Community Note")
        case .recommendation:
            return .init(color: DesignSystem.Color.accent, symbol: "sparkles", verb: "— suggested for you")
        case .trending:
            return .init(color: DesignSystem.Color.spark, symbol: "chart.line.uptrend.xyaxis", verb: "— trending")
        case .other(let raw):
            return .init(color: DesignSystem.Color.accent, symbol: "bell.fill", verb: raw)
        }
    }
}

/// The colour, glyph and verb a kind of notification wears.
struct NotificationStyle {
    let color: UIColor
    let symbol: String
    let verb: String

    /// A round chip with the glyph, drawn once per size and appearance. A small
    /// chip is a solid colour with a white glyph, so it reads over a photo; a
    /// large one is a soft tint with a coloured glyph.
    @MainActor
    func badge(diameter: CGFloat = 38, glyphSize: CGFloat = 17) -> UIImage {
        let key = "\(symbol)|\(color.hash)|\(diameter)|\(glyphSize)|\(UITraitCollection.current.userInterfaceStyle.rawValue)"
        if let cached = Self.cache.object(forKey: key as NSString) { return cached }
        let image = render(diameter: diameter, glyphSize: glyphSize)
        Self.cache.setObject(image, forKey: key as NSString)
        return image
    }

    @MainActor private static let cache = NSCache<NSString, UIImage>()

    @MainActor
    private func render(diameter: CGFloat, glyphSize: CGFloat) -> UIImage {
        let size = CGSize(width: diameter, height: diameter)
        let solid = diameter <= 26
        return UIGraphicsImageRenderer(size: size).image { _ in
            color.withAlphaComponent(solid ? 1 : 0.16).setFill()
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).fill()
            let config = UIImage.SymbolConfiguration(pointSize: glyphSize, weight: .semibold)
            let tint = solid ? UIColor.white : color
            guard let glyph = UIImage(systemName: symbol, withConfiguration: config)?
                .withTintColor(tint, renderingMode: .alwaysOriginal) else { return }
            glyph.draw(in: CGRect(x: (size.width - glyph.size.width) / 2,
                                  y: (size.height - glyph.size.height) / 2,
                                  width: glyph.size.width, height: glyph.size.height))
        }.withRenderingMode(.alwaysOriginal)
    }
}

/// The groups the filter chips choose between. Mentions is the full-post
/// mentions feed; the rest narrow the loaded activity.
enum NotificationCategory: String, CaseIterable {
    case all, mentions, likes, reposts, follows

    var title: String {
        switch self {
        case .all: return "All"
        case .mentions: return "Mentions"
        case .likes: return "Likes"
        case .reposts: return "Reposts"
        case .follows: return "Follows"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "bell.fill"
        case .mentions: return "at"
        case .likes: return "heart.fill"
        case .reposts: return "arrow.2.squarepath"
        case .follows: return "person.fill.badge.plus"
        }
    }

    func includes(_ notification: XNotification) -> Bool {
        let type = NotificationType(raw: notification.type)
        switch self {
        case .all: return true
        case .mentions: return type.isConversation
        case .likes: return type == .like
        case .reposts: return type == .repost
        case .follows: return type == .follow
        }
    }

    var emptyState: (symbol: String, title: String, subtitle: String) {
        switch self {
        case .all:
            return ("bell", "All quiet", "Likes, replies and new followers will show up here.")
        case .mentions:
            return ("at", "No mentions", "Posts that mention you will show up here.")
        case .likes:
            return ("heart", "No likes yet", "When someone likes your post, it lands here.")
        case .reposts:
            return ("arrow.2.squarepath", "No reposts yet", "When someone reposts you, it lands here.")
        case .follows:
            return ("person.badge.plus", "No new followers", "New followers will show up here.")
        }
    }
}

/// A day-based group of the list. Unread activity leads, whatever its day.
enum NotificationSection: Int, CaseIterable, Hashable {
    case new, today, yesterday, thisWeek, earlier

    var title: String {
        switch self {
        case .new: return "New"
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .thisWeek: return "This week"
        case .earlier: return "Earlier"
        }
    }

    static func bucket(for date: Date, now: Date, calendar: Calendar = .current) -> NotificationSection {
        let startOfToday = calendar.startOfDay(for: now)
        if date >= startOfToday { return .today }
        guard let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday),
              let startOfWeek = calendar.date(byAdding: .day, value: -6, to: startOfToday) else { return .earlier }
        if date >= startOfYesterday { return .yesterday }
        return date >= startOfWeek ? .thisWeek : .earlier
    }
}

/// Everything about how notifications read that doesn't need a view: copy,
/// grouping into sections, the digest, and what a row offers.
enum NotificationPresentation {
    /// How many people stand behind a row: the listed actors plus X's "and N
    /// others".
    static func peopleCount(_ notification: XNotification) -> Int {
        guard !notification.actors.isEmpty else { return 0 }
        return notification.actors.count + max(0, notification.othersCount ?? 0)
    }

    /// Whether a row stands for more than one person, so its faces open a list.
    static func hasPeopleList(_ notification: XNotification) -> Bool {
        peopleCount(notification) > 1
    }

    /// The names a title leads with (at most two) and how many more people the
    /// row stands for; nil when the notification carries no actors.
    static func who(for notification: XNotification) -> (names: [String], remaining: Int)? {
        let names = Array(notification.actors.prefix(2).map(\.name))
        guard !names.isEmpty else { return nil }
        return (names, peopleCount(notification) - names.count)
    }

    /// "A", "A and B", "A, B and 5 others".
    static func whoText(for notification: XNotification) -> String? {
        guard let who = who(for: notification) else { return nil }
        return joined(names: who.names, remaining: who.remaining) { $0 }
    }

    private static func joined(names: [String], remaining: Int, decorate: (String) -> String) -> String {
        let others = remaining > 0 ? "\(remaining) other\(remaining == 1 ? "" : "s")" : nil
        switch (names.count, others) {
        case (1, nil): return decorate(names[0])
        case (1, let others?): return decorate(names[0]) + " and " + decorate(others)
        case (_, nil): return decorate(names[0]) + " and " + decorate(names[1])
        case (_, let others?): return decorate(names[0]) + ", " + decorate(names[1]) + " and " + decorate(others)
        }
    }

    /// Plain title + body for a local banner. The title carries the actor names
    /// and action verb; actor-less types fall back to X's own rendered message
    /// (never "Someone Poll"). The body is the target tweet snippet when present.
    static func bannerCopy(for notification: XNotification) -> (title: String, body: String) {
        let style = NotificationType(raw: notification.type).style
        let body = notification.targetTweetSnippet ?? ""
        if let who = whoText(for: notification) { return ("\(who) \(style.verb)", body) }
        if let message = notification.message, !message.isEmpty { return (message, body) }
        return ("Someone \(style.verb)", body)
    }

    /// Badge image + title + optional subtitle for the in-app notification toast.
    @MainActor
    static func toastContent(for notification: XNotification) -> (badge: UIImage, title: String, subtitle: String?) {
        let copy = bannerCopy(for: notification)
        return (NotificationType(raw: notification.type).style.badge(), copy.title,
                copy.body.isEmpty ? nil : copy.body)
    }

    /// Coalesced toast content when several notifications land in one poll.
    @MainActor
    static func toastSummary(count: Int) -> (badge: UIImage, title: String, subtitle: String?) {
        let style = NotificationStyle(color: DesignSystem.Color.accent, symbol: "bell.fill", verb: "")
        return (style.badge(), "\(count) new notifications", "Tap to view")
    }

    /// The row's headline: names in bold, the rest in a quieter weight.
    @MainActor
    static func title(for notification: XNotification) -> NSAttributedString {
        let bold: [NSAttributedString.Key: Any] = [
            .font: DesignSystem.Typography.name(), .foregroundColor: DesignSystem.Color.label,
        ]
        let quiet: [NSAttributedString.Key: Any] = [
            .font: DesignSystem.Typography.handle(), .foregroundColor: DesignSystem.Color.label,
        ]
        let style = NotificationType(raw: notification.type).style
        let result = NSMutableAttributedString()
        if let who = who(for: notification) {
            let names = joined(names: who.names, remaining: who.remaining) { "\u{1}\($0)\u{2}" }
            result.append(styled(names, bold: bold, quiet: quiet))
            result.append(NSAttributedString(string: " " + style.verb, attributes: quiet))
        } else if let message = notification.message, !message.isEmpty {
            result.append(NSAttributedString(string: message, attributes: bold))
        } else {
            result.append(NSAttributedString(string: "Someone", attributes: bold))
            result.append(NSAttributedString(string: " " + style.verb, attributes: quiet))
        }
        TwemojiText.substituteCachedEmoji(in: result, font: DesignSystem.Typography.name())
        return result
    }

    /// Splits `text` at the control marks `joined` wrapped bold runs in.
    private static func styled(_ text: String, bold: [NSAttributedString.Key: Any],
                               quiet: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var isBold = false
        var run = ""
        func flush() {
            guard !run.isEmpty else { return }
            result.append(NSAttributedString(string: run, attributes: isBold ? bold : quiet))
            run = ""
        }
        for character in text {
            switch character {
            case "\u{1}": flush(); isBold = true
            case "\u{2}": flush(); isBold = false
            default: run.append(character)
            }
        }
        flush()
        return result
    }

    /// Splits `order` into sections. A notification newer than the user's last
    /// visit leads in New; the rest fall into their day. Within a section the
    /// order is kept, and a section with no rows is left out.
    static func sections(
        order: [String], items: [String: XNotification], isUnread: (XNotification) -> Bool,
        now: Date = Date(), calendar: Calendar = .current
    ) -> [(section: NotificationSection, ids: [String])] {
        var buckets: [NotificationSection: [String]] = [:]
        for id in order {
            guard let notification = items[id] else { continue }
            let section = isUnread(notification)
                ? NotificationSection.new
                : NotificationSection.bucket(for: notification.timestamp, now: now, calendar: calendar)
            buckets[section, default: []].append(id)
        }
        return NotificationSection.allCases.compactMap { section in
            buckets[section].map { (section, $0) }
        }
    }

    /// One line on what a stretch of activity added up to: "47 likes · 3 replies
    /// · 2 new followers". Conversation comes first, then people, then volume;
    /// at most three kinds are named.
    static func digest(of notifications: [XNotification]) -> String? {
        var counts: [String: Int] = [:]
        for notification in notifications {
            let people = max(1, peopleCount(notification))
            switch NotificationType(raw: notification.type) {
            case .reply: counts["reply", default: 0] += 1
            case .mention: counts["mention", default: 0] += 1
            case .quote: counts["quote", default: 0] += 1
            case .follow: counts["follow", default: 0] += people
            case .repost: counts["repost", default: 0] += people
            case .like: counts["like", default: 0] += people
            default: counts["other", default: 0] += 1
            }
        }
        let names: [(key: String, one: String, many: String)] = [
            ("reply", "reply", "replies"), ("mention", "mention", "mentions"), ("quote", "quote", "quotes"),
            ("follow", "new follower", "new followers"), ("repost", "repost", "reposts"),
            ("like", "like", "likes"), ("other", "update", "updates"),
        ]
        let parts = names.compactMap { name -> String? in
            guard let count = counts[name.key], count > 0 else { return nil }
            return "\(Format.count(count)) \(count == 1 ? name.one : name.many)"
        }
        return parts.isEmpty ? nil : parts.prefix(3).joined(separator: " · ")
    }

    /// Whether a notification opens something when tapped: its post, or the
    /// person, or a list of people.
    static func destination(of notification: XNotification) -> Destination? {
        if let tweetID = notification.targetTweetID { return .post(tweetID) }
        if hasPeopleList(notification) { return .people }
        if let actor = notification.actors.first { return .profile(actor.handle) }
        return nil
    }

    enum Destination: Equatable {
        case post(String)
        case people
        case profile(String)
    }

    /// The link to a notification's post on x.com.
    static func postURL(_ tweetID: String) -> URL? {
        URL(string: "https://x.com/i/status/\(tweetID)")
    }
}
