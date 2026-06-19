import Foundation

/// iOS-only client preferences that don't belong in the cross-platform
/// `AppSettings` (UnragerKit). Same UserDefaults store, app-specific keys.
enum ClientSettings {
    private static var defaults: UserDefaults { .standard }

    private enum Key {
        static let markSeen = "unrager.ios.markSeen"
        static let tabs = "unrager.ios.tabs"
    }

    /// When on, tweets scrolled past on Following / Mentions are reported to
    /// the server's read tracker and dimmed on subsequent loads. Default on.
    static var markSeenEnabled: Bool {
        get { defaults.object(forKey: Key.markSeen) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.markSeen) }
    }

    /// The user's ordered tab-bar selection (max 5). Persisted as raw values;
    /// falls back to the default set, and is sanitized so a corrupt or
    /// out-of-bounds stored value can never produce an empty or oversized bar.
    static var tabs: [TabItem] {
        get {
            guard let raw = defaults.array(forKey: Key.tabs) as? [String] else { return TabItem.defaults }
            let resolved = raw.compactMap(TabItem.init(rawValue:))
            return TabItem.sanitized(resolved)
        }
        set { defaults.set(TabItem.sanitized(newValue).map(\.rawValue), forKey: Key.tabs) }
    }
}
