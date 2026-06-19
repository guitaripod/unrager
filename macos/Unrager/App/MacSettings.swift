import Foundation

/// macOS-local preferences that aren't part of the cross-platform `AppSettings`
/// in UnragerKit. Backed by `UserDefaults.standard`, keyed under the same
/// `unrager.` namespace.
enum MacSettings {
    private static var defaults: UserDefaults { .standard }

    private enum Key {
        static let seenDimming = "unrager.mac.seenDimming"
    }

    /// When on, tweets the server has recorded as seen (via `markSeen`) render
    /// dimmed, and visible rows are marked seen as they scroll into view.
    static var seenDimming: Bool {
        get { defaults.object(forKey: Key.seenDimming) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.seenDimming) }
    }
}
