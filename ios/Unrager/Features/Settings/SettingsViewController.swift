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
    private let officialComposeSwitch = UISwitch()
    private let profileButton = UIButton(configuration: .gray())
    private let notificationsSwitch = UISwitch()
    private let bannerSoundSwitch = UISwitch()
    private let quietHoursSwitch = UISwitch()
    private let quietStartPicker = UIDatePicker()
    private let quietEndPicker = UIDatePicker()
    private var kindSwitches: [NotificationKind: UISwitch] = [:]
    private var bannerOnlyRows: [UIView] = []
    private var quietWindowRow: UIView?

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
        serverField.textColor = DesignSystem.Color.secondaryLabel
        serverField.autocapitalizationType = .none
        serverField.autocorrectionType = .no
        serverField.keyboardType = .URL
        serverField.returnKeyType = .done
        serverField.clearButtonMode = .whileEditing
        serverField.addTarget(self, action: #selector(serverEditingBegan), for: .editingDidBegin)
        serverField.addTarget(self, action: #selector(serverEditingEnded), for: .editingDidEnd)
        serverField.addTarget(self, action: #selector(serverReturnTapped), for: .editingDidEndOnExit)

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

        officialComposeSwitch.isOn = AppSettings.composeViaOfficialApp
        officialComposeSwitch.addTarget(self, action: #selector(officialComposeChanged), for: .valueChanged)

        stack.addArrangedSubview(section("Server", card: card([
            labeledFieldRow("Server URL", serverField),
            navRow("Test connection", icon: "bolt.horizontal") { [weak self] in self?.testConnection() },
            contentRow(statusLabel),
        ]), footnote: "The unrager server (`unrager serve`) — a Linux box, a Mac, any machine you keep running. Use its LAN or Tailscale address. Tap the address to edit; it applies when you finish editing."))

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

        stack.addArrangedSubview(section("Composing", card: card([
            toggleRow("Tweet with the X app", officialComposeSwitch),
        ]), footnote: "On: the Tweet and reply buttons open the official X app with your text prefilled (and copied to the clipboard) — no developer account, no cost. Off: posts through the server's OAuth client."))

        stack.addArrangedSubview(notificationsSection())

        stack.addArrangedSubview(section("Rage filter", card: card([
            toggleRow("Hide rage tweets", filterSwitch),
            navRow("Edit filter rubric", icon: "slider.horizontal.3") { [weak self] in
                self?.navigationController?.pushViewController(FilterSettingsViewController(), animated: true)
            },
        ]), footnote: "Runs each tweet through your local Ollama classifier; matches are removed from the feed. Refresh after toggling."))

        stack.addArrangedSubview(section("About", card: card([
            navRow("What's new", icon: "sparkles") { [weak self] in
                self?.navigationController?.pushViewController(ChangelogViewController(), animated: true)
            },
            contentRow(captionLabel("unrager · a calm X client. The server does the X work; this app is a thin native client.")),
        ])))
    }

    // MARK: - Notifications

    /// The notifications card: per-type toggles (gating both in-app toasts and
    /// local banners), a master banner toggle, banner sound + quiet hours
    /// (banner-only, so they follow the master), and a row that jumps to the
    /// system notification settings. The unread badge is independent of every
    /// toggle here. NO PUSH: banners are foreground/best-effort.
    private func notificationsSection() -> UIView {
        notificationsSwitch.isOn = NotificationPrefs.bannersEnabled
        notificationsSwitch.addTarget(self, action: #selector(notificationsChanged), for: .valueChanged)

        var rows: [UIView] = NotificationKind.allCases.map { kind in
            let control = UISwitch()
            control.isOn = NotificationPrefs.bannerEnabled(for: kind)
            control.addAction(UIAction { _ in
                NotificationPrefs.setBannerEnabled(control.isOn, for: kind)
                Haptics.selection()
            }, for: .valueChanged)
            kindSwitches[kind] = control
            return toggleRow(kind.title, control)
        }
        rows.append(toggleRow("Banners", notificationsSwitch))

        bannerSoundSwitch.isOn = NotificationPrefs.bannerSoundEnabled
        bannerSoundSwitch.addTarget(self, action: #selector(bannerSoundChanged), for: .valueChanged)
        quietHoursSwitch.isOn = NotificationPrefs.quietHoursEnabled
        quietHoursSwitch.addTarget(self, action: #selector(quietHoursChanged), for: .valueChanged)
        let soundRow = toggleRow("Banner sound", bannerSoundSwitch)
        let quietRow = toggleRow("Quiet hours", quietHoursSwitch)
        let windowRow = quietHoursWindowRow()
        quietWindowRow = windowRow
        bannerOnlyRows = [soundRow, quietRow, windowRow]
        rows.append(contentsOf: bannerOnlyRows)

        rows.append(navRow("System notification settings", icon: "gear") { [weak self] in
            self?.openSystemNotificationSettings()
        })

        updateBannerRowsEnabled()
        return section("Notifications", card: card(rows),
                       footnote: "The type toggles gate both in-app toasts and system banners; likes and reposts are off by default. Banners are delivered by an in-app poller while Unrager is active (best-effort in the background); there is no push server, so they won't arrive when the app is closed. During quiet hours banners land silently in Notification Center. The Notifications-tab badge always counts unread activity regardless of these toggles.")
    }

    /// The "From … until …" row of compact time pickers bounding the
    /// quiet-hours window; only enabled while quiet hours are on.
    private func quietHoursWindowRow() -> UIView {
        for picker in [quietStartPicker, quietEndPicker] {
            picker.datePickerMode = .time
            picker.preferredDatePickerStyle = .compact
            picker.setContentHuggingPriority(.required, for: .horizontal)
        }
        quietStartPicker.date = Self.time(minute: NotificationPrefs.quietHoursStartMinute)
        quietEndPicker.date = Self.time(minute: NotificationPrefs.quietHoursEndMinute)
        quietStartPicker.accessibilityLabel = "Quiet hours start"
        quietEndPicker.accessibilityLabel = "Quiet hours end"
        quietStartPicker.addTarget(self, action: #selector(quietWindowChanged), for: .valueChanged)
        quietEndPicker.addTarget(self, action: #selector(quietWindowChanged), for: .valueChanged)

        return paddedRow([captionLabel("From"), quietStartPicker,
                          captionLabel("until"), quietEndPicker, UIView()])
    }

    private static func time(minute: Int) -> Date {
        Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
    }

    private static func minute(of date: Date) -> Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    /// Sound and quiet hours only shape system banners, so they follow the
    /// master banner switch; the per-type rows stay live regardless because
    /// they also gate in-app toasts.
    private func updateBannerRowsEnabled() {
        let enabled = notificationsSwitch.isOn
        bannerSoundSwitch.isEnabled = enabled
        quietHoursSwitch.isEnabled = enabled
        let quietOn = enabled && quietHoursSwitch.isOn
        quietStartPicker.isEnabled = quietOn
        quietEndPicker.isEnabled = quietOn
        for row in bannerOnlyRows { row.alpha = enabled ? 1 : 0.4 }
        if enabled { quietWindowRow?.alpha = quietOn ? 1 : 0.4 }
    }

    @objc private func bannerSoundChanged() {
        NotificationPrefs.bannerSoundEnabled = bannerSoundSwitch.isOn
        Haptics.selection()
    }

    @objc private func quietHoursChanged() {
        NotificationPrefs.quietHoursEnabled = quietHoursSwitch.isOn
        updateBannerRowsEnabled()
        Haptics.selection()
    }

    @objc private func quietWindowChanged() {
        NotificationPrefs.quietHoursStartMinute = Self.minute(of: quietStartPicker.date)
        NotificationPrefs.quietHoursEndMinute = Self.minute(of: quietEndPicker.date)
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
                self.updateBannerRowsEnabled()
            }
        } else {
            NotificationPrefs.bannersEnabled = false
            updateBannerRowsEnabled()
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

    private func contentRow(_ view: UIView) -> UIView { paddedRow([view]) }

    /// A captioned, visibly-editable field row: a small "Server URL"-style
    /// caption above the value, with a trailing pencil glyph signalling that
    /// the text edits in place.
    private func labeledFieldRow(_ title: String, _ field: UITextField) -> UIView {
        let caption = UILabel()
        caption.text = title
        caption.font = DesignSystem.Typography.caption()
        caption.textColor = DesignSystem.Color.secondaryLabel

        let column = UIStackView(arrangedSubviews: [caption, field])
        column.axis = .vertical
        column.spacing = 2

        let pencil = UIImageView(image: DesignSystem.icon("pencil", pointSize: 14))
        pencil.tintColor = DesignSystem.Color.accent
        pencil.setContentHuggingPriority(.required, for: .horizontal)
        pencil.isAccessibilityElement = false

        return paddedRow([column, UIView(), pencil])
    }

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

    @objc private func serverEditingBegan() {
        serverField.textColor = DesignSystem.Color.label
    }

    @objc private func serverReturnTapped() {
        serverField.resignFirstResponder()
    }

    /// Commits the server URL once editing finishes — never per keystroke, so
    /// background traffic can't be redirected at a half-typed host (or the
    /// useless localhost fallback after the clear button). An invalid or empty
    /// value reverts to the previous address with a visible explanation.
    @objc private func serverEditingEnded() {
        serverField.textColor = DesignSystem.Color.secondaryLabel
        let candidate = (serverField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate != AppSettings.serverURLString else { return }
        guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else {
            serverField.text = AppSettings.serverURLString
            statusLabel.textColor = .systemRed
            statusLabel.text = "Not a valid server URL — kept \(AppSettings.serverURLString)"
            Haptics.error()
            return
        }
        AppSettings.serverURLString = candidate
        statusLabel.textColor = DesignSystem.Color.secondaryLabel
        statusLabel.text = "Server set to \(candidate)"
        AppLogger.shared.info("server URL changed to \(candidate)", category: .app)
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

    @objc private func officialComposeChanged() {
        AppSettings.composeViaOfficialApp = officialComposeSwitch.isOn
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
