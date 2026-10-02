import UIKit
import UnragerKit

/// Which notifications raise an alert, and how: a switch per kind, then the
/// banners (sound and quiet hours) and a way into the system's own settings.
/// Banners come from an in-app poller while the app is active; there is no push
/// server, so they don't arrive when it's closed.
final class NotificationSettingsViewController: UIViewController {
    private enum Section: Int, CaseIterable {
        case kinds, banners, system

        var header: String {
            switch self {
            case .kinds: return "Alert me about"
            case .banners: return "Banners"
            case .system: return "System"
            }
        }

        var footer: String? {
            switch self {
            case .kinds:
                return "These gate both in-app toasts and system banners. The Notifications tab's badge always counts unread activity."
            case .banners:
                return "Banners are best-effort and only arrive while Unrager is active. During quiet hours they land silently in Notification Center."
            case .system:
                return nil
            }
        }
    }

    private enum Item: Hashable {
        case kind(NotificationKind)
        case banners, sound, quietHours, quietWindow
        case system
    }

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    /// "5 of 6 · banners on", the line Settings shows for this screen.
    @MainActor
    static var summary: String {
        let on = NotificationKind.allCases.filter { NotificationPrefs.bannerEnabled(for: $0) }.count
        return "\(on) of \(NotificationKind.allCases.count) · banners \(NotificationPrefs.bannersEnabled ? "on" : "off")"
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Notifications"
        view.backgroundColor = DesignSystem.Color.background
        navigationItem.largeTitleDisplayMode = .never
        var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        configuration.headerMode = .supplementary
        configuration.footerMode = .supplementary
        configuration.backgroundColor = DesignSystem.Color.background
        collectionView = UICollectionView(
            frame: view.bounds, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: configuration))
        collectionView.backgroundColor = DesignSystem.Color.background
        collectionView.delegate = self
        view.addManaged(collectionView)
        collectionView.pinEdges(to: view)

        let rows = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            self?.configure(cell, for: item)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { view, indexPath, item in
            view.dequeueConfiguredReusableCell(using: rows, for: indexPath, item: item)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { cell, _, indexPath in
            var content = UIListContentConfiguration.groupedHeader()
            content.text = Section(rawValue: indexPath.section)?.header
            cell.contentConfiguration = content
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { cell, _, indexPath in
            var content = UIListContentConfiguration.groupedFooter()
            content.text = Section(rawValue: indexPath.section)?.footer
            cell.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { view, kind, indexPath in
            view.dequeueConfiguredReusableSupplementary(
                using: kind == UICollectionView.elementKindSectionHeader ? header : footer, for: indexPath)
        }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections(Section.allCases)
        snapshot.appendItems(NotificationKind.allCases.map(Item.kind), toSection: .kinds)
        snapshot.appendItems(Self.bannerRows, toSection: .banners)
        snapshot.appendItems([.system], toSection: .system)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// The window row only exists while quiet hours are on, so it never sits
    /// there greyed out.
    private static var bannerRows: [Item] {
        var rows: [Item] = [.banners, .sound, .quietHours]
        if NotificationPrefs.bannersEnabled && NotificationPrefs.quietHoursEnabled { rows.append(.quietWindow) }
        return rows
    }

    /// Brings the banner section's rows in line with the settings: the window
    /// row appears or disappears, and the rest are redrawn.
    private func refreshBannerRows() {
        var snapshot = dataSource.snapshot()
        let current = snapshot.itemIdentifiers(inSection: .banners)
        let wanted = Self.bannerRows
        let removed = current.filter { !wanted.contains($0) }
        if !removed.isEmpty { snapshot.deleteItems(removed) }
        if wanted.contains(.quietWindow), !current.contains(.quietWindow) {
            snapshot.appendItems([.quietWindow], toSection: .banners)
        }
        snapshot.reconfigureItems(snapshot.itemIdentifiers(inSection: .banners).filter { $0 != .quietWindow })
        dataSource.apply(snapshot, animatingDifferences: true)
    }

    private func configure(_ cell: UICollectionViewListCell, for item: Item) {
        var content = UIListContentConfiguration.valueCell()
        content.textProperties.font = DesignSystem.Typography.body()
        var background = UIBackgroundConfiguration.listCell()
        background.backgroundColor = DesignSystem.Color.elevatedBackground
        cell.backgroundConfiguration = background
        cell.accessories = []
        let bannersOn = NotificationPrefs.bannersEnabled

        func toggle(_ title: String, isOn: Bool, enabled: Bool = true, change: @escaping (Bool) -> Void) {
            content.text = title
            content.textProperties.color = enabled ? DesignSystem.Color.label : DesignSystem.Color.tertiaryLabel
            let control = UISwitch()
            control.isOn = isOn
            control.isEnabled = enabled
            control.accessibilityLabel = title
            control.addAction(UIAction { [weak control] _ in
                guard let control else { return }
                Haptics.selection()
                change(control.isOn)
            }, for: .valueChanged)
            cell.accessories = [.customView(configuration: .init(
                customView: control, placement: .trailing(), maintainsFixedSize: true))]
        }

        switch item {
        case let .kind(kind):
            toggle(kind.title, isOn: NotificationPrefs.bannerEnabled(for: kind)) { NotificationPrefs.setBannerEnabled($0, for: kind) }
        case .banners:
            toggle("Banners", isOn: bannersOn) { [weak self] isOn in self?.setBanners(isOn) }
        case .sound:
            toggle("Banner sound", isOn: NotificationPrefs.bannerSoundEnabled, enabled: bannersOn) {
                NotificationPrefs.bannerSoundEnabled = $0
            }
        case .quietHours:
            toggle("Quiet hours", isOn: NotificationPrefs.quietHoursEnabled, enabled: bannersOn) { [weak self] isOn in
                NotificationPrefs.quietHoursEnabled = isOn
                self?.refreshBannerRows()
            }
        case .quietWindow:
            content.text = "From … until"
            let pickers = UIStackView(arrangedSubviews: [
                Self.picker(minute: NotificationPrefs.quietHoursStartMinute, label: "Quiet hours start") {
                    NotificationPrefs.quietHoursStartMinute = $0
                },
                Self.picker(minute: NotificationPrefs.quietHoursEndMinute, label: "Quiet hours end") {
                    NotificationPrefs.quietHoursEndMinute = $0
                },
            ])
            pickers.spacing = 6
            cell.accessories = [.customView(configuration: .init(
                customView: pickers, placement: .trailing(), reservedLayoutWidth: .custom(190),
                maintainsFixedSize: true))]
        case .system:
            content.text = "System notification settings"
            content.image = DesignSystem.icon("gear", pointSize: 16)
            content.imageProperties.tintColor = DesignSystem.Color.accent
            cell.accessories = [.disclosureIndicator()]
        }
        cell.contentConfiguration = content
    }

    private static func picker(minute: Int, label: String, change: @escaping (Int) -> Void) -> UIDatePicker {
        let picker = UIDatePicker()
        picker.datePickerMode = .time
        picker.preferredDatePickerStyle = .compact
        picker.date = Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
        picker.accessibilityLabel = label
        picker.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            picker.widthAnchor.constraint(equalToConstant: 92),
            picker.heightAnchor.constraint(equalToConstant: 34),
        ])
        picker.addAction(UIAction { [weak picker] _ in
            guard let picker else { return }
            let parts = Calendar.current.dateComponents([.hour, .minute], from: picker.date)
            change((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
        }, for: .valueChanged)
        return picker
    }

    private func reconfigure(_ items: [Item]) {
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(items)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// Turning banners on asks the system for permission first; a refusal puts
    /// the switch back and says where to change it.
    private func setBanners(_ isOn: Bool) {
        guard isOn else {
            NotificationPrefs.bannersEnabled = false
            refreshBannerRows()
            return
        }
        Task { [weak self] in
            let granted = await NotificationCenterService.shared.requestAuthorization()
            guard let self else { return }
            NotificationPrefs.bannersEnabled = granted
            self.refreshBannerRows()
            if !granted { self.present(self.permissionDeniedAlert(), animated: true) }
        }
    }

    private func permissionDeniedAlert() -> UIAlertController {
        let alert = UIAlertController(
            title: "Notifications are off",
            message: "Allow notifications for Unrager in System Settings to receive banners.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Open Settings", style: .default) { _ in Self.openSystemSettings() })
        alert.addAction(UIAlertAction(title: "Not Now", style: .cancel))
        return alert
    }

    private static func openSystemSettings() {
        guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

extension NotificationSettingsViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        dataSource.itemIdentifier(for: indexPath) == .system
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        if dataSource.itemIdentifier(for: indexPath) == .system { Self.openSystemSettings() }
    }
}
