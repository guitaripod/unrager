import UIKit
import UnragerKit

/// Bookmarks as a standalone tab root. Loads the full bookmarks timeline by
/// default (the server's `/api/sources/bookmarks` with no query); the search
/// field narrows it via X's bookmark keyword search, and clearing or
/// cancelling the search restores the full listing.
final class BookmarksViewController: FeedViewController {
    private let searchController = UISearchController(searchResultsController: nil)

    init() {
        super.init(viewModel: TimelineViewModel(source: .bookmarks(query: "")))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Bookmarks"
        navigationItem.largeTitleDisplayMode = .always
        searchController.searchBar.placeholder = "Search bookmarks"
        searchController.searchBar.autocapitalizationType = .none
        searchController.searchBar.delegate = self
        searchController.obscuresBackgroundDuringPresentation = false
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
    }

    private func applyQuery(_ raw: String?) {
        let query = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        viewModel.updateSource(.bookmarks(query: query))
    }
}

extension BookmarksViewController: UISearchBarDelegate {
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        applyQuery(searchBar.text)
    }

    func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
        applyQuery(nil)
    }

    /// Clearing the field (the `x` button or select-all-delete) restores the
    /// full timeline without waiting for a Search tap; typing alone never
    /// fires a fetch.
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        guard searchText.isEmpty else { return }
        applyQuery(nil)
    }
}
