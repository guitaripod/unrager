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

    private func build() {
        let header = sectionTitle("Server")
        serverField.stringValue = AppSettings.serverURLString
        serverField.placeholderString = "http://192.168.1.10:7777"
        serverField.font = DesignSystem.Typography.body()
        serverField.target = self
        serverField.action = #selector(serverChanged)
        serverField.bezelStyle = .roundedBezel

        let testButton = NSButton(title: "Test Connection", target: self, action: #selector(testConnection))
        testButton.bezelStyle = .rounded

        statusLabel.font = DesignSystem.Typography.metric()
        statusLabel.textColor = DesignSystem.Color.secondaryLabel
        statusLabel.stringValue = "Not tested"

        let appearanceTitle = sectionTitle("Appearance")
        appearanceControl.segmentCount = AppearanceMode.allCases.count
        for mode in AppearanceMode.allCases {
            appearanceControl.setLabel(mode.title, forSegment: mode.rawValue)
        }
        appearanceControl.selectedSegment = AppSettings.appearance.rawValue
        appearanceControl.target = self
        appearanceControl.action = #selector(appearanceChanged)
        appearanceControl.segmentStyle = .rounded

        let imagesTitle = sectionTitle("Media")
        imagesSwitch.state = AppSettings.imagesEnabled ? .on : .off
        imagesSwitch.target = self
        imagesSwitch.action = #selector(imagesChanged)
        let imagesRow = toggleRow("Load images", control: imagesSwitch)

        let filterTitle = sectionTitle("Rage filter")
        filterSwitch.state = AppSettings.filterEnabled ? .on : .off
        filterSwitch.target = self
        filterSwitch.action = #selector(filterChanged)
        let filterRow = toggleRow("Hide rage tweets", control: filterSwitch)
        let filterCaption = caption("Runs each tweet through your local Ollama classifier; matches are removed from the feed. Refresh after toggling.")
        let rubricButton = NSButton(title: "Edit filter rubric…", target: self, action: #selector(editRubric))
        rubricButton.bezelStyle = .rounded

        seenSwitch.state = MacSettings.seenDimming ? .on : .off
        seenSwitch.target = self
        seenSwitch.action = #selector(seenChanged)
        let seenRow = toggleRow("Dim seen tweets", control: seenSwitch)
        let seenCaption = caption("Tweets you've scrolled past are marked read and shown dimmed.")

        let serverRow = NSStackView(views: [serverField, testButton])
        serverRow.orientation = .horizontal
        serverRow.spacing = DesignSystem.Spacing.s
        serverField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let column = NSStackView(views: [
            header, serverRow, statusLabel,
            spacer(),
            appearanceTitle, appearanceControl,
            spacer(),
            imagesTitle, imagesRow, seenRow, seenCaption,
            spacer(),
            filterTitle, filterRow, filterCaption, rubricButton,
        ])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = DesignSystem.Spacing.s

        view.addManaged(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: DesignSystem.Spacing.xl),
            column.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: DesignSystem.Spacing.xl),
            column.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -DesignSystem.Spacing.xl),
            serverRow.widthAnchor.constraint(equalTo: column.widthAnchor),
            appearanceControl.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
            imagesRow.widthAnchor.constraint(equalTo: column.widthAnchor),
            seenRow.widthAnchor.constraint(equalTo: column.widthAnchor),
            filterRow.widthAnchor.constraint(equalTo: column.widthAnchor),
            filterCaption.widthAnchor.constraint(equalTo: column.widthAnchor),
            seenCaption.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
    }

    private func toggleRow(_ title: String, control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = DesignSystem.Typography.body()
        label.textColor = DesignSystem.Color.label
        let row = NSStackView(views: [label, NSView(), control])
        row.orientation = .horizontal
        row.alignment = .centerY
        return row
    }

    private func caption(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = DesignSystem.Typography.metric()
        label.textColor = DesignSystem.Color.secondaryLabel
        return label
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = DesignSystem.Typography.caption()
        label.textColor = DesignSystem.Color.secondaryLabel
        return label
    }

    private func spacer() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: DesignSystem.Spacing.m).isActive = true
        return view
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
