import UIKit
import UnragerKit

/// A paginated followers / following list for a user. Tapping a row opens that
/// user's profile.
final class UserListViewController: PagedUserListViewController {
    enum Mode {
        case followers
        case following

        var title: String {
            switch self {
            case .followers: return "Followers"
            case .following: return "Following"
            }
        }

        var emptySymbol: String {
            switch self {
            case .followers: return "person.2"
            case .following: return "person.badge.plus"
            }
        }

        var emptyText: String {
            switch self {
            case .followers: return "No followers to show — X only shares part of this list."
            case .following: return "This account doesn't follow anyone X will show."
            }
        }
    }

    private let userID: String
    private let mode: Mode
    private let social = SocialAPI(baseURL: { AppSettings.serverURL })

    init(user: User, mode: Mode) {
        self.userID = user.restID
        self.mode = mode
        super.init(nibName: nil, bundle: nil)
        title = mode.title
    }

    /// Opens by id/handle only (debug router); the server resolves either.
    init(userID: String, mode: Mode) {
        self.userID = userID
        self.mode = mode
        super.init(nibName: nil, bundle: nil)
        title = mode.title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var emptyCopy: EmptyCopy {
        EmptyCopy(symbol: mode.emptySymbol, title: "Nothing here", subtitle: mode.emptyText)
    }

    override func fetchPage(cursor: String?) async throws -> Page {
        let page = mode == .followers
            ? try await social.followers(userID: userID, cursor: cursor)
            : try await social.following(userID: userID, cursor: cursor)
        return Page(users: page.users, cursor: page.cursor,
                    endNote: page.verifiedOnly ? "X only shares this account's verified followers." : nil)
    }
}
