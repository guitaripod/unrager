import UIKit

/// The status line under a list: "Loading more…" while a page is in flight, a
/// retry when one failed, or a closing note. Owns the footer's state and keeps
/// the visible footer in step with it, so a screen only sets `state`.
@MainActor
final class PagingFooter {
    enum State: Equatable {
        case hidden
        case loading(String)
        case failed(String)
        case note(String)
    }

    static let kind = "paging-footer"

    var onRetry: (() -> Void)?
    private(set) var state: State = .hidden
    private weak var collectionView: UICollectionView?

    init(collectionView: UICollectionView? = nil) {
        self.collectionView = collectionView
    }

    func attach(to collectionView: UICollectionView) {
        self.collectionView = collectionView
    }

    /// The boundary item to add to the section that should carry the footer.
    static func boundaryItem() -> NSCollectionLayoutBoundarySupplementaryItem {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(56))
        return NSCollectionLayoutBoundarySupplementaryItem(layoutSize: size, elementKind: kind, alignment: .bottom)
    }

    /// Makes `dataSource` dequeue this footer for its boundary item.
    func install<Section: Hashable & Sendable, Item: Hashable & Sendable>(
        on dataSource: UICollectionViewDiffableDataSource<Section, Item>
    ) {
        let registration = UICollectionView.SupplementaryRegistration<FeedFooterView>(
            elementKind: Self.kind) { [weak self] footer, _, _ in
            self?.configure(footer)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: registration, for: indexPath)
        }
    }

    func set(_ newState: State) {
        guard newState != state else { return }
        state = newState
        refresh()
    }

    private func configure(_ footer: FeedFooterView) {
        footer.onRetry = nil
        switch state {
        case .hidden:
            footer.setHidden()
        case .loading(let text):
            footer.showLoading(text)
        case .failed(let text):
            footer.show(text: text, showsRetry: true)
            footer.onRetry = { [weak self] in self?.onRetry?() }
        case .note(let text):
            footer.show(text: text, showsRetry: false)
        }
    }

    private func refresh() {
        guard let collectionView else { return }
        for indexPath in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: Self.kind) {
            if let footer = collectionView.supplementaryView(forElementKind: Self.kind, at: indexPath) as? FeedFooterView {
                configure(footer)
            }
        }
        collectionView.collectionViewLayout.invalidateLayout()
    }
}
