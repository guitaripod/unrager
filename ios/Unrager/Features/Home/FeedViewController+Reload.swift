import Combine
import UIKit
import UnragerKit

extension FeedViewController {
    /// The collection sits under the glass navigation bar with automatic
    /// insets, so its real top is above zero by the adjusted inset.
    func scrollToTop(animated: Bool) {
        collectionView.setContentOffset(
            CGPoint(x: 0, y: -collectionView.adjustedContentInset.top), animated: animated)
    }

    /// Reloads the feed from the top once Settings saves a new server
    /// address: what is on screen came from the old server.
    func reloadOnServerChange() -> AnyCancellable {
        NotificationCenter.default.publisher(for: AppSettings.serverURLDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                AppLogger.shared.info("server address changed: reloading \(type(of: self))", category: .timeline)
                self.viewModel.refresh()
                self.scrollToTop(animated: false)
            }
    }
}
