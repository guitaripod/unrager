import UIKit
import UnragerKit

/// A fixed-query search feed pushed onto the stack — used when a `#hashtag` in a
/// tweet body is tapped. Reuses all the feed machinery; the query is set once
/// and never edited (unlike the live `SearchViewController`).
final class SearchResultsViewController: FeedViewController {
    private let query: String

    init(query: String, product: SourceProduct) {
        self.query = query
        super.init(viewModel: TimelineViewModel(source: .search(query: query, product: product)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = query
        navigationItem.largeTitleDisplayMode = .never
    }
}
