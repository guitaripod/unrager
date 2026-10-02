import UIKit
import UnragerKit

/// A paginated "Liked by" list for a tweet. Tapping a row opens that user's
/// profile.
final class LikersViewController: PagedUserListViewController {
    private let tweetID: String

    init(tweetID: String) {
        self.tweetID = tweetID
        super.init(nibName: nil, bundle: nil)
        title = "Liked by"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var emptyCopy: EmptyCopy {
        EmptyCopy(symbol: "heart", title: "No likes yet",
                  subtitle: "Nobody has liked this tweet, or X isn't sharing the list.")
    }

    override var logCategory: LogCategory { .timeline }

    override func fetchPage(cursor: String?) async throws -> Page {
        let page = try await AppEnvironment.shared.api.likers(tweetID: tweetID, cursor: cursor)
        return Page(users: page.users, cursor: page.cursor)
    }
}
