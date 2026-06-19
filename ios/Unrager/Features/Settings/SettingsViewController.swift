import UIKit
import UnragerKit

/// A full-bleed tappable settings row that highlights on touch-down, used for
/// the navigation rows inside grouped cards.
private final class RowButton: UIControl {
    var onTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? DesignSystem.Color.separator.withAlphaComponent(0.25) : .clear }
    }
}

/// Server address, appearance, image toggle, and a connection test. The server
/// URL is the one piece of client config the app needs — everything else lives
/// server-side.
final class SettingsViewController: UIViewController {
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let serverField = UITextField()
    private let statusLabel = UILabel()
    private let appearanceControl = UISegmentedControl(items: AppearanceMode.allCases.map(\.title))
    private let fontScaleControl = UISegmentedControl(items: FontScale.allCases.map(\.title))
    private let imagesSwitch = UISwitch()
    private let filterSwitch = UISwitch()
    private let markSeenSwitch = UISwitch()
    private let profileButton = UIButton(configuration: .gray())
    private let notificationsSwitch = UISwitch()
    private var kindSwitches: [NotificationKind: UISwitch] = [:]
    private var kindRows: [UIView] = []
    private var notificationsCardStack: UIStackView?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        view.backgroundColor = DesignSystem.Color.background
        navigationItem.largeTitleDisplayMode = .never
        buildLayout()
    }

    private func buildLayout() {
        stack.axis = .vertical
        stack.spacing = DesignSystem.Spacing.xl
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = .init(top: 18, leading: 16, bottom: 32, trailing: 16)

        view.addManaged(scrollView)
        scrollView.pinEdges(toSafeAreaOf: view)
        scrollView.addManaged(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor),
        ])

        serverField.text = AppSettings.serverURLString
        serverField.placeholder = "http://192.168.1.10:7777"
        serverField.borderStyle = .none
        serverField.font = DesignSystem.Typography.body()
        serverField.autocapitalizationType = .none
        serverField.autocorrectionType = .no
        serverField.keyboardType = .URL
        serverField.clearButtonMode = .whileEditing
        serverField.addTarget(self, action: #selector(serverChanged), for: .editingChanged)

        statusLabel.font = DesignSystem.Typography.metric()
        statusLabel.textColor = DesignSystem.Color.secondaryLabel
        statusLabel.numberOfLines = 0

        appearanceControl.selectedSegmentIndex = AppSettings.appearance.rawValue
        appearanceControl.addTarget(self, action: #selector(appearanceChanged), for: .valueChanged)

        fontScaleControl.selectedSegmentIndex = AppSettings.fontScale.rawValue
        fontScaleControl.addTarget(self, action: #selector(fontScaleChanged), for: .valueChanged)

        imagesSwitch.isOn = AppSettings.imagesEnabled
        imagesSwitch.addTarget(self, action: #selector(imagesChanged), for: .valueChanged)

        markSeenSwitch.isOn = ClientSettings.markSeenEnabled
        markSeenSwitch.addTarget(self, action: #selector(markSeenChanged), for: .valueChanged)

        filterSwitch.isOn = AppSettings.filterEnabled
        filterSwitch.addTarget(self, action: #selector(filterChanged), for: .valueChanged)

        stack.addArrangedSubview(section("Server", card: card([
            fieldRow(serverField),
            navRow("Test connection", icon: "bolt.horizontal") { [weak self] in self?.testConnection() },
            contentRow(statusLabel),
        ]), footnote: "The unrager server (`unrager serve`) — a Linux box, a Mac, any machine you keep running. Use its LAN or Tailscale address."))

        stack.addArrangedSubview(section("Account", card: card([
            navRow("Open my profile", icon: "person.crop.circle") { [weak self] in self?.openMyProfile() },
        ])))

        stack.addArrangedSubview(section("Tabs", card: card([
            navRow("Edit tabs", icon: "rectangle.grid.1x2") { [weak self] in
                self?.navigationController?.pushViewController(EditTabsViewController(), animated: true)
            },
        ]), footnote: "Choose up to \(TabItem.maxCount) tabs and reorder them."))

        stack.addArrangedSubview(section("Appearance", card: card([
            contentRow(appearanceControl),
            contentRow(fontScaleControl),
        ]), footnote: "Text size scales the whole app."))

        stack.addArrangedSubview(section("Feed", card: card([
            toggleRow("Load images", imagesSwitch),
            toggleRow("Track seen tweets", markSeenSwitch),
        ]), footnote: "Reports tweets you scroll past on Following and Mentions to the server's read tracker and dims them on reload."))

        stack.addArrangedSubview(notificationsSection())

        stack.addArrangedSubview(section("Rage filter", card: card([
            toggleRow("Hide rage tweets", filterSwitch),
            navRow("Edit filter rubric", icon: "slider.horizontal.3") { [weak self] in
                self?.navigationController?.pushViewController(FilterSettingsViewController(), animated: true)
            },
        ]), footnote: "Runs each tweet through your local Ollama classifier; matches are removed from the feed. Refresh after toggling."))

        stack.addArrangedSubview(section("About", card: card([
            contentRow(captionLabel("unrager · a calm X client. The server does the X work; this app is a thin native client.")),
        ])))
    }

    // MARK: - Notifications

    /// The notifications card: a master banner toggle, per-type toggles (enabled
    /// only while the master is on), and a row that jumps to the system
    /// notification settings. The unread badge is independent of these toggles —
    /// they only gate local banners. NO PUSH: banners are foreground/best-effort.
    private func notificationsSection() -> UIView {
        notificationsSwitch.isOn = NotificationPrefs.bannersEnabled
        notificationsSwitch.addTarget(self, action: #selector(notificationsChanged), for: .valueChanged)

        var rows: [UIView] = [toggleRow("Notifications", notificationsSwitch)]
        kindRows = NotificationKind.allCases.map { kind in
            let control = UISwitch()
            control.isOn = NotificationPrefs.bannerEnabled(for: kind)
            control.addAction(UIAction { _ in
                NotificationPrefs.setBannerEnabled(control.isOn, for: kind)
                Haptics.selection()
            }, for: .valueChanged)
            kindSwitches[kind] = control
            return toggleRow(kind.title, control)
        }
        rows.append(contentsOf: kindRows)
        rows.append(navRow("System notification settings", icon: "gear") { [weak self] in
            self?.openSystemNotificationSettings()
        })

        updateKindRowsEnabled()
        return section("Notifications", card: card(rows),
                       footnote: "Banners are delivered by an in-app poller while Unrager is active (best-effort in the background); there is no push server, so they won't arrive when the app is closed. The Notifications-tab badge always counts unread activity regardless of these toggles.")
    }

    private func updateKindRowsEnabled() {
        let enabled = notificationsSwitch.isOn
        for control in kindSwitches.values { control.isEnabled = enabled }
        for row in kindRows { row.alpha = enabled ? 1 : 0.4 }
    }

    @objc private func notificationsChanged() {
        Haptics.selection()
        if notificationsSwitch.isOn {
            Task { [weak self] in
                let granted = await NotificationCenterService.shared.requestAuthorization()
                guard let self else { return }
                if granted {
                    NotificationPrefs.bannersEnabled = true
                } else {
                    self.notificationsSwitch.setOn(false, animated: true)
                    NotificationPrefs.bannersEnabled = false
                    self.present(self.permissionDeniedAlert(), animated: true)
                }
                self.updateKindRowsEnabled()
            }
        } else {
            NotificationPrefs.bannersEnabled = false
            updateKindRowsEnabled()
        }
    }

    private func permissionDeniedAlert() -> UIAlertController {
        let alert = UIAlertController(
            title: "Notifications are off",
            message: "Allow notifications for Unrager in System Settings to receive banners.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Open Settings", style: .default) { [weak self] _ in
            self?.openSystemNotificationSettings()
        })
        alert.addAction(UIAlertAction(title: "Not Now", style: .cancel))
        return alert
    }

    private func openSystemNotificationSettings() {
        let urlString = UIApplication.openNotificationSettingsURLString
        guard let url = URL(string: urlString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Grouped-card building blocks

    private func section(_ title: String, card: UIView, footnote: String? = nil) -> UIView {
        let header = UILabel()
        header.text = title.uppercased()
        header.font = DesignSystem.Typography.caption()
        header.textColor = DesignSystem.Color.secondaryLabel
        header.directionalLayoutMargins = .init(top: 0, leading: 4, bottom: 0, trailing: 4)

        let column = UIStackView(arrangedSubviews: [headerWrap(header), card])
        column.axis = .vertical
        column.spacing = DesignSystem.Spacing.xs
        if let footnote {
            column.addArrangedSubview(footnoteLabel(footnote))
        }
        return column
    }

    private func headerWrap(_ label: UILabel) -> UIView {
        let wrap = UIView()
        wrap.addManaged(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: wrap.topAnchor),
            label.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
        ])
        return wrap
    }

    /// A rounded, elevated container stacking rows with hairline separators
    /// inset to the row content — the native grouped-settings card.
    private func card(_ rows: [UIView]) -> UIView {
        let inner = UIStackView()
        inner.axis = .vertical
        inner.spacing = 0
        for (index, row) in rows.enumerated() {
            if index > 0 { inner.addArrangedSubview(separator()) }
            inner.addArrangedSubview(row)
        }
        let container = UIView()
        container.backgroundColor = DesignSystem.Color.elevatedBackground
        container.layer.cornerRadius = 14
        container.layer.cornerCurve = .continuous
        container.clipsToBounds = true
        container.addManaged(inner)
        inner.pinEdges(to: container)
        return container
    }

    private func separator() -> UIView {
        let line = UIView()
        line.backgroundColor = DesignSystem.Color.separator
        let wrap = UIView()
        wrap.addManaged(line)
        NSLayoutConstraint.activate([
            line.heightAnchor.constraint(equalToConstant: 0.5),
            line.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 16),
            line.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
            line.topAnchor.constraint(equalTo: wrap.topAnchor),
            line.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
        ])
        return wrap
    }

    private func toggleRow(_ title: String, _ control: UISwitch) -> UIView {
        let label = UILabel()
        label.text = title
        label.font = DesignSystem.Typography.body()
        label.textColor = DesignSystem.Color.label
        control.setContentHuggingPriority(.required, for: .horizontal)
        let row = paddedRow([label, UIView(), control])
        return row
    }

    private func navRow(_ title: String, icon: String, _ action: @escaping () -> Void) -> UIView {
        let button = RowButton()
        button.onTap = action
        let glyph = UIImageView(image: DesignSystem.icon(icon, pointSize: 16, weight: .regular))
        glyph.tintColor = DesignSystem.Color.accent
        glyph.setContentHuggingPriority(.required, for: .horizontal)
        let label = UILabel()
        label.text = title
        label.font = DesignSystem.Typography.body()
        label.textColor = DesignSystem.Color.label
        let chevron = UIImageView(image: DesignSystem.icon("chevron.right", pointSize: 13, weight: .semibold))
        chevron.tintColor = DesignSystem.Color.separator
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        let content = UIStackView(arrangedSubviews: [glyph, label, UIView(), chevron])
        content.axis = .horizontal
        content.alignment = .center
        content.spacing = DesignSystem.Spacing.m
        content.isUserInteractionEnabled = false
        button.addManaged(content)
        content.pinEdges(to: button, insets: UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16))
        return button
    }

    private func fieldRow(_ field: UITextField) -> UIView { paddedRow([field]) }
    private func contentRow(_ view: UIView) -> UIView { paddedRow([view]) }

    private func paddedRow(_ subviews: [UIView]) -> UIView {
        let row = UIStackView(arrangedSubviews: subviews)
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = DesignSystem.Spacing.s
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = .init(top: 12, leading: 16, bottom: 12, trailing: 16)
        return row
    }

    private func footnoteLabel(_ text: String) -> UIView {
        let label = captionLabel(text)
        return headerWrap(label)
    }

    private func captionLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = DesignSystem.Typography.metric()
        label.textColor = DesignSystem.Color.secondaryLabel
        label.numberOfLines = 0
        return label
    }

    @objc private func serverChanged() {
        AppSettings.serverURLString = serverField.text ?? ""
    }

    @objc private func appearanceChanged() {
        let mode = AppearanceMode(rawValue: appearanceControl.selectedSegmentIndex) ?? .system
        AppSettings.appearance = mode
        view.window?.overrideUserInterfaceStyle = UIUserInterfaceStyle(rawValue: mode.rawValue) ?? .unspecified
    }

    @objc private func fontScaleChanged() {
        AppSettings.fontScale = FontScale(rawValue: fontScaleControl.selectedSegmentIndex) ?? .standard
        NotificationCenter.default.post(name: AppSettings.fontScaleDidChange, object: nil)
        Haptics.selection()
    }

    @objc private func imagesChanged() {
        AppSettings.imagesEnabled = imagesSwitch.isOn
    }

    @objc private func filterChanged() {
        AppSettings.filterEnabled = filterSwitch.isOn
        SessionSync.patchFilterEnabled(filterSwitch.isOn)
        Haptics.selection()
    }

    @objc private func markSeenChanged() {
        ClientSettings.markSeenEnabled = markSeenSwitch.isOn
        Haptics.selection()
    }

    private func openMyProfile() {
        Haptics.tap()
        profileButton.isEnabled = false
        Task {
            defer { profileButton.isEnabled = true }
            do {
                let me = try await AppEnvironment.shared.api.whoami()
                navigationController?.pushViewController(ProfileViewController(handle: me.handle), animated: true)
            } catch {
                present(AlertFactory.error(error, title: "Couldn't load profile"), animated: true)
            }
        }
    }

    private func testConnection() {
        statusLabel.textColor = DesignSystem.Color.secondaryLabel
        statusLabel.text = "Connecting…"
        Task {
            do {
                let me = try await AppEnvironment.shared.api.whoami()
                statusLabel.textColor = DesignSystem.Color.retweet
                statusLabel.text = "Connected · signed in as @\(me.handle)"
                Haptics.success()
            } catch {
                statusLabel.textColor = .systemRed
                statusLabel.text = error.localizedDescription
                Haptics.error()
            }
        }
    }
}
