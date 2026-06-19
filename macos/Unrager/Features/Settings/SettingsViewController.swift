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
    private let imagesSwitch = NSSwitch()
    private let filterSwitch = NSSwitch()
    private let seenSwitch = NSSwitch()

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
                    footnote: "The unrager server (`unrager serve`). Use your Mac's LAN / Tailscale address."),
            section("Appearance", rows: [contentRow(appearanceControl)]),
            section("Media",
                    rows: [toggleRow("Load images", control: imagesSwitch),
                           toggleRow("Dim seen tweets", control: seenSwitch)],
                    footnote: "Tweets you've scrolled past are marked read and shown dimmed."),
            section("Rage filter",
                    rows: [toggleRow("Hide rage tweets", control: filterSwitch),
                           buttonRow("Filter rubric", rubricButton)],
                    footnote: "Runs each tweet through your local Ollama classifier; matches are removed from the feed. Refresh after toggling."),
        ])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = DesignSystem.Spacing.xl

        let documentView = NSView()
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
            documentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),

            column.topAnchor.constraint(equalTo: documentView.topAnchor),
            column.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: DesignSystem.Spacing.xl),
            column.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -DesignSystem.Spacing.xl),
            column.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            appearanceControl.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
        ])
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
