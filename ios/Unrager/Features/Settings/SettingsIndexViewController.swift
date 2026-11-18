import UIKit

/// The sidebar half of the iPad's settings split: one row per section with the
/// one thing worth knowing about it, and a check on the one showing beside it.
final class SettingsIndexViewController: UIViewController {
    var onChoose: ((SettingsViewController.Section) -> Void)?

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, SettingsViewController.Section>!
    private var summaries: [SettingsViewController.Section: String] = [:]
    private var chosen: SettingsViewController.Section = .server

    private var sections: [SettingsViewController.Section] {
        SettingsViewController.Section.allCases.filter { $0 != .hero }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        view.backgroundColor = DesignSystem.Color.background
        navigationItem.largeTitleDisplayMode = .always

        var configuration = UICollectionLayoutListConfiguration(appearance: .sidebar)
        configuration.backgroundColor = DesignSystem.Color.background
        let layout = UICollectionViewCompositionalLayout.list(using: configuration)
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.backgroundColor = DesignSystem.Color.background
        collectionView.delegate = self
        collectionView.selfSizingInvalidation = .enabled
        view.addManaged(collectionView)
        collectionView.pinEdges(to: view)

        let rows = UICollectionView.CellRegistration<UICollectionViewListCell, SettingsViewController.Section> {
            [weak self] cell, _, section in
            guard let self else { return }
            var content = UIListContentConfiguration.sidebarSubtitleCell()
            content.text = section.indexTitle
            content.secondaryText = self.summaries[section]
            content.secondaryTextProperties.color = DesignSystem.Color.secondaryLabel
            cell.contentConfiguration = content
            cell.accessories = section == self.chosen ? [.checkmark()] : []
        }
        dataSource = UICollectionViewDiffableDataSource<Int, SettingsViewController.Section>(
            collectionView: collectionView
        ) { view, indexPath, section in
            view.dequeueConfiguredReusableCell(using: rows, for: indexPath, item: section)
        }
        apply()
    }

    /// Re-renders the one-line summaries after the server check lands.
    func refresh(summaries: [SettingsViewController.Section: String]) {
        self.summaries = summaries
        guard dataSource != nil else { return }
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// Marks the section whose rows are showing beside this list.
    func mark(_ section: SettingsViewController.Section) {
        guard chosen != section else { return }
        chosen = section
        guard dataSource != nil else { return }
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
        guard let row = sections.firstIndex(of: section) else { return }
        collectionView.selectItem(at: IndexPath(item: row, section: 0), animated: false, scrollPosition: [])
    }

    private func apply() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, SettingsViewController.Section>()
        snapshot.appendSections([0])
        snapshot.appendItems(sections, toSection: 0)
        dataSource.apply(snapshot, animatingDifferences: false)
    }
}

extension SettingsIndexViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let section = dataSource.itemIdentifier(for: indexPath) else { return }
        Haptics.selection()
        chosen = section
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
        onChoose?(section)
    }
}
