import Foundation

/// The notification activity types the apps classify (mirrors the cases in each
/// platform's `NotificationsViewController.style(for:)`). Used both to key the
/// per-type local-notification toggles and to bucket a raw server type into a
/// user-facing switch.
public enum NotificationKind: String, Sendable, CaseIterable {
    case like
    case reply
    case mention
    case follow
    case repost
    case quote

    public var title: String {
        switch self {
        case .like: return "Likes"
        case .reply: return "Replies"
        case .mention: return "Mentions"
        case .follow: return "Follows"
        case .repost: return "Reposts"
        case .quote: return "Quotes"
        }
    }

    /// Buckets a raw server notification `type` into a togglable kind, applying
    /// the same case-insensitive, underscore-stripped normalization the feed
    /// uses for its style chips. Types that don't map to a user-facing toggle
    /// (e.g. Community Notes) return nil and are never suppressed by a toggle.
    public static func from(rawType: String) -> NotificationKind? {
        switch rawType.lowercased().replacingOccurrences(of: "_", with: "") {
        case "like", "favorite": return .like
        case "reply": return .reply
        case "mention": return .mention
        case "follow": return .follow
        case "retweet", "repost": return .repost
        case "quote": return .quote
        default: return nil
        }
    }

    /// Whether this kind alerts (toast/banner) before the user touches any
    /// toggle. Conversation-grade activity (someone said something to you, or
    /// started following you) defaults on; volume engagement (likes, reposts)
    /// defaults off so a viral post doesn't turn the app into a noise machine.
    public var alertsByDefault: Bool {
        switch self {
        case .reply, .mention, .quote, .follow: return true
        case .like, .repost: return false
        }
    }

    /// Whether a banner for this kind should interrupt quietly: likes and
    /// reposts are worth a list entry, not a sound or a lit screen.
    public var isPassiveDelivery: Bool {
        switch self {
        case .like, .repost: return true
        case .reply, .mention, .quote, .follow: return false
        }
    }
}

/// Client-side notification preferences (UserDefaults). The badge/unread count
/// is always tracked; the master toggle and per-type toggles only gate local
/// banner delivery. Cross-platform — shared by both apps.
///
/// NO PUSH: there is no APNs server. Banners are driven by a foreground poller
/// (`NotificationPoller`), so they're reliable only while the app is active and
/// best-effort in a short background refresh. They will not arrive when the app
/// is fully terminated. These prefs only decide *whether* to post a banner when
/// the poller happens to be running and finds new activity.
public enum NotificationPrefs {
    private static var defaults: UserDefaults { .standard }

    private enum Key {
        static let bannersEnabled = "unrager.notifications.bannersEnabled"
        static let perKindPrefix = "unrager.notifications.kind."
        static let lastSeenID = "unrager.notifications.lastSeenID"
        static let lastSeenTimestamp = "unrager.notifications.lastSeenTimestamp"
        static let bannerSound = "unrager.notifications.bannerSound"
        static let quietHoursEnabled = "unrager.notifications.quietHours.enabled"
        static let quietHoursStart = "unrager.notifications.quietHours.startMinute"
        static let quietHoursEnd = "unrager.notifications.quietHours.endMinute"
        static let deliveredBannerIDs = "unrager.notifications.deliveredBannerIDs"
    }

    /// The master switch: when on (and the system permission is granted) the
    /// poller posts a local banner for new activity. Off by default — banners
    /// are opt-in, the unread badge is not. Toggling this on is what triggers the
    /// system permission prompt.
    public static var bannersEnabled: Bool {
        get { defaults.bool(forKey: Key.bannersEnabled) }
        set { defaults.set(newValue, forKey: Key.bannersEnabled) }
    }

    /// Whether a given activity kind is allowed to alert — this single per-kind
    /// toggle gates both in-app toasts and local banners. Defaults follow
    /// `alertsByDefault`: replies/mentions/quotes/follows on, likes/reposts off.
    public static func bannerEnabled(for kind: NotificationKind) -> Bool {
        defaults.object(forKey: Key.perKindPrefix + kind.rawValue) as? Bool ?? kind.alertsByDefault
    }

    public static func setBannerEnabled(_ enabled: Bool, for kind: NotificationKind) {
        defaults.set(enabled, forKey: Key.perKindPrefix + kind.rawValue)
    }

    /// Whether a banner should be raised for a raw server type, honoring both the
    /// master switch and the per-kind toggle. Unmapped types (no toggle) follow
    /// the master switch alone.
    public static func shouldBanner(rawType: String) -> Bool {
        guard bannersEnabled else { return false }
        guard let kind = NotificationKind.from(rawType: rawType) else { return true }
        return bannerEnabled(for: kind)
    }

    /// Whether an in-app toast should be raised for a raw server type. Toasts
    /// need no system permission and no master switch — they honor the per-kind
    /// mute toggles, and unmapped junk types (Recommendation/Trending/Poll/…)
    /// never toast: the tab badge and list carry those.
    public static func shouldToast(rawType: String) -> Bool {
        guard let kind = NotificationKind.from(rawType: rawType) else { return false }
        return bannerEnabled(for: kind)
    }

    /// Whether banners carry the default sound (subject to quiet hours). On by
    /// default; likes/reposts are always silent regardless.
    public static var bannerSoundEnabled: Bool {
        get { defaults.object(forKey: Key.bannerSound) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.bannerSound) }
    }

    // MARK: - Quiet hours

    public static var quietHoursEnabled: Bool {
        get { defaults.bool(forKey: Key.quietHoursEnabled) }
        set { defaults.set(newValue, forKey: Key.quietHoursEnabled) }
    }

    /// Quiet-hours window start, in minutes from local midnight (default 22:00).
    public static var quietHoursStartMinute: Int {
        get { defaults.object(forKey: Key.quietHoursStart) as? Int ?? 22 * 60 }
        set { defaults.set(newValue, forKey: Key.quietHoursStart) }
    }

    /// Quiet-hours window end, in minutes from local midnight (default 08:00).
    public static var quietHoursEndMinute: Int {
        get { defaults.object(forKey: Key.quietHoursEnd) as? Int ?? 8 * 60 }
        set { defaults.set(newValue, forKey: Key.quietHoursEnd) }
    }

    /// True when `date` falls inside the enabled quiet-hours window. Handles
    /// windows that wrap midnight (22:00 → 08:00); a start equal to the end
    /// means the window is degenerate and never matches.
    public static func isQuietHours(at date: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard quietHoursEnabled else { return false }
        let start = quietHoursStartMinute
        let end = quietHoursEndMinute
        guard start != end else { return false }
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        if start < end {
            return minute >= start && minute < end
        }
        return minute >= start || minute < end
    }

    // MARK: - Delivered-banner dedupe

    /// The cap on remembered banner ids; old entries fall off first.
    private static let deliveredBannerCap = 300

    /// Whether a system banner for this notification id was already posted —
    /// dedupes the foreground diff path against the background marker path so
    /// the user is never alerted twice for one event.
    public static func hasDeliveredBanner(id: String) -> Bool {
        (defaults.array(forKey: Key.deliveredBannerIDs) as? [String])?.contains(id) ?? false
    }

    public static func recordDeliveredBanners(ids: [String]) {
        guard !ids.isEmpty else { return }
        var stored = (defaults.array(forKey: Key.deliveredBannerIDs) as? [String]) ?? []
        stored.append(contentsOf: ids.filter { !stored.contains($0) })
        if stored.count > deliveredBannerCap {
            stored.removeFirst(stored.count - deliveredBannerCap)
        }
        defaults.set(stored, forKey: Key.deliveredBannerIDs)
    }

    /// The newest notification the user has actually viewed (id + its timestamp).
    /// Unread = notifications strictly newer than this marker. Persisted so the
    /// count survives relaunch and only ever advances.
    public static var lastSeenID: String? {
        get { defaults.string(forKey: Key.lastSeenID) }
        set { defaults.set(newValue, forKey: Key.lastSeenID) }
    }

    public static var lastSeenTimestamp: Date? {
        get {
            let raw = defaults.double(forKey: Key.lastSeenTimestamp)
            return raw == 0 ? nil : Date(timeIntervalSince1970: raw)
        }
        set { defaults.set(newValue?.timeIntervalSince1970 ?? 0, forKey: Key.lastSeenTimestamp) }
    }

    /// Advances the last-seen marker to the supplied instant, monotonically —
    /// it never moves backward, so an older marker (a stale page, a lagging
    /// server marker) can't resurrect already-cleared unreads. Returns true if
    /// the marker moved. The primitive under every other `markSeen`, and the
    /// adoption point for a server-side marker read from another device.
    @discardableResult
    public static func markSeen(timestamp: Date, id: String? = nil) -> Bool {
        if let current = lastSeenTimestamp, timestamp <= current { return false }
        lastSeenID = id
        lastSeenTimestamp = timestamp
        return true
    }

    /// Advances the last-seen marker to the newest of the supplied notifications,
    /// monotonically — it never moves backward, so viewing an older page can't
    /// resurrect already-cleared unreads. Returns true if the marker moved.
    @discardableResult
    public static func markSeen(upTo newest: XNotification?) -> Bool {
        guard let newest else { return false }
        return markSeen(timestamp: newest.timestamp, id: newest.id)
    }

    /// Advances the marker to the newest notification *by timestamp* in a loaded
    /// page. X doesn't return notifications in strict time order, so the first
    /// item isn't reliably the newest — marking only it leaves a deeper,
    /// higher-timestamp item counting as unread on every poll (a badge that
    /// clears on view then reappears). Taking the max keeps it cleared.
    @discardableResult
    public static func markSeen(in notifications: [XNotification]) -> Bool {
        markSeen(upTo: notifications.max { $0.timestamp < $1.timestamp })
    }

    /// The unread count for a page: notifications strictly newer than the
    /// last-seen marker. With no marker yet (fresh install), nothing is unread —
    /// the first view establishes the baseline rather than flooding the badge.
    public static func unreadCount(in notifications: [XNotification]) -> Int {
        guard let marker = lastSeenTimestamp else { return 0 }
        return notifications.filter { $0.timestamp > marker }.count
    }
}
