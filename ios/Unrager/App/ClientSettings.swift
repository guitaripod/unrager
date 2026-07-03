import Foundation

/// iOS-only client preferences that don't belong in the cross-platform
/// `AppSettings` (UnragerKit). Same UserDefaults store, app-specific keys.
enum ClientSettings {
    private static var defaults: UserDefaults { .standard }

    private enum Key {
        static let markSeen = "unrager.ios.markSeen"
        static let tabs = "unrager.ios.tabs"
        static let homeFollowing = "unrager.ios.homeFollowing"
        static let homeOriginals = "unrager.ios.homeOriginals"
        static let followingChronological = "unrager.ios.followingChronological"
        static let recentSearches = "unrager.ios.recentSearches"
    }

    /// Whether the Following feed is sorted strictly newest-first. X's
    /// HomeLatestTimeline interleaves; this re-sorts the displayed tweets by
    /// timestamp. Persisted; only applied on the Following feed.
    static var followingChronological: Bool {
        get { defaults.bool(forKey: Key.followingChronological) }
        set { defaults.set(newValue, forKey: Key.followingChronological) }
    }

    /// When on, tweets scrolled past on Following / Mentions are reported to
    /// the server's read tracker and dimmed on subsequent loads. Default on.
    static var markSeenEnabled: Bool {
        get { defaults.object(forKey: Key.markSeen) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.markSeen) }
    }

    /// Whether the Home tab last sat on Following (vs For You). Restored on
    /// launch so the feed reopens where it was left — local is authoritative;
    /// the server session is synced but never clobbers this.
    static var homeFollowing: Bool {
        get { defaults.bool(forKey: Key.homeFollowing) }
        set { defaults.set(newValue, forKey: Key.homeFollowing) }
    }

    /// Whether the Home feed's "Originals only" filter was last on. Persisted
    /// locally so the toggle survives relaunch.
    static var homeOriginals: Bool {
        get { defaults.bool(forKey: Key.homeOriginals) }
        set { defaults.set(newValue, forKey: Key.homeOriginals) }
    }

    /// The user's ordered tab-bar selection (max 5). Persisted as raw values;
    /// falls back to the default set, and is sanitized so a corrupt or
    /// out-of-bounds stored value can never produce an empty or oversized bar.
    static let maxRecentSearches = 10

    /// The user's recent search queries, most recent first, shown on the
    /// Search tab's empty state. Capped and de-duplicated case-insensitively.
    static var recentSearches: [String] {
        get { defaults.stringArray(forKey: Key.recentSearches) ?? [] }
        set { defaults.set(Array(newValue.prefix(maxRecentSearches)), forKey: Key.recentSearches) }
    }

    static func addRecentSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = recentSearches.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        list.insert(trimmed, at: 0)
        recentSearches = list
    }

    static func clearRecentSearches() {
        defaults.removeObject(forKey: Key.recentSearches)
    }

    static var tabs: [TabItem] {
        get {
            guard let raw = defaults.array(forKey: Key.tabs) as? [String] else { return TabItem.defaults }
            let resolved = raw.compactMap(TabItem.resolve(persisted:))
            return TabItem.sanitized(resolved)
        }
        set { defaults.set(TabItem.sanitized(newValue).map(\.rawValue), forKey: Key.tabs) }
    }
}
