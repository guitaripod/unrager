import UIKit
import UnragerKit

/// Server address, appearance, image toggle, and a connection test. The server
/// URL is the one piece of client config the app needs — everything else lives
/// server-side.
final class SettingsViewController: UIViewController {
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let serverField = UITextField()
    private let statusLabel = UILabel()
    private let appearanceControl = UISegmentedControl(items: AppearanceMode.allCases.map(\.title))
    private let imagesSwitch = UISwitch()
    private let filterSwitch = UISwitch()
    private let markSeenSwitch = UISwitch()
    private let profileButton = UIButton(configuration: .gray())

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        view.backgroundColor = DesignSystem.Color.background
        navigationItem.largeTitleDisplayMode = .always
        buildLayout()
    }

    private func buildLayout() {
        stack.axis = .vertical
        stack.spacing = DesignSystem.Spacing.l
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = .init(top: 20, leading: 20, bottom: 20, trailing: 20)

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
        serverField.borderStyle = .roundedRect
        serverField.autocapitalizationType = .none
        serverField.autocorrectionType = .no
        serverField.keyboardType = .URL
        serverField.clearButtonMode = .whileEditing
        serverField.addTarget(self, action: #selector(serverChanged), for: .editingChanged)

        statusLabel.font = DesignSystem.Typography.metric()
        statusLabel.textColor = DesignSystem.Color.secondaryLabel
        statusLabel.numberOfLines = 0

        let testButton = UIButton(configuration: .tinted())
        testButton.setTitle("Test connection", for: .normal)
        testButton.addAction(UIAction { [weak self] _ in self?.testConnection() }, for: .touchUpInside)

        appearanceControl.selectedSegmentIndex = AppSettings.appearance.rawValue
        appearanceControl.addTarget(self, action: #selector(appearanceChanged), for: .valueChanged)

        imagesSwitch.isOn = AppSettings.imagesEnabled
        imagesSwitch.addTarget(self, action: #selector(imagesChanged), for: .valueChanged)
        let imagesRow = labeledRow("Load images", accessory: imagesSwitch)

        markSeenSwitch.isOn = ClientSettings.markSeenEnabled
        markSeenSwitch.addTarget(self, action: #selector(markSeenChanged), for: .valueChanged)
        let markSeenRow = labeledRow("Track seen tweets", accessory: markSeenSwitch)

        profileButton.setTitle("Open my profile →", for: .normal)
        profileButton.contentHorizontalAlignment = .leading
        profileButton.addAction(UIAction { [weak self] _ in self?.openMyProfile() }, for: .touchUpInside)

        stack.addArrangedSubview(section("Server", views: [
            captionLabel("The unrager server (`unrager serve`). Use your Mac's LAN/Tailscale address from a real device."),
            serverField, testButton, statusLabel,
        ]))
        stack.addArrangedSubview(section("Account", views: [profileButton]))

        let editTabsButton = UIButton(configuration: .gray())
        editTabsButton.setTitle("Edit tabs →", for: .normal)
        editTabsButton.contentHorizontalAlignment = .leading
        editTabsButton.addAction(UIAction { [weak self] _ in
            self?.navigationController?.pushViewController(EditTabsViewController(), animated: true)
        }, for: .touchUpInside)
        stack.addArrangedSubview(section("Tabs", views: [
            editTabsButton,
            captionLabel("Choose up to \(TabItem.maxCount) tabs and reorder them."),
        ]))

        stack.addArrangedSubview(section("Appearance", views: [appearanceControl]))
        stack.addArrangedSubview(section("Feed", views: [
            imagesRow,
            markSeenRow,
            captionLabel("Reports tweets you scroll past on Following and Mentions to the server's read tracker and dims them on reload."),
        ]))

        filterSwitch.isOn = AppSettings.filterEnabled
        filterSwitch.addTarget(self, action: #selector(filterChanged), for: .valueChanged)
        let rubricButton = UIButton(configuration: .gray())
        rubricButton.setTitle("Edit filter rubric →", for: .normal)
        rubricButton.contentHorizontalAlignment = .leading
        rubricButton.addAction(UIAction { [weak self] _ in
            self?.navigationController?.pushViewController(FilterSettingsViewController(), animated: true)
        }, for: .touchUpInside)
        stack.addArrangedSubview(section("Rage filter", views: [
            labeledRow("Hide rage tweets", accessory: filterSwitch),
            captionLabel("Runs each tweet through your local Ollama classifier; matches are removed from the feed. Refresh after toggling."),
            rubricButton,
        ]))

        stack.addArrangedSubview(section("About", views: [
            captionLabel("unrager · a calm X client. The server does the X work; this app is a thin native client."),
        ]))
    }

    private func section(_ title: String, views: [UIView]) -> UIView {
        let header = UILabel()
        header.text = title.uppercased()
        header.font = DesignSystem.Typography.caption()
        header.textColor = DesignSystem.Color.secondaryLabel
        let inner = UIStackView(arrangedSubviews: [header] + views)
        inner.axis = .vertical
        inner.spacing = DesignSystem.Spacing.s
        return inner
    }

    private func captionLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = DesignSystem.Typography.metric()
        label.textColor = DesignSystem.Color.secondaryLabel
        label.numberOfLines = 0
        return label
    }

    private func labeledRow(_ title: String, accessory: UIView) -> UIView {
        let label = UILabel()
        label.text = title
        label.font = DesignSystem.Typography.body()
        let row = UIStackView(arrangedSubviews: [label, UIView(), accessory])
        row.axis = .horizontal
        return row
    }

    @objc private func serverChanged() {
        AppSettings.serverURLString = serverField.text ?? ""
    }

    @objc private func appearanceChanged() {
        let mode = AppearanceMode(rawValue: appearanceControl.selectedSegmentIndex) ?? .system
        AppSettings.appearance = mode
        view.window?.overrideUserInterfaceStyle = UIUserInterfaceStyle(rawValue: mode.rawValue) ?? .unspecified
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
