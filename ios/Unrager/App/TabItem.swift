import UIKit
import UnragerKit

/// One selectable root tab. The user picks up to five (`RootViewController`
/// honors the order); the catalog is fixed. Each case knows its label, SF
/// Symbol, and how to build its root view controller. Bookmarks and My Profile
/// resolve asynchronously (a keyword prompt / a `whoami` lookup), so their roots
/// are lightweight hosts that defer the real screen.
enum TabItem: String, CaseIterable, Sendable {
    case forYou
    case following
    case search
    case notifications
    case mentions
    case bookmarks
    case myProfile
    case settings

    static let defaults: [TabItem] = [.forYou, .search, .notifications, .settings]
    static let maxCount = 5

    /// Clamps a selection to the bar's invariants: de-duplicated, capped at
    /// `maxCount`, and never empty (falls back to the defaults).
    static func sanitized(_ items: [TabItem]) -> [TabItem] {
        var seen = Set<TabItem>()
        let unique = items.filter { seen.insert($0).inserted }
        let capped = Array(unique.prefix(maxCount))
        return capped.isEmpty ? defaults : capped
    }

    var title: String {
        switch self {
        case .forYou: return "For You"
        case .following: return "Following"
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
        case .forYou: return "sparkles"
        case .following: return "person.2.fill"
        case .search: return "magnifyingglass"
        case .notifications: return "bell.fill"
        case .mentions: return "at"
        case .bookmarks: return "bookmark.fill"
        case .myProfile: return "person.crop.circle.fill"
        case .settings: return "gearshape.fill"
        }
    }

    /// Notifications and Settings read better with large titles.
    private var prefersLargeTitles: Bool {
        switch self {
        case .notifications, .settings, .mentions, .bookmarks, .myProfile: return true
        case .forYou, .following, .search: return false
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
        case .forYou: return HomeViewController(initialFollowing: false)
        case .following: return HomeViewController(initialFollowing: true)
        case .search: return SearchViewController()
        case .notifications: return NotificationsViewController()
        case .mentions: return MentionsViewController()
        case .bookmarks: return BookmarksViewController()
        case .myProfile: return MyProfileViewController()
        case .settings: return SettingsViewController()
        }
    }
}
