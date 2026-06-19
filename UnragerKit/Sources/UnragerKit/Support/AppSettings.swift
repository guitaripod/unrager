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

    public static var imagesEnabled: Bool {
        get { defaults.object(forKey: Key.imagesEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.imagesEnabled) }
    }

    public static var filterEnabled: Bool {
        get { defaults.bool(forKey: Key.filterEnabled) }
        set { defaults.set(newValue, forKey: Key.filterEnabled) }
    }
}
