import UIKit
import UnragerKit

/// The posts quoting one post, as an ordinary feed: paging, pull to refresh,
/// the empty and error states and every row action come from
/// `FeedViewController`.
final class QuotesViewController: FeedViewController {
    init(tweetID: String) {
        super.init(viewModel: TimelineViewModel(source: .quotes(tweetID: tweetID)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Quotes"
        navigationItem.largeTitleDisplayMode = .never
    }
}
