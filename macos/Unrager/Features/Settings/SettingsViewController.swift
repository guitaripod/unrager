import AppKit
import UnragerKit

/// Server URL, connection test, appearance, and the load-images toggle.
@MainActor
final class SettingsViewController: NSViewController {
    var onAppearanceChange: ((AppearanceMode) -> Void)?
    var onFilterChange: ((Bool) -> Void)?

    private let api = AppEnvironment.shared.api
    private let serverField = NSTextField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let appearanceControl = NSSegmentedControl()
    private let fontScaleControl = NSSegmentedControl()
    private let imagesSwitch = NSSwitch()
    private let filterSwitch = NSSwitch()
    private let seenSwitch = NSSwitch()
    private let notificationsSwitch = NSSwitch()
    private var kindSwitches: [NotificationKind: NSSwitch] = [:]
    private var kindRows: [NSView] = []

    override func loadView() {
        view = BackgroundView(color: DesignSystem.Color.windowBackground)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        build()
    }

    private let scrollView = NSScrollView()

    private func build() {
        serverField.stringValue = AppSettings.serverURLString
        serverField.placeholderString = "http://192.168.1.10:7777"
        serverField.font = DesignSystem.Typography.body()
        serverField.target = self
        serverField.action = #selector(serverChanged)
        serverField.bezelStyle = .roundedBezel

        let testButton = NSButton(title: "Test Connection", target: self, action: #selector(testConnection))
        testButton.bezelStyle = .rounded
        testButton.setContentHuggingPriority(.required, for: .horizontal)

        statusLabel.font = DesignSystem.Typography.metric()
        statusLabel.textColor = DesignSystem.Color.secondaryLabel
        statusLabel.stringValue = "Not tested"

        appearanceControl.segmentCount = AppearanceMode.allCases.count
        for mode in AppearanceMode.allCases {
            appearanceControl.setLabel(mode.title, forSegment: mode.rawValue)
        }
        appearanceControl.selectedSegment = AppSettings.appearance.rawValue
        appearanceControl.target = self
        appearanceControl.action = #selector(appearanceChanged)
        appearanceControl.segmentStyle = .rounded

        fontScaleControl.segmentCount = FontScale.allCases.count
        for scale in FontScale.allCases {
            fontScaleControl.setLabel(scale.title, forSegment: scale.rawValue)
        }
        fontScaleControl.selectedSegment = AppSettings.fontScale.rawValue
        fontScaleControl.target = self
        fontScaleControl.action = #selector(fontScaleChanged)
        fontScaleControl.segmentStyle = .rounded

        imagesSwitch.state = AppSettings.imagesEnabled ? .on : .off
        imagesSwitch.target = self
        imagesSwitch.action = #selector(imagesChanged)

        seenSwitch.state = MacSettings.seenDimming ? .on : .off
        seenSwitch.target = self
        seenSwitch.action = #selector(seenChanged)

        filterSwitch.state = AppSettings.filterEnabled ? .on : .off
        filterSwitch.target = self
        filterSwitch.action = #selector(filterChanged)

        let rubricButton = NSButton(title: "Edit filter rubric…", target: self, action: #selector(editRubric))
        rubricButton.bezelStyle = .rounded

        let serverRow = NSStackView(views: [serverField, testButton])
        serverRow.orientation = .horizontal
        serverRow.spacing = DesignSystem.Spacing.s
        serverRow.distribution = .fill
        serverField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let column = NSStackView(views: [
            section("Server",
                    rows: [paddedRow([serverRow]), contentRow(statusLabel)],
                    footnote: "The unrager server (`unrager serve`) — a Linux box, a Mac, any machine you keep running. Use its LAN or Tailscale address."),
            section("Appearance",
                    rows: [contentRow(appearanceControl), contentRow(fontScaleControl)],
                    footnote: "Text size scales the whole app."),
            section("Media",
                    rows: [toggleRow("Load images", control: imagesSwitch),
                           toggleRow("Dim seen tweets", control: seenSwitch)],
                    footnote: "Tweets you've scrolled past are marked read and shown dimmed."),
            notificationsSection(),
            section("Rage filter",
                    rows: [toggleRow("Hide rage tweets", control: filterSwitch),
                           buttonRow("Filter rubric", rubricButton)],
                    footnote: "Runs each tweet through your local Ollama classifier; matches are removed from the feed. Refresh after toggling."),
        ])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = DesignSystem.Spacing.xl

        let documentView = FlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addManaged(column)
        scrollView.documentView = documentView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: DesignSystem.Spacing.xl, left: 0, bottom: DesignSystem.Spacing.xl, right: 0)
        view.addManaged(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),

            column.topAnchor.constraint(equalTo: documentView.topAnchor),
            column.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: DesignSystem.Spacing.xl),
            column.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -DesignSystem.Spacing.xl),
            column.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            appearanceControl.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
            fontScaleControl.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
        ])
    }

    // MARK: - Notifications

    /// The notifications card: a master banner toggle, per-type toggles (enabled
    /// only while the master is on), and a button that opens the system
    /// notification settings. The Dock/sidebar unread badge is independent of
    /// these toggles. NO PUSH: banners are foreground/best-effort only.
    private func notificationsSection() -> NSStackView {
        notificationsSwitch.state = NotificationPrefs.bannersEnabled ? .on : .off
        notificationsSwitch.target = self
        notificationsSwitch.action = #selector(notificationsChanged)

        var rows: [NSView] = [toggleRow("Notifications", control: notificationsSwitch)]
        kindRows = NotificationKind.allCases.map { kind in
            let control = NSSwitch()
            control.state = NotificationPrefs.bannerEnabled(for: kind) ? .on : .off
            let action = KindToggleAction(kind: kind, control: control)
            kindActions.append(action)
            control.target = action
            control.action = #selector(KindToggleAction.toggled)
            kindSwitches[kind] = control
            return toggleRow(kind.title, control: control)
        }
        rows.append(contentsOf: kindRows)
        let openButton = NSButton(title: "Open…", target: self, action: #selector(openSystemNotificationSettings))
        openButton.bezelStyle = .rounded
        rows.append(buttonRow("System notification settings", openButton))

        updateKindRowsEnabled()
        return section("Notifications", rows: rows,
                       footnote: "Banners are delivered by an in-app poller while Unrager is running; there is no push server, so they won't arrive when the app is quit. The Dock and sidebar unread badge always count new activity regardless of these toggles.")
    }

    private var kindActions: [KindToggleAction] = []

    /// A target/action box for a per-kind switch — AppKit's `action` needs a
    /// retained object target, so each toggle keeps one alive for the VC's life.
    final class KindToggleAction: NSObject {
        let kind: NotificationKind
        weak var control: NSSwitch?
        init(kind: NotificationKind, control: NSSwitch) {
            self.kind = kind
            self.control = control
        }
        @objc func toggled() {
            NotificationPrefs.setBannerEnabled(control?.state == .on, for: kind)
        }
    }

    private func updateKindRowsEnabled() {
        let enabled = notificationsSwitch.state == .on
        for control in kindSwitches.values { control.isEnabled = enabled }
        for row in kindRows { row.alphaValue = enabled ? 1 : 0.4 }
    }

    @objc private func notificationsChanged() {
        if notificationsSwitch.state == .on {
            Task { [weak self] in
                let granted = await NotificationCenterService.shared.requestAuthorization()
                guard let self else { return }
                if granted {
                    NotificationPrefs.bannersEnabled = true
                } else {
                    self.notificationsSwitch.state = .off
                    NotificationPrefs.bannersEnabled = false
                    self.openSystemNotificationSettings()
                }
                self.updateKindRowsEnabled()
            }
        } else {
            NotificationPrefs.bannersEnabled = false
            updateKindRowsEnabled()
        }
    }

    @objc private func openSystemNotificationSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications")
            ?? URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        if let url { NSWorkspace.shared.open(url) }
    }

    // MARK: - Grouped sections

    /// A section: an uppercased header, a rounded elevated card stacking
    /// hairline-separated rows, and an optional footnote. The AppKit read of the
    /// iOS grouped-settings card.
    private func section(_ title: String, rows: [NSView], footnote: String? = nil) -> NSStackView {
        let header = NSTextField(labelWithString: title.uppercased())
        header.font = DesignSystem.Typography.caption()
        header.textColor = DesignSystem.Color.secondaryLabel

        let column = NSStackView(views: [header, card(rows)])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = DesignSystem.Spacing.xs
        if let footnote {
            column.addArrangedSubview(caption(footnote))
        }
        for child in column.arrangedSubviews {
            child.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        return column
    }

    /// A rounded, elevated container stacking rows with hairline separators inset
    /// to the row content — the native grouped-settings card.
    private func card(_ rows: [NSView]) -> NSView {
        let inner = NSStackView()
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 0
        for (index, row) in rows.enumerated() {
            if index > 0 { inner.addArrangedSubview(separatorRow()) }
            inner.addArrangedSubview(row)
        }
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.cornerCurve = .continuous
        container.applyLayerBackground(DesignSystem.Color.surface)
        container.addManaged(inner)
        inner.pinEdges(to: container)
        for row in inner.arrangedSubviews {
            row.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true
        }
        return container
    }

    private func separatorRow() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        let wrap = NSView()
        wrap.addManaged(line)
        NSLayoutConstraint.activate([
            line.heightAnchor.constraint(equalToConstant: 1),
            line.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: DesignSystem.Spacing.l),
            line.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
            line.topAnchor.constraint(equalTo: wrap.topAnchor),
            line.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
        ])
        return wrap
    }

    private func toggleRow(_ title: String, control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = DesignSystem.Typography.body()
        label.textColor = DesignSystem.Color.label
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        control.setContentHuggingPriority(.required, for: .horizontal)
        return paddedRow([label, NSView(), control])
    }

    private func buttonRow(_ title: String, _ button: NSButton) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = DesignSystem.Typography.body()
        label.textColor = DesignSystem.Color.label
        button.setContentHuggingPriority(.required, for: .horizontal)
        return paddedRow([label, NSView(), button])
    }

    private func contentRow(_ view: NSView) -> NSView { paddedRow([view]) }

    /// One inset row inside a grouped card: leading/trailing/vertical padding so
    /// content lines up with the section's other rows.
    private func paddedRow(_ subviews: [NSView]) -> NSView {
        let row = NSStackView(views: subviews)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = DesignSystem.Spacing.s
        row.edgeInsets = NSEdgeInsets(top: DesignSystem.Spacing.m, left: DesignSystem.Spacing.l,
                                      bottom: DesignSystem.Spacing.m, right: DesignSystem.Spacing.l)
        return row
    }

    private func caption(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = DesignSystem.Typography.metric()
        label.textColor = DesignSystem.Color.secondaryLabel
        return label
    }

    @objc private func serverChanged() {
        AppSettings.serverURLString = serverField.stringValue
    }

    @objc private func testConnection() {
        AppSettings.serverURLString = serverField.stringValue
        statusLabel.textColor = DesignSystem.Color.secondaryLabel
        statusLabel.stringValue = "Connecting…"
        Task {
            do {
                let me = try await api.whoami()
                statusLabel.textColor = DesignSystem.Color.retweet
                statusLabel.stringValue = "Connected · signed in as @\(me.handle)"
            } catch {
                statusLabel.textColor = .systemRed
                statusLabel.stringValue = error.localizedDescription
            }
        }
    }

    @objc private func appearanceChanged() {
        let mode = AppearanceMode(rawValue: appearanceControl.selectedSegment) ?? .system
        AppSettings.appearance = mode
        onAppearanceChange?(mode)
    }

    @objc private func fontScaleChanged() {
        AppSettings.fontScale = FontScale(rawValue: fontScaleControl.selectedSegment) ?? .standard
        NotificationCenter.default.post(name: AppSettings.fontScaleDidChange, object: nil)
    }

    @objc private func imagesChanged() {
        AppSettings.imagesEnabled = imagesSwitch.state == .on
    }

    @objc private func filterChanged() {
        AppSettings.filterEnabled = filterSwitch.state == .on
        onFilterChange?(AppSettings.filterEnabled)
    }

    @objc private func seenChanged() {
        MacSettings.seenDimming = seenSwitch.state == .on
    }

    @objc private func editRubric() {
        presentAsSheet(FilterSettingsViewController())
    }
}

/// A top-origin document view for the settings scroll view, so the stacked
/// cards lay out from the top and scroll naturally rather than bottom-up.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
