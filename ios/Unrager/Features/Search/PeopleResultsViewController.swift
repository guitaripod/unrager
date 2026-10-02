import UIKit
import UnragerKit

/// The People tab of search: accounts matching the query, from the server's
/// people-search route. Tapping one opens that profile. It sits over the
/// search feed while People is the chosen result type.
final class PeopleResultsViewController: PagedUserListViewController {
    private let social = SocialAPI(baseURL: { AppSettings.serverURL })
    private(set) var query = ""

    override var emptyCopy: EmptyCopy {
        EmptyCopy(symbol: "person.2", title: "No people found",
                  subtitle: "Nobody matched \"\(query)\". Try another name or handle.")
    }

    /// Shows the accounts for `newQuery`, starting from the first page.
    func show(query newQuery: String) {
        guard newQuery != query else { return }
        query = newQuery
        if isViewLoaded { restart() }
    }

    override func fetchPage(cursor: String?) async throws -> Page {
        guard !query.isEmpty else { return Page(users: [], cursor: nil) }
        let page = try await social.searchPeople(query: query, cursor: cursor)
        return Page(users: page.users, cursor: page.cursor)
    }
}
