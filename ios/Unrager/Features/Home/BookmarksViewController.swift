import UIKit
import UnragerKit

/// Bookmarks as a standalone tab root. X has no "all bookmarks" listing — only
/// keyword search — so this prompts for a keyword on first appearance and shows
/// a search button to change it. Until a keyword is entered the feed shows its
/// awaiting-query empty state.
final class BookmarksViewController: FeedViewController {
    private var hasPrompted = false

    init() {
        super.init(viewModel: TimelineViewModel(source: .bookmarks(query: "")))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Bookmarks"
        navigationItem.largeTitleDisplayMode = .always
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: DesignSystem.icon("magnifyingglass"),
            primaryAction: UIAction { [weak self] _ in self?.promptKeyword() })
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasPrompted else { return }
        hasPrompted = true
        promptKeyword()
    }

    private func promptKeyword() {
        let alert = UIAlertController(
            title: "Search Bookmarks",
            message: "X searches bookmarks by keyword — there's no \"all\" listing.",
            preferredStyle: .alert)
        alert.addTextField {
            $0.placeholder = "keyword"
            $0.autocapitalizationType = .none
            $0.returnKeyType = .search
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Search", style: .default) { [weak self] _ in
            let query = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !query.isEmpty else { return }
            self?.viewModel.updateSource(.bookmarks(query: query))
        })
        present(alert, animated: true)
    }
}
