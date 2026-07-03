import UIKit
import UnragerKit

/// One selectable root tab. The user picks up to five (`RootViewController`
/// honors the order); the catalog is fixed. Each case knows its label, SF
/// Symbol, and how to build its root view controller. Bookmarks and My Profile
/// resolve asynchronously (a keyword prompt / a `whoami` lookup), so their roots
/// are lightweight hosts that defer the real screen.
enum TabItem: String, CaseIterable, Sendable {
    case home
    case search
    case notifications
    case mentions
    case bookmarks
    case myProfile
    case settings

    static let defaults: [TabItem] = [.home, .search, .notifications, .settings]
    static let maxCount = 5

    /// Clamps a selection to the bar's invariants: de-duplicated, capped at
    /// `maxCount`, and never empty (falls back to the defaults).
    static func sanitized(_ items: [TabItem]) -> [TabItem] {
        var seen = Set<TabItem>()
        let unique = items.filter { seen.insert($0).inserted }
        let capped = Array(unique.prefix(maxCount))
        return capped.isEmpty ? defaults : capped
    }

    /// Decodes a persisted raw value, folding the legacy separate "For You" /
    /// "Following" entries into the single Home tab — the live tab itself
    /// toggles between the two modes, so two rows only contradicted the bar.
    static func resolve(persisted raw: String) -> TabItem? {
        if raw == "forYou" || raw == "following" { return .home }
        return TabItem(rawValue: raw)
    }

    var title: String {
        switch self {
        case .home: return "Home"
        case .search: return "Search"
        case .notifications: return "Notifications"
        case .mentions: return "Mentions"
        case .bookmarks: return "Bookmarks"
        case .myProfile: return "My Profile"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house.fill"
        case .search: return "magnifyingglass"
        case .notifications: return "bell.fill"
        case .mentions: return "at"
        case .bookmarks: return "bookmark.fill"
        case .myProfile: return "person.crop.circle.fill"
        case .settings: return "gearshape.fill"
        }
    }

    /// The Edit Tabs subtitle; only Home needs one (to explain that the single
    /// entry carries both feed modes).
    var subtitle: String? {
        self == .home ? "Toggles For You / Following" : nil
    }

    /// List-style tabs read better with large titles; Notifications matches
    /// the compact centered header the feed tabs use (its nav bar carries the
    /// filter menu instead).
    private var prefersLargeTitles: Bool {
        switch self {
        case .settings, .mentions, .bookmarks, .myProfile: return true
        case .home, .search, .notifications: return false
        }
    }

    @MainActor
    func makeViewController() -> UINavigationController {
        let root = makeRoot()
        root.title = title
        root.tabBarItem = UITabBarItem(title: title, image: DesignSystem.icon(symbol), selectedImage: nil)
        let nav = UINavigationController(rootViewController: root)
        nav.navigationBar.prefersLargeTitles = prefersLargeTitles
        return nav
    }

    @MainActor
    private func makeRoot() -> UIViewController {
        switch self {
        case .home: return HomeViewController()
        case .search: return SearchViewController()
        case .notifications: return NotificationsViewController()
        case .mentions: return MentionsViewController()
        case .bookmarks: return BookmarksViewController()
        case .myProfile: return MyProfileViewController()
        case .settings: return SettingsViewController()
        }
    }
}
