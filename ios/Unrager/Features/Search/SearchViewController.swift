import UIKit
import UnragerKit

/// Live search over the feed infrastructure. Typing a query swaps the feed's
/// source to `.search`; the product (Top/Latest/People/…) is switchable.
/// Until a query runs, the empty state shows the persisted recent searches —
/// tappable to re-run, clearable in one tap.
final class SearchViewController: FeedViewController {
    private let searchController = UISearchController(searchResultsController: nil)
    private var product: SourceProduct = .top
    private let recentsTable = UITableView(frame: .zero, style: .insetGrouped)
    private var recents: [String] = []

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
        navigationItem.rightBarButtonItem = productButton()
        configureRecents()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshRecents()
    }

    /// The result types a search can show as tweets. People results are a
    /// different kind of row the server doesn't return, so they aren't offered.
    private static let products = SourceProduct.allCases.filter { $0 != .people }

    /// A bar button titled with the active result type, so which one is in
    /// force is always visible, opening the menu that changes it.
    private func productButton() -> UIBarButtonItem {
        let item = UIBarButtonItem(title: product.apiValue, menu: productMenu())
        item.accessibilityLabel = "Results: \(product.apiValue)"
        return item
    }

    private func productMenu() -> UIMenu {
        UIMenu(title: "Results", options: .singleSelection, children: Self.products.map { item in
            UIAction(title: item.apiValue, state: item == product ? .on : .off) { [weak self] _ in
                self?.selectProduct(item)
            }
        })
    }

    private func selectProduct(_ item: SourceProduct) {
        product = item
        navigationItem.rightBarButtonItem = productButton()
        runSearch()
    }

    private func runSearch() {
        let query = searchController.searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !query.isEmpty else { return }
        ClientSettings.addRecentSearch(query)
        viewModel.updateSource(.search(query: query, product: product))
        refreshRecents()
    }

    // MARK: - Recent searches

    private func configureRecents() {
        recentsTable.backgroundColor = DesignSystem.Color.background
        recentsTable.dataSource = self
        recentsTable.delegate = self
        recentsTable.keyboardDismissMode = .onDrag
        recentsTable.isHidden = true
        view.addManaged(recentsTable)
        recentsTable.pinEdges(to: view)
    }

    /// Shows the recents list only while no search has run and there is
    /// something to show; otherwise the feed (or its "Search X" empty state)
    /// stays in charge.
    private func refreshRecents() {
        recents = ClientSettings.recentSearches
        let visible = viewModel.awaitingQuery && !recents.isEmpty
        recentsTable.isHidden = !visible
        if visible { recentsTable.reloadData() }
    }

    /// Clears the results and brings the recent searches back, after the query
    /// is emptied or the search is cancelled.
    private func showRecents() {
        viewModel.updateSource(.search(query: "", product: product))
        refreshRecents()
    }

    private func performRecent(_ query: String) {
        Haptics.selection()
        searchController.searchBar.text = query
        searchController.isActive = false
        runSearch()
    }

    private func clearRecents() {
        Haptics.selection()
        ClientSettings.clearRecentSearches()
        refreshRecents()
    }
}

extension SearchViewController: UISearchBarDelegate {
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        runSearch()
        searchBar.resignFirstResponder()
    }

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        if searchText.isEmpty { showRecents() }
    }

    func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
        showRecents()
    }
}

extension SearchViewController: UITableViewDataSource, UITableViewDelegate {
    func numberOfSections(in tableView: UITableView) -> Int { 2 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? recents.count : 1
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? "Recent searches" : nil
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "recent")
            ?? UITableViewCell(style: .default, reuseIdentifier: "recent")
        var content = cell.defaultContentConfiguration()
        if indexPath.section == 0 {
            content.text = recents[indexPath.row]
            content.textProperties.color = DesignSystem.Color.label
            content.image = DesignSystem.icon("clock.arrow.circlepath", pointSize: 15)
            content.imageProperties.tintColor = DesignSystem.Color.secondaryLabel
        } else {
            content.text = "Clear recent searches"
            content.textProperties.color = .systemRed
            content.textProperties.alignment = .center
        }
        cell.contentConfiguration = content
        cell.backgroundColor = DesignSystem.Color.elevatedBackground
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 0 {
            performRecent(recents[indexPath.row])
        } else {
            clearRecents()
        }
    }
}
