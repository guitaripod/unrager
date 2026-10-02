import UIKit
import UnragerKit
import UserNotifications

/// Which notifications raise an alert, and how: a switch per kind, then the
/// banners (sound and quiet hours) and a way into the system's own settings.
/// While the app is open new activity shows as a toast; in the background a
/// short refresh the system schedules posts banners. There is no push server,
/// so nothing arrives once the app is closed. When notifications are off for
/// Unrager in iOS Settings the Banners switch shows off and the System row
/// becomes the way to turn them back on.
final class NotificationSettingsViewController: UIViewController {
    private enum Section: Int, CaseIterable {
        case kinds, banners, system, diagnostics

        var header: String {
            switch self {
            case .kinds: return "Alert me about"
            case .banners: return "Banners"
            case .system: return "System"
            case .diagnostics: return "Diagnostics"
            }
        }
    }

    private enum Item: Hashable {
        case kind(NotificationKind)
        case banners, sound, quietHours, quietWindow, quietStart, quietEnd
        case system
        case lastCheck, backgroundCheck, permission, seenSync, seenMarker, testBanner
    }

    private static let diagnosticRows: [Item] = [
        .lastCheck, .backgroundCheck, .permission, .seenSync, .seenMarker, .testBanner,
    ]

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var footerRegistration: UICollectionView.SupplementaryRegistration<UICollectionViewListCell>!

    /// Whether iOS refuses Unrager's notifications, as last checked. Shared so
    /// the Settings summary says the same as this screen.
    @MainActor private static var deniedBySystem = false
    /// What iOS last said about Unrager's notifications, nil until asked.
    @MainActor private static var permissionStatus: UNAuthorizationStatus?

    /// Banners as they actually behave: on only when switched on here and
    /// allowed by iOS.
    @MainActor private static var bannersEffectivelyOn: Bool {
        NotificationPrefs.bannersEnabled && !deniedBySystem
    }

    /// "5 of 6 · banners on", the line Settings shows for this screen.
    @MainActor
    static var summary: String {
        let on = NotificationKind.allCases.filter { NotificationPrefs.bannerEnabled(for: $0) }.count
        let banners: String
        if NotificationPrefs.bannersEnabled && deniedBySystem {
            banners = "banners off in iOS Settings"
        } else {
            banners = "banners \(NotificationPrefs.bannersEnabled ? "on" : "off")"
        }
        return "\(on) of \(NotificationKind.allCases.count) · \(banners)"
    }

    /// Asks iOS whether Unrager may notify and remembers the answer for
    /// `summary`. Returns whether the answer changed.
    @MainActor
    @discardableResult
    static func refreshSystemPermission() async -> Bool {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        let denied = status == .denied
        permissionStatus = status
        defer { deniedBySystem = denied }
        return denied != deniedBySystem
    }

    /// The Banners footer: how delivery works, what iOS is blocking, and a
    /// quiet-hours window that can never apply.
    static func bannersFooter(deniedBySystem: Bool, bannersOn: Bool, quietHoursOn: Bool,
                              quietStart: Int, quietEnd: Int) -> String {
        var lines: [String] = []
        if deniedBySystem && bannersOn {
            lines.append("Off in iOS Settings: allow notifications for Unrager there to get banners.")
        }
        if bannersOn && quietHoursOn && quietStart == quietEnd {
            lines.append("Start and end are the same, so quiet hours never apply.")
        }
        lines.append("While Unrager is open, new activity shows as a toast. In the background iOS checks now and "
            + "then (often every 15 minutes or more) and posts a banner; nothing arrives once the app is closed. "
            + "During quiet hours banners land silently in Notification Center.")
        return lines.joined(separator: "\n\n")
    }

    private func footer(for section: Section) -> String? {
        switch section {
        case .kinds:
            return "These gate both in-app toasts and system banners. The Notifications tab's badge always counts unread activity."
        case .banners:
            return Self.bannersFooter(
                deniedBySystem: Self.deniedBySystem, bannersOn: NotificationPrefs.bannersEnabled,
                quietHoursOn: NotificationPrefs.quietHoursEnabled,
                quietStart: NotificationPrefs.quietHoursStartMinute, quietEnd: NotificationPrefs.quietHoursEndMinute)
        case .system:
            return nil
        case .diagnostics:
            return "Unrager has no push server: banners come from checks it runs itself, every 15 seconds while it's "
                + "open and in the background only when iOS schedules one. A test banner arrives five seconds after "
                + "the tap, so there is time to leave the app."
        }
    }

    /// "OK, 2m ago", "Failed 2m ago: <reason>" or "Not yet".
    static func checkText(at date: Date?, error: String?, now: Date = Date()) -> String {
        guard let date else { return "Not yet" }
        let ago = now.timeIntervalSince(date) < 5 ? "just now" : "\(Format.relativeTime(date, now: now)) ago"
        guard let error else { return "OK, \(ago)" }
        return "Failed \(ago): \(error)"
    }

    static func permissionText(_ status: UNAuthorizationStatus?) -> String {
        switch status {
        case .authorized?, .ephemeral?: return "Allowed"
        case .provisional?: return "Delivered quietly"
        case .denied?: return "Off in iOS Settings"
        case .notDetermined?: return "Not asked yet"
        case nil: return "Checking…"
        @unknown default: return "Unknown"
        }
    }

    static func seenSyncText(_ state: NotificationPoller.SeenSyncState) -> String {
        switch state {
        case .unknown: return "Not checked yet"
        case .ok: return "On"
        case .unsupported: return "Off: this server doesn't sync it"
        case .failed: return "Last sync failed"
        }
    }

    private var isAccessibilitySize: Bool {
        traitCollection.preferredContentSizeCategory.isAccessibilityCategory
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Notifications"
        view.backgroundColor = DesignSystem.Color.background
        navigationItem.largeTitleDisplayMode = .never
        var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        configuration.headerMode = .supplementary
        configuration.backgroundColor = DesignSystem.Color.background
        let layout = UICollectionViewCompositionalLayout { [weak self] index, environment in
            var configuration = configuration
            let section = Section(rawValue: index)
            configuration.footerMode = section.flatMap { self?.footer(for: $0) } == nil ? .none : .supplementary
            return NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
        }
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
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
        footerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] cell, _, indexPath in
            self?.configureFooter(cell, section: indexPath.section)
        }
        let footer = footerRegistration!
        dataSource.supplementaryViewProvider = { view, kind, indexPath in
            view.dequeueConfiguredReusableSupplementary(
                using: kind == UICollectionView.elementKindSectionHeader ? header : footer, for: indexPath)
        }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections(Section.allCases)
        snapshot.appendItems(NotificationKind.allCases.map(Item.kind), toSection: .kinds)
        snapshot.appendItems(bannerRows, toSection: .banners)
        snapshot.appendItems([.system], toSection: .system)
        snapshot.appendItems(Self.diagnosticRows, toSection: .diagnostics)
        dataSource.apply(snapshot, animatingDifferences: false)

        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            self.refreshBannerRows(animated: false)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(appBecameActive), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        checkSystemPermission()
    }

    @objc private func appBecameActive() { checkSystemPermission() }

    /// Coming back from iOS Settings may have changed the permission; the
    /// switch, the footer and the System row follow it.
    private func checkSystemPermission() {
        Task { [weak self] in
            await Self.refreshSystemPermission()
            self?.refreshBannerRows(animated: false)
            self?.reconfigure([.system] + Self.diagnosticRows)
        }
    }

    private func configureFooter(_ cell: UICollectionViewListCell, section: Int) {
        var content = UIListContentConfiguration.groupedFooter()
        content.text = Section(rawValue: section).flatMap(footer(for:))
        cell.contentConfiguration = content
    }

    /// Redraws the footers on screen in place, so a picker being used isn't
    /// rebuilt under the finger.
    private func refreshFooters() {
        for indexPath in collectionView.indexPathsForVisibleSupplementaryElements(
            ofKind: UICollectionView.elementKindSectionFooter) {
            guard let cell = collectionView.supplementaryView(
                forElementKind: UICollectionView.elementKindSectionFooter, at: indexPath) as? UICollectionViewListCell
            else { continue }
            configureFooter(cell, section: indexPath.section)
        }
        collectionView.collectionViewLayout.invalidateLayout()
    }

    /// The window rows only exist while quiet hours are on, so they never sit
    /// there greyed out; at the accessibility text sizes start and end get a
    /// row each.
    private var bannerRows: [Item] {
        var rows: [Item] = [.banners, .sound, .quietHours]
        if Self.bannersEffectivelyOn && NotificationPrefs.quietHoursEnabled {
            rows += isAccessibilitySize ? [.quietStart, .quietEnd] : [.quietWindow]
        }
        return rows
    }

    private static let windowRows: Set<Item> = [.quietWindow, .quietStart, .quietEnd]

    /// Brings the banner section's rows in line with the settings: the window
    /// rows appear or disappear, and the rest are redrawn.
    private func refreshBannerRows(animated: Bool = true) {
        var snapshot = dataSource.snapshot()
        let current = snapshot.itemIdentifiers(inSection: .banners)
        let wanted = bannerRows
        if current != wanted {
            snapshot.deleteItems(current)
            snapshot.appendItems(wanted, toSection: .banners)
        }
        snapshot.reconfigureItems(wanted.filter { !Self.windowRows.contains($0) && current.contains($0) })
        dataSource.apply(snapshot, animatingDifferences: animated)
        refreshFooters()
    }

    private func configure(_ cell: UICollectionViewListCell, for item: Item) {
        var content = UIListContentConfiguration.valueCell()
        content.textProperties.font = DesignSystem.Typography.body()
        var background = UIBackgroundConfiguration.listCell()
        background.backgroundColor = DesignSystem.Color.elevatedBackground
        cell.backgroundConfiguration = background
        cell.accessories = []
        let bannersOn = Self.bannersEffectivelyOn

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
        func timePicker(_ title: String, minute: Int, change: @escaping (Int) -> Void) {
            let picker = Self.picker(minute: minute, label: "Quiet hours \(title.lowercased())", fixedSize: false) {
                [weak self] in
                change($0)
                self?.refreshFooters()
            }
            cell.contentConfiguration = StackedControlConfiguration(title: title, control: picker)
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
                    [weak self] in
                    NotificationPrefs.quietHoursStartMinute = $0
                    self?.refreshFooters()
                },
                Self.picker(minute: NotificationPrefs.quietHoursEndMinute, label: "Quiet hours end") {
                    [weak self] in
                    NotificationPrefs.quietHoursEndMinute = $0
                    self?.refreshFooters()
                },
            ])
            pickers.spacing = 6
            pickers.frame.size = pickers.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
            cell.accessories = [.customView(configuration: .init(
                customView: pickers, placement: .trailing(), reservedLayoutWidth: .custom(190),
                maintainsFixedSize: true))]
        case .quietStart:
            timePicker("Starts", minute: NotificationPrefs.quietHoursStartMinute) {
                NotificationPrefs.quietHoursStartMinute = $0
            }
            return
        case .quietEnd:
            timePicker("Ends", minute: NotificationPrefs.quietHoursEndMinute) {
                NotificationPrefs.quietHoursEndMinute = $0
            }
            return
        case .lastCheck, .backgroundCheck, .permission, .seenSync, .seenMarker:
            content.text = diagnosticTitle(item)
            content.secondaryText = diagnosticValue(item)
            content.secondaryTextProperties.numberOfLines = 0
            content.secondaryTextProperties.color = DesignSystem.Color.secondaryLabel
        case .testBanner:
            content.text = "Send a test banner"
            content.textProperties.color = DesignSystem.Color.accent
        case .system:
            let blocked = Self.deniedBySystem
            content.text = blocked ? "Turn on notifications in iOS Settings" : "System notification settings"
            content.textProperties.color = blocked ? DesignSystem.Color.accent : DesignSystem.Color.label
            content.image = DesignSystem.icon(blocked ? "bell.slash.fill" : "gear", pointSize: 16)
            content.imageProperties.tintColor = DesignSystem.Color.accent
            cell.accessories = [.disclosureIndicator()]
        }
        cell.contentConfiguration = content
    }

    private func diagnosticTitle(_ item: Item) -> String {
        switch item {
        case .lastCheck: return "Last check"
        case .backgroundCheck: return "Last background check"
        case .permission: return "iOS permission"
        case .seenSync: return "Read sync with server"
        case .seenMarker: return "Read up to"
        default: return ""
        }
    }

    private func diagnosticValue(_ item: Item) -> String {
        let diagnostics = NotificationCenterService.shared.diagnostics
        switch item {
        case .lastCheck:
            return Self.checkText(at: diagnostics.lastPollAt, error: diagnostics.lastPollError)
        case .backgroundCheck:
            return NotificationPrefs.lastBackgroundRefreshAt.map { "\(Format.relativeTime($0)) ago" } ?? "Never yet"
        case .permission:
            return Self.permissionText(Self.permissionStatus)
        case .seenSync:
            return Self.seenSyncText(diagnostics.seenSync)
        case .seenMarker:
            return NotificationPrefs.lastSeenTimestamp.map(Format.absoluteTime) ?? "Nothing yet"
        default:
            return ""
        }
    }

    private func sendTestBanner() {
        Task { [weak self] in
            let sent = await NotificationCenterService.shared.sendTestBanner()
            guard let self else { return }
            if sent {
                Haptics.success()
                self.showToast("A test banner arrives in 5 seconds")
            } else {
                self.present(self.permissionDeniedAlert(), animated: true)
            }
        }
    }

    /// A compact time picker. In the shared window row it is a fixed 92 × 34
    /// so two fit side by side; on its own row it takes its natural size, which
    /// grows with the text size.
    private static func picker(minute: Int, label: String, fixedSize: Bool = true,
                               change: @escaping (Int) -> Void) -> UIDatePicker {
        let picker = UIDatePicker()
        picker.datePickerMode = .time
        picker.preferredDatePickerStyle = .compact
        picker.date = Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
        picker.accessibilityLabel = label
        if fixedSize {
            picker.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                picker.widthAnchor.constraint(equalToConstant: 92),
                picker.heightAnchor.constraint(equalToConstant: 34),
            ])
        }
        picker.addAction(UIAction { [weak picker] _ in
            guard let picker else { return }
            let parts = Calendar.current.dateComponents([.hour, .minute], from: picker.date)
            change((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
        }, for: .valueChanged)
        return picker
    }

    private func reconfigure(_ items: [Item]) {
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(items.filter { snapshot.indexOfItem($0) != nil })
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
            await Self.refreshSystemPermission()
            guard let self else { return }
            NotificationPrefs.bannersEnabled = granted
            self.refreshBannerRows()
            self.reconfigure([.system])
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
        let item = dataSource.itemIdentifier(for: indexPath)
        return item == .system || item == .testBanner
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .system?: Self.openSystemSettings()
        case .testBanner?: sendTestBanner()
        default: break
        }
    }
}

/// A row with its title on one line and a control under it, for the
/// accessibility text sizes where the two don't fit side by side.
private struct StackedControlConfiguration: UIContentConfiguration {
    let title: String
    let control: UIView

    @MainActor
    func makeContentView() -> UIView & UIContentView { StackedControlView(configuration: self) }

    func updated(for state: UIConfigurationState) -> StackedControlConfiguration { self }
}

@MainActor
private final class StackedControlView: UIView, UIContentView {
    private let titleLabel = UILabel()
    private let column = UIStackView()

    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    init(configuration: StackedControlConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        titleLabel.numberOfLines = 0
        titleLabel.textColor = DesignSystem.Color.label
        column.axis = .vertical
        column.alignment = .leading
        column.spacing = 8
        addManaged(column)
        column.pinEdges(to: self, insets: UIEdgeInsets(top: 12, left: 20, bottom: 12, right: 20))
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func apply() {
        guard let configuration = configuration as? StackedControlConfiguration else { return }
        titleLabel.font = DesignSystem.Typography.body()
        titleLabel.text = configuration.title
        column.arrangedSubviews.forEach { $0.removeFromSuperview() }
        column.addArrangedSubview(titleLabel)
        column.addArrangedSubview(configuration.control)
    }
}

#if DEBUG
extension NotificationSettingsViewController {
    /// Screenshot-QA hook (`UNRAGER_SCREEN=notifsettings/<points>`): scrolls
    /// the list `points` down.
    func debugScroll(by points: CGFloat) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, let list = self.view.subviews.compactMap({ $0 as? UICollectionView }).first else { return }
            list.setContentOffset(CGPoint(x: 0, y: points - list.adjustedContentInset.top), animated: false)
        }
    }
}
#endif
