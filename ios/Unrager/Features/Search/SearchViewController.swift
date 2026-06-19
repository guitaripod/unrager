import UIKit
import UnragerKit

/// Live search over the feed infrastructure. Typing a query swaps the feed's
/// source to `.search`; the product (Top/Latest/People/…) is switchable.
final class SearchViewController: FeedViewController {
    private let searchController = UISearchController(searchResultsController: nil)
    private var product: SourceProduct = .top

    init() {
        super.init(viewModel: TimelineViewModel(source: .search(query: "", product: .top)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Search"
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        searchController.searchBar.delegate = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "Search X"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: DesignSystem.icon("slider.horizontal.3"), menu: productMenu())
    }

    private func productMenu() -> UIMenu {
        UIMenu(title: "Results", children: SourceProduct.allCases.map { item in
            UIAction(title: item.apiValue, state: item == product ? .on : .off) { [weak self] _ in
                self?.product = item
                self?.runSearch()
            }
        })
    }

    private func runSearch() {
        let query = searchController.searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !query.isEmpty else { return }
        viewModel.updateSource(.search(query: query, product: product))
        navigationItem.rightBarButtonItem?.menu = productMenu()
    }
}

extension SearchViewController: UISearchBarDelegate {
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        runSearch()
        searchBar.resignFirstResponder()
    }
}
