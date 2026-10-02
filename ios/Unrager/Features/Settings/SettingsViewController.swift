import UIKit
import UnragerKit

/// Settings: a grouped list that opens on who you are and whether the server
/// is reachable, then everything that shapes the app, a section at a time. The
/// server and its filter are checked live each time the screen appears, so it
/// answers "is it working?" before it asks for anything.
final class SettingsViewController: UIViewController {
    enum Section: Int, CaseIterable {
        case hero, server, reading, appearance, writing, notifications, data, about

        var header: String? {
            switch self {
            case .hero: return nil
            case .server: return "Server"
            case .reading: return "Reading"
            case .appearance: return "Appearance"
            case .writing: return "Writing"
            case .notifications: return "Notifications"
            case .data: return "Data"
            case .about: return "About"
            }
        }

        var footer: String? {
            switch self {
            case .server:
                return "The unrager server (`unrager serve`) does the X work: a machine you keep running, reached by its LAN or Tailscale address."
            case .reading:
                return "The rage filter runs each post on Home through the server's model; matches are removed from the feed. Post stats opens engagement figures under a post."
            case .writing:
                return "On: the compose and reply buttons open the official X app with your text prefilled. Off: posts go through the server's own OAuth client."
            case .data:
                return "Saved timelines let a feed paint at once on launch; they are replaced by the first fetch."
            default:
                return nil
            }
        }
    }

    enum Item: Hashable {
        case hero
        case serverAddress, serverStatus
        case rageFilter, filterRules, postStats, markSeen, images
        case theme, textSize, tabs
        case officialCompose
        case notifications
        case savedTimelines, imageCache, shareLogs, resetSettings
        case whatsNew, version, source
    }

    /// What the server check last found.
    enum Connection: Equatable {
        case checking
        case online(version: String, signedInAs: String?)
        case offline(String)
    }

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var connection = Connection.checking
    private var account: Whoami?
    private var imageCacheBytes: Int?
    private var filterSummary: String?
    private var checkTask: Task<Void, Never>?
    /// Bumped on every flip of the rage-filter switch, so a late failure of an
    /// earlier flip can't undo a newer one.
    private var filterSwitchGeneration = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        view.backgroundColor = DesignSystem.Color.background
        navigationItem.largeTitleDisplayMode = .never
        configureCollectionView()
        applySnapshot()
        NotificationCenter.default.addObserver(
            self, selector: #selector(fontScaleApplied), name: AppSettings.fontScaleDidChange, object: nil)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            self.dataSource.reconfigureAllItems()
        }
    }

    /// At the accessibility text sizes a choice's value moves under its label
    /// and the whole row opens the menu, since a trailing button beside the
    /// label leaves neither room to read.
    private var isAccessibilitySize: Bool {
        traitCollection.preferredContentSizeCategory.isAccessibilityCategory
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshImageCacheSize()
        refreshConnection()
        reconfigure(Item.allSettingsRows)
        Task { [weak self] in
            if await NotificationSettingsViewController.refreshSystemPermission() {
                self?.reconfigure([.notifications])
            }
        }
    }

    #if DEBUG
    /// Screenshot-QA hook: scrolls the list `points` down.
    func debugScroll(by points: CGFloat) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self else { return }
            self.collectionView.setContentOffset(
                CGPoint(x: 0, y: points - self.collectionView.adjustedContentInset.top), animated: false)
        }
    }
    #endif

    // MARK: - Layout

    private func configureCollectionView() {
        var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        configuration.headerMode = .supplementary
        configuration.footerMode = .supplementary
        configuration.backgroundColor = DesignSystem.Color.background
        let layout = UICollectionViewCompositionalLayout { index, environment in
            var configuration = configuration
            let section = Section(rawValue: index)
            configuration.headerMode = section?.header == nil ? .none : .supplementary
            configuration.footerMode = section?.footer == nil ? .none : .supplementary
            return NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
        }
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.backgroundColor = DesignSystem.Color.background
        collectionView.delegate = self
        collectionView.alwaysBounceVertical = true
        view.addManaged(collectionView)
        collectionView.pinEdges(to: view)

        let rows = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            self?.configure(cell, for: item)
        }
        let hero = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, _ in
            guard let self else { return }
            cell.contentConfiguration = SettingsHeroConfiguration(account: self.account, connection: self.connection)
            cell.backgroundConfiguration = Self.cardBackground()
            cell.accessories = self.account == nil ? [] : [.disclosureIndicator()]
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { view, indexPath, item in
            if item == .hero { return view.dequeueConfiguredReusableCell(using: hero, for: indexPath, item: item) }
            return view.dequeueConfiguredReusableCell(using: rows, for: indexPath, item: item)
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
            content.attributedText = InlineMarkdown.render(
                Section(rawValue: indexPath.section)?.footer ?? "", font: DesignSystem.Typography.metric(),
                color: DesignSystem.Color.secondaryLabel)
            cell.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { view, kind, indexPath in
            view.dequeueConfiguredReusableSupplementary(
                using: kind == UICollectionView.elementKindSectionHeader ? header : footer, for: indexPath)
        }
    }

    private static func cardBackground() -> UIBackgroundConfiguration {
        var background = UIBackgroundConfiguration.listCell()
        background.backgroundColor = DesignSystem.Color.elevatedBackground
        return background
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections(Section.allCases)
        snapshot.appendItems([.hero], toSection: .hero)
        snapshot.appendItems([.serverAddress, .serverStatus], toSection: .server)
        snapshot.appendItems([.rageFilter, .filterRules, .postStats, .markSeen, .images], toSection: .reading)
        snapshot.appendItems([.theme, .textSize, .tabs], toSection: .appearance)
        snapshot.appendItems([.officialCompose], toSection: .writing)
        snapshot.appendItems([.notifications], toSection: .notifications)
        snapshot.appendItems([.savedTimelines, .imageCache, .shareLogs, .resetSettings], toSection: .data)
        snapshot.appendItems([.whatsNew, .version, .source], toSection: .about)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func reconfigure(_ items: [Item]) {
        var snapshot = dataSource.snapshot()
        let present = items.filter { snapshot.indexOfItem($0) != nil }
        guard !present.isEmpty else { return }
        snapshot.reconfigureItems(present)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// A new text size re-resolves every row's font, except the slider being
    /// dragged, which would be rebuilt under the finger.
    @objc private func fontScaleApplied() {
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { $0 != .textSize })
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: - Rows

    private func configure(_ cell: UICollectionViewListCell, for item: Item) {
        var content = isAccessibilitySize ? UIListContentConfiguration.subtitleCell() : UIListContentConfiguration.valueCell()
        content.textProperties.font = DesignSystem.Typography.body()
        content.secondaryTextProperties.font = DesignSystem.Typography.body()
        content.secondaryTextProperties.color = DesignSystem.Color.secondaryLabel
        cell.backgroundConfiguration = Self.cardBackground()
        cell.accessories = []

        func tile(_ symbol: String, _ color: UIColor) {
            content.image = IconTile.image(symbol: symbol, color: color)
            content.imageProperties.reservedLayoutSize = CGSize(width: 30, height: 30)
            content.imageToTextPadding = 14
        }
        func toggle(_ title: String, isOn: Bool, change: @escaping (Bool) -> Void) {
            content.text = title
            let control = UISwitch()
            control.isOn = isOn
            control.accessibilityLabel = title
            control.addAction(UIAction { [weak control] _ in
                guard let control else { return }
                Haptics.selection()
                change(control.isOn)
            }, for: .valueChanged)
            cell.accessories = [.customView(configuration: .init(
                customView: control, placement: .trailing(), maintainsFixedSize: true))]
        }
        func menu<Option: Equatable>(
            _ title: String, current: Option, options: [Option], label: @escaping (Option) -> String,
            select: @escaping (Option) -> Void
        ) {
            content.text = title
            let button = settingsMenuButton(current: current, options: options, title: label, select: select)
            if isAccessibilitySize, let choices = button.menu {
                content.secondaryText = label(current)
                cell.accessories = [.popUpMenu(choices)]
                return
            }
            content.secondaryText = nil
            button.accessibilityLabel = title
            cell.accessories = [.customView(configuration: .init(
                customView: button, placement: .trailing(), maintainsFixedSize: true))]
        }

        switch item {
        case .hero:
            break
        case .serverAddress:
            tile("server.rack", .systemBlue)
            content.text = "Address"
            content.secondaryText = SettingsFormat.host(of: AppSettings.serverURLString)
            cell.accessories = [.customView(configuration: .init(
                customView: Self.pencil(), placement: .trailing(), maintainsFixedSize: true))]
        case .serverStatus:
            tile("bolt.horizontal.fill", .systemGreen)
            content.text = "Connection"
            switch connection {
            case .checking:
                content.secondaryText = "Checking…"
            case let .online(version, _):
                content.secondaryText = "Connected · v\(version)"
                content.secondaryTextProperties.color = DesignSystem.Color.retweet
            case let .offline(reason):
                content.secondaryText = reason
                content.secondaryTextProperties.color = .systemRed
            }
            content.secondaryTextProperties.numberOfLines = 2
        case .rageFilter:
            tile("line.3.horizontal.decrease", .systemRed)
            toggle("Rage filter", isOn: AppSettings.filterEnabled) { [weak self] isOn in
                self?.setFilterEnabled(isOn)
            }
        case .filterRules:
            tile("slider.horizontal.3", .systemOrange)
            content.text = "Filter rules"
            content.secondaryText = filterSummary
            cell.accessories = [.disclosureIndicator()]
        case .postStats:
            tile("chart.bar.xaxis", .systemPurple)
            menu("Post stats", current: AppSettings.postStatsMode, options: PostStatsMode.allCases,
                 label: \.title) { [weak self] mode in
                AppSettings.postStatsMode = mode
                NotificationCenter.default.post(name: AppSettings.displayDidChange, object: nil)
                self?.reconfigure([.postStats])
            }
        case .markSeen:
            tile("eye", .systemTeal)
            toggle("Dim posts you've read", isOn: ClientSettings.markSeenEnabled) { ClientSettings.markSeenEnabled = $0 }
        case .images:
            tile("photo", .systemYellow)
            toggle("Load images", isOn: AppSettings.imagesEnabled) { isOn in
                AppSettings.imagesEnabled = isOn
                NotificationCenter.default.post(name: AppSettings.displayDidChange, object: nil)
            }
        case .theme:
            tile("circle.lefthalf.filled", .systemIndigo)
            menu("Theme", current: AppSettings.appearance, options: AppearanceMode.allCases,
                 label: \.title) { [weak self] mode in
                AppSettings.appearance = mode
                self?.view.window?.overrideUserInterfaceStyle = UIUserInterfaceStyle(rawValue: mode.rawValue) ?? .unspecified
                self?.reconfigure([.theme])
            }
        case .textSize:
            cell.contentConfiguration = SettingsTextSizeConfiguration(scale: AppSettings.fontScale) { scale in
                AppSettings.fontScale = scale
                NotificationCenter.default.post(name: AppSettings.fontScaleDidChange, object: nil)
            }
            return
        case .tabs:
            tile("rectangle.grid.1x2", .systemMint)
            content.text = "Tabs"
            content.secondaryText = SettingsFormat.tabSummary(ClientSettings.tabs)
            content.secondaryTextProperties.numberOfLines = 1
            cell.accessories = [.disclosureIndicator()]
        case .officialCompose:
            tile("square.and.pencil", .systemBlue)
            toggle("Post with the X app", isOn: AppSettings.composeViaOfficialApp) {
                AppSettings.composeViaOfficialApp = $0
            }
        case .notifications:
            tile("bell.badge.fill", .systemRed)
            content.text = "Notifications"
            content.secondaryText = NotificationSettingsViewController.summary
            cell.accessories = [.disclosureIndicator()]
        case .savedTimelines:
            tile("clock.arrow.circlepath", .systemGray)
            content.text = "Saved timelines"
            content.secondaryText = SettingsFormat.bytes(TimelineCache.shared.diskUsage())
        case .imageCache:
            tile("photo.stack", .systemGray)
            content.text = "Saved pictures"
            content.secondaryText = imageCacheBytes.map(SettingsFormat.bytes) ?? "Counting…"
        case .shareLogs:
            tile("doc.text.magnifyingglass", .systemGray)
            content.text = "Share logs"
            cell.accessories = [.disclosureIndicator()]
        case .resetSettings:
            tile("arrow.counterclockwise", .systemRed)
            content.text = "Reset settings"
            content.textProperties.color = .systemRed
        case .whatsNew:
            tile("sparkles", .systemPink)
            content.text = "What's new"
            cell.accessories = [.disclosureIndicator()]
        case .version:
            tile("info.circle.fill", .systemGray)
            content.text = "Version"
            content.secondaryText = Self.versionText(connection: connection)
        case .source:
            tile("chevron.left.forwardslash.chevron.right", .systemGray)
            content.text = "Source code"
            cell.accessories = [.customView(configuration: .init(
                customView: UIImageView(image: DesignSystem.icon("arrow.up.right", pointSize: 13, weight: .semibold))
                    .tinted(DesignSystem.Color.tertiaryLabel),
                placement: .trailing(), maintainsFixedSize: true))]
        }
        cell.contentConfiguration = content
    }

    private static func pencil() -> UIImageView {
        UIImageView(image: DesignSystem.icon("pencil", pointSize: 14)).tinted(DesignSystem.Color.accent)
    }

    private static func versionText(connection: Connection) -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        guard case let .online(serverVersion, _) = connection else { return "\(version) (\(build))" }
        return "\(version) (\(build)) · server \(serverVersion)"
    }

    // MARK: - Server

    /// Looks at the server again: is it up, is X signed in, what is the filter
    /// set to. One round of requests, run side by side; the rows update as the
    /// answers land.
    private func refreshConnection() {
        checkTask?.cancel()
        connection = .checking
        reconfigure([.serverStatus, .version])
        checkTask = Task { [weak self] in
            let api = AppEnvironment.shared.api
            async let health = Self.result { try await api.health() }
            async let me = AppEnvironment.shared.whoami()
            async let rules = Self.result { try await api.filterConfig() }
            let (healthResult, whoami, rulesResult) = await (health, me, rules)
            guard !Task.isCancelled, let self else { return }
            switch healthResult {
            case let .success(info):
                self.connection = .online(version: info.version, signedInAs: whoami?.handle)
            case let .failure(error):
                self.connection = .offline(Self.describe(error))
            }
            self.account = whoami
            if case let .success(config) = rulesResult {
                let strictness = config.strictness?.title.lowercased()
                let topics = "\(config.dropTopics.count) topic\(config.dropTopics.count == 1 ? "" : "s")"
                self.filterSummary = strictness.map { "\(topics) · \($0)" } ?? topics
            }
            self.reconfigure([.hero, .serverStatus, .filterRules, .version])
        }
    }

    private nonisolated static func result<T: Sendable>(_ work: @Sendable () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await work()) } catch { return .failure(error) }
    }

    private static func describe(_ error: Error) -> String {
        let text = error.localizedDescription
        return text.isEmpty ? "Can't reach the server" : text
    }

    private func editServerAddress(prefill: String = AppSettings.serverURLString) {
        let alert = UIAlertController(
            title: "Server address",
            message: "The address of your unrager server, such as 100.64.0.1:7777.",
            preferredStyle: .alert)
        alert.addTextField { field in
            field.text = prefill
            field.placeholder = "http://192.168.1.10:7777"
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self, weak alert] _ in
            self?.commitServerAddress(alert?.textFields?.first?.text ?? "")
        })
        present(alert, animated: true)
    }

    /// Checks an address typed in the alert before it replaces the current one:
    /// a server that answers is saved at once, one that doesn't asks whether to
    /// save it anyway, and text that isn't an http(s) address is refused with a
    /// reason while the old address stays.
    private func commitServerAddress(_ text: String) {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = SettingsFormat.serverAddress(typed) else {
            Haptics.error()
            present(AlertFactory.error(
                SettingsError.invalidAddress(typed), title: "Not a server address"), animated: true)
            return
        }
        let candidate = url.absoluteString
        guard candidate != AppSettings.serverURLString else { return }
        checkTask?.cancel()
        connection = .checking
        reconfigure([.serverStatus])
        checkTask = Task { [weak self] in
            let result = await Self.probe(url)
            guard !Task.isCancelled, let self else { return }
            switch result {
            case .success:
                self.applyServerAddress(candidate)
            case let .failure(error):
                self.refreshConnection()
                self.offerUnreachable(candidate, error: error)
            }
        }
    }

    /// Asks a candidate server for its health on a short-lived session with a
    /// short timeout, so a wrong address answers in seconds rather than the
    /// client's usual twenty.
    private nonisolated static func probe(_ url: URL) async -> Result<ServerHealth, Error> {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 10
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let client = APIClient(transport: URLSessionTransport(session: session), baseURL: { url })
        return await result { try await client.health() }
    }

    private func offerUnreachable(_ candidate: String, error: Error) {
        Haptics.error()
        let alert = UIAlertController(
            title: "Can't reach \(SettingsFormat.host(of: candidate))",
            message: "\(Self.describe(error))\n\nSave it anyway, or keep \(SettingsFormat.host(of: AppSettings.serverURLString))?",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Save Anyway", style: .default) { [weak self] _ in
            self?.applyServerAddress(candidate)
        })
        alert.addAction(UIAlertAction(title: "Edit", style: .default) { [weak self] _ in
            self?.editServerAddress(prefill: candidate)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    /// Stores the new address and tells the app, which starts over against
    /// that server: its session, saved timelines and signed-in account.
    private func applyServerAddress(_ candidate: String) {
        AppSettings.serverURLString = candidate
        AppLogger.shared.info("server URL changed to \(candidate)", category: .app)
        Haptics.success()
        account = nil
        filterSummary = nil
        NotificationCenter.default.post(name: AppSettings.serverURLDidChange, object: nil)
        reconfigure([.serverAddress, .savedTimelines, .rageFilter])
        refreshConnection()
    }

    private enum SettingsError: LocalizedError {
        case invalidAddress(String)

        var errorDescription: String? {
            switch self {
            case let .invalidAddress(text):
                return "\"\(text)\" isn't an http or https address. The server stays as it was."
            }
        }
    }

    /// Flips the rage filter here and on the server together: when the server
    /// refuses, the switch goes back and says so, rather than looking changed
    /// until the next launch restores the server's setting.
    private func setFilterEnabled(_ isOn: Bool) {
        AppSettings.filterEnabled = isOn
        filterSwitchGeneration += 1
        let generation = filterSwitchGeneration
        Task { [weak self] in
            do {
                try await SessionSync.patchFilterEnabled(isOn)
            } catch {
                guard let self, generation == self.filterSwitchGeneration else { return }
                AppSettings.filterEnabled = !isOn
                Haptics.error()
                self.reconfigure([.rageFilter])
                self.present(AlertFactory.error(error, title: "Couldn't change the filter"), animated: true)
            }
        }
    }

    // MARK: - Data

    /// Reads how much the picture cache takes and shows it on its row.
    private func refreshImageCacheSize() {
        Task {
            imageCacheBytes = await ImagePipeline.shared.diskUsage()
            reconfigure([.imageCache])
        }
    }

    private func confirmClearImages() {
        let sheet = UIAlertController(title: nil, message: "Pictures load from the network again the next time they are shown.",
                                      preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Clear Saved Pictures", style: .destructive) { [weak self] _ in
            Task {
                await ImagePipeline.shared.clearMedia()
                Haptics.success()
                self?.refreshImageCacheSize()
            }
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(sheet, animated: true)
    }

    private func confirmClearTimelines() {
        let sheet = UIAlertController(title: nil, message: "Feeds will load from the server the next time you open them.",
                                      preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Clear Saved Timelines", style: .destructive) { [weak self] _ in
            TimelineCache.shared.clearAll()
            ProfileCache.shared.clearAll()
            Haptics.success()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.reconfigure([.savedTimelines]) }
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(sheet, animated: true)
    }

    private func shareLogs() {
        guard let url = AppLogger.shared.currentLogFileURL, FileManager.default.fileExists(atPath: url.path) else {
            showToast("No log yet")
            return
        }
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        present(activity, animated: true)
    }

    private func confirmReset() {
        let sheet = UIAlertController(
            title: "Reset settings?",
            message: "Text size, theme, tabs, post stats, images, notification alerts and the other switches go back to "
                + "how they started. Your server, the rage filter, what you've already read in Notifications and "
                + "recent searches stay.",
            preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Reset", style: .destructive) { [weak self] _ in self?.resetSettings() })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(sheet, animated: true)
    }

    /// Forgets every preference the app keeps except the state listed in
    /// `SettingsReset`, and lets the screen, the tab bar and the app's window
    /// catch up.
    private func resetSettings() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where SettingsReset.clears(key) {
            defaults.removeObject(forKey: key)
        }
        view.window?.overrideUserInterfaceStyle = .unspecified
        (view.window?.rootViewController as? RootViewController)?.rebuildTabs()
        NotificationCenter.default.post(name: AppSettings.fontScaleDidChange, object: nil)
        NotificationCenter.default.post(name: AppSettings.displayDidChange, object: nil)
        Haptics.success()
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }
}

/// What "Reset settings" forgets: every `unrager.` preference except state
/// that isn't a setting (where the server is, what was already read or alerted,
/// recent searches, the one-time appearance cleanup) and the rage filter, which
/// mirrors the server's own setting and would otherwise switch off on this
/// device only.
enum SettingsReset {
    static let keptKeys: Set<String> = [
        "unrager.serverURL",
        "unrager.filterEnabled",
        "unrager.appearanceMigratedToLocal.v1",
        "unrager.ios.recentSearches",
        "unrager.notifications.deliveredBannerIDs",
    ]
    static let keptPrefixes = ["unrager.notifications.lastSeen"]

    static func clears(_ key: String) -> Bool {
        key.hasPrefix("unrager.") && !keptKeys.contains(key) && !keptPrefixes.contains { key.hasPrefix($0) }
    }
}

extension SettingsViewController.Item {
    /// The rows that mirror a setting another screen can change.
    static let allSettingsRows: [Self] = [
        .serverAddress, .rageFilter, .postStats, .markSeen, .images, .theme, .textSize, .tabs,
        .officialCompose, .notifications, .savedTimelines,
    ]
}

extension SettingsViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        switch item {
        case .hero:
            guard let handle = account?.handle else { return }
            navigationController?.pushViewController(ProfileViewController(handle: handle), animated: true)
        case .serverAddress:
            editServerAddress()
        case .serverStatus:
            Haptics.tap()
            refreshConnection()
        case .filterRules:
            navigationController?.pushViewController(FilterSettingsViewController(), animated: true)
        case .tabs:
            navigationController?.pushViewController(EditTabsViewController(), animated: true)
        case .notifications:
            navigationController?.pushViewController(NotificationSettingsViewController(), animated: true)
        case .savedTimelines:
            confirmClearTimelines()
        case .imageCache:
            confirmClearImages()
        case .shareLogs:
            shareLogs()
        case .resetSettings:
            confirmReset()
        case .whatsNew:
            navigationController?.pushViewController(ChangelogViewController(), animated: true)
        case .source:
            if let url = URL(string: "https://github.com/guitaripod/unrager") { UIApplication.shared.open(url) }
        case .rageFilter, .postStats, .markSeen, .images, .theme, .textSize, .officialCompose, .version:
            break
        }
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .postStats?, .theme?:
            return isAccessibilitySize
        case .rageFilter?, .markSeen?, .images?, .textSize?, .officialCompose?, .version?:
            return false
        default:
            return true
        }
    }
}

private extension UIImageView {
    func tinted(_ color: UIColor) -> UIImageView {
        tintColor = color
        return self
    }
}
