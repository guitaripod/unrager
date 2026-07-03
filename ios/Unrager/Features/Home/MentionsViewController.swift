import UIKit
import UnragerKit

/// The Mentions feed as a standalone tab root. A thin `FeedViewController` over
/// the `.mentions` source; seen-tracking and the jump-to-unread button come
/// from the base class.
final class MentionsViewController: FeedViewController {
    init() {
        super.init(viewModel: TimelineViewModel(source: .mentions))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Mentions"
        navigationItem.largeTitleDisplayMode = .automatic
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.navigationBar.prefersLargeTitles = true
    }
}
