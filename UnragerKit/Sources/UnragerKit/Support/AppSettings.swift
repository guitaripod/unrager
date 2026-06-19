import CoreGraphics
import Foundation

public enum AppearanceMode: Int, Sendable, CaseIterable {
    case system = 0
    case light = 1
    case dark = 2

    public var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

/// A stepped, user-chosen text-size multiplier applied across every font the
/// app renders (through each platform's `DesignSystem.Typography`). `.standard`
/// is the unscaled default; raw values double as a segmented-control index.
public enum FontScale: Int, Sendable, CaseIterable {
    case small = 0
    case standard = 1
    case large = 2
    case xLarge = 3
    case xxLarge = 4

    public var multiplier: CGFloat {
        switch self {
        case .small: return 0.85
        case .standard: return 1.0
        case .large: return 1.15
        case .xLarge: return 1.3
        case .xxLarge: return 1.5
        }
    }

    public var title: String {
        switch self {
        case .small: return "S"
        case .standard: return "M"
        case .large: return "L"
        case .xLarge: return "XL"
        case .xxLarge: return "XXL"
        }
    }
}

/// Client-side preferences (UserDefaults). The server owns the source/seen/
/// filter *state*; this only holds what the client decides: where the server
/// is and how the UI looks. Cross-platform.
public enum AppSettings {
    private static var defaults: UserDefaults { .standard }

    private enum Key {
        static let serverURL = "unrager.serverURL"
        static let appearance = "unrager.appearance"
        static let imagesEnabled = "unrager.imagesEnabled"
        static let filterEnabled = "unrager.filterEnabled"
        static let appearanceMigrated = "unrager.appearanceMigratedToLocal.v1"
        static let fontScale = "unrager.fontScale"
    }

    /// Posted after the user changes `fontScale` so already-visible views can
    /// re-resolve their fonts and re-measure. The setter stays a pure store;
    /// the Settings screens post this, mirroring how `appearance` side-effects
    /// live in the view controllers.
    public static let fontScaleDidChange = Notification.Name("unrager.fontScaleDidChange")

    /// One-time cleanup: earlier builds auto-applied the server's (dark) TUI
    /// theme to the app appearance, leaving a non-chosen `.dark` persisted.
    /// Clear that once so the app honors the system default until the user
    /// explicitly picks an appearance in Settings. Call at launch before
    /// reading `appearance`.
    public static func migrateAppearanceIfNeeded() {
        guard !defaults.bool(forKey: Key.appearanceMigrated) else { return }
        defaults.set(true, forKey: Key.appearanceMigrated)
        defaults.removeObject(forKey: Key.appearance)
    }

    /// The fallback server: a build-time `UNRAGER_DEFAULT_SERVER` Info.plist key
    /// if present (lets a device build ship pointed at a Tailscale address),
    /// else localhost for the simulator/dev.
    public static var defaultServerURL: URL {
        if let configured = Bundle.main.object(forInfoDictionaryKey: "UNRAGER_DEFAULT_SERVER") as? String,
           let url = URL(string: configured), url.scheme != nil, url.host != nil {
            return url
        }
        return URL(string: "http://localhost:7777")!
    }

    public static var serverURLString: String {
        get { defaults.string(forKey: Key.serverURL) ?? defaultServerURL.absoluteString }
        set { defaults.set(newValue, forKey: Key.serverURL) }
    }

    /// The normalized base URL; falls back to the default if the stored string
    /// is unparseable, so the client never ends up with no server.
    public static var serverURL: URL {
        let trimmed = serverURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else {
            return defaultServerURL
        }
        return url
    }

    public static var appearance: AppearanceMode {
        get { AppearanceMode(rawValue: defaults.integer(forKey: Key.appearance)) ?? .system }
        set { defaults.set(newValue.rawValue, forKey: Key.appearance) }
    }

    /// The user's text-size choice. An unset key reads as `.standard` (not the
    /// raw-`0` `.small`), so a fresh install renders unscaled.
    public static var fontScale: FontScale {
        get {
            guard defaults.object(forKey: Key.fontScale) != nil else { return .standard }
            return FontScale(rawValue: defaults.integer(forKey: Key.fontScale)) ?? .standard
        }
        set { defaults.set(newValue.rawValue, forKey: Key.fontScale) }
    }

    public static var imagesEnabled: Bool {
        get { defaults.object(forKey: Key.imagesEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.imagesEnabled) }
    }

    public static var filterEnabled: Bool {
        get { defaults.bool(forKey: Key.filterEnabled) }
        set { defaults.set(newValue, forKey: Key.filterEnabled) }
    }
}
