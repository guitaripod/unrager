import UIKit

/// Edit Tabs: pick up to five tabs and reorder them. The first section holds the
/// active tabs (draggable to reorder, swipe or the editing control to remove);
/// the second lists the tabs not yet shown (tap to add, up to the cap). Every
/// change persists to `ClientSettings.tabs` and rebuilds the live tab bar so the
/// result is visible the moment Settings is dismissed.
final class EditTabsViewController: UIViewController {
    private enum Section: Int, CaseIterable { case active, available }

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, TabItem>!
    private var active: [TabItem] = ClientSettings.tabs

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Edit Tabs"
        view.backgroundColor = DesignSystem.Color.background
        navigationItem.largeTitleDisplayMode = .never

        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
        config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            self?.removeSwipe(at: indexPath)
        }
        let layout = UICollectionViewCompositionalLayout.list(using: config)
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        view.addManaged(collectionView)
        collectionView.pinEdges(to: view)
        collectionView.isEditing = true

        configureDataSource()
        apply(animated: false)
    }

    /// Rebuilds the live tab bar only when leaving — rebuilding mid-edit would
    /// recreate the Settings stack hosting this very screen and pop it out from
    /// under the user. Selections persist immediately; the bar catches up here.
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard isMovingFromParent || isBeingDismissed else { return }
        (view.window?.rootViewController as? RootViewController)?.rebuildTabs()
    }

    private func configureDataSource() {
        let cellReg = UICollectionView.CellRegistration<UICollectionViewListCell, TabItem> {
            [weak self] cell, indexPath, tab in
            var content = cell.defaultContentConfiguration()
            content.text = tab.title
            content.image = DesignSystem.icon(tab.symbol, pointSize: 18)
            content.imageProperties.tintColor = DesignSystem.Color.accent
            cell.contentConfiguration = content
            let isActive = self?.dataSource.sectionIdentifier(for: indexPath.section) == .active
            if isActive {
                cell.accessories = [
                    .reorder(displayed: .always),
                    .delete(displayed: .always, actionHandler: { [weak self] in self?.remove(tab) }),
                ]
            } else {
                cell.accessories = [
                    .insert(displayed: .always, actionHandler: { [weak self] in self?.add(tab) }),
                ]
            }
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { cv, ip, tab in
            cv.dequeueConfiguredReusableCell(using: cellReg, for: ip, item: tab)
        }

        let headerReg = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader) { [weak self] header, _, indexPath in
            var content = header.defaultContentConfiguration()
            let section = self?.dataSource.sectionIdentifier(for: indexPath.section)
            content.text = section == .active
                ? "Shown · \(self?.active.count ?? 0)/\(TabItem.maxCount)"
                : "More tabs"
            header.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { cv, _, indexPath in
            cv.dequeueConfiguredReusableSupplementary(using: headerReg, for: indexPath)
        }
        dataSource.reorderingHandlers.canReorderItem = { [weak self] tab in
            self?.active.contains(tab) ?? false
        }
        dataSource.reorderingHandlers.didReorder = { [weak self] transaction in
            guard let self else { return }
            self.active = transaction.finalSnapshot.itemIdentifiers(inSection: .active)
            self.persist()
        }
    }

    private func apply(animated: Bool) {
        var snapshot = NSDiffableDataSourceSnapshot<Section, TabItem>()
        snapshot.appendSections([.active, .available])
        snapshot.appendItems(active, toSection: .active)
        snapshot.appendItems(TabItem.allCases.filter { !active.contains($0) }, toSection: .available)
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: animated)
    }

    private func add(_ tab: TabItem) {
        guard active.count < TabItem.maxCount, !active.contains(tab) else {
            Haptics.error()
            return
        }
        active.append(tab)
        Haptics.selection()
        persist()
        apply(animated: true)
    }

    private func remove(_ tab: TabItem) {
        guard active.count > 1, let index = active.firstIndex(of: tab) else {
            Haptics.error()
            return
        }
        active.remove(at: index)
        Haptics.selection()
        persist()
        apply(animated: true)
    }

    private func removeSwipe(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard dataSource.sectionIdentifier(for: indexPath.section) == .active,
              let tab = dataSource.itemIdentifier(for: indexPath) else { return nil }
        let action = UIContextualAction(style: .destructive, title: "Remove") { [weak self] _, _, done in
            self?.remove(tab)
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [action])
    }

    /// Persists the sanitized selection. The live tab bar is rebuilt on exit
    /// (see `viewWillDisappear`).
    private func persist() {
        ClientSettings.tabs = active
    }
}

extension EditTabsViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard dataSource.sectionIdentifier(for: indexPath.section) == .available,
              let tab = dataSource.itemIdentifier(for: indexPath) else { return }
        add(tab)
    }

    func collectionView(_ collectionView: UICollectionView, targetIndexPathForMoveOfItemFromOriginalIndexPath originalIndexPath: IndexPath, atCurrentIndexPath currentIndexPath: IndexPath, toProposedIndexPath proposedIndexPath: IndexPath) -> IndexPath {
        guard dataSource.sectionIdentifier(for: proposedIndexPath.section) == .active else {
            return originalIndexPath
        }
        return proposedIndexPath
    }
}
