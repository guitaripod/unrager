import UIKit
import UnragerKit

/// The coloured rounded square with a white glyph that marks a row in iOS's own
/// Settings, drawn once per symbol and colour.
enum IconTile {
    private nonisolated(unsafe) static var cache: [String: UIImage] = [:]

    @MainActor
    static func image(symbol: String, color: UIColor) -> UIImage {
        let key = "\(symbol)-\(color.hash)"
        if let cached = cache[key] { return cached }
        let size = CGSize(width: 30, height: 30)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            let tile = UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 7)
            color.setFill()
            tile.fill()
            let configuration = UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            guard let glyph = UIImage(systemName: symbol, withConfiguration: configuration)?
                .withTintColor(.white, renderingMode: .alwaysOriginal) else { return }
            glyph.draw(in: CGRect(
                x: (size.width - glyph.size.width) / 2, y: (size.height - glyph.size.height) / 2,
                width: glyph.size.width, height: glyph.size.height))
        }
        cache[key] = image
        return image
    }
}

/// Plain facts Settings shows, formatted in one place.
enum SettingsFormat {
    /// `host:port` of a server address, without the scheme.
    static func host(of address: String) -> String {
        guard let url = URL(string: address), let host = url.host else { return address }
        return url.port.map { "\(host):\($0)" } ?? host
    }

    /// The server a typed address means: `http://` is assumed when no scheme is
    /// given (`100.64.0.1:7777`), and anything that isn't an http or https
    /// address with a host is nil.
    static func serverAddress(_ text: String) -> URL? {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, !typed.contains(where: \.isWhitespace) else { return nil }
        let full = typed.contains("://") ? typed : "http://" + typed
        guard let url = URL(string: full), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    static func bytes(_ count: Int) -> String {
        count <= 0 ? "Empty" : ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    /// "Home, Search, Notifications": the tab bar in order, without Settings.
    static func tabSummary(_ tabs: [TabItem]) -> String {
        tabs.filter { $0 != .settings }.map(\.title).joined(separator: ", ")
    }
}

/// A trailing pop-up button for a row: the current value and a menu of the
/// others, so a choice among a few reads as one tap rather than a new screen.
@MainActor
func settingsMenuButton<Option: Equatable>(
    current: Option, options: [Option], title: @escaping (Option) -> String, select: @escaping (Option) -> Void
) -> UIButton {
    var configuration = UIButton.Configuration.plain()
    configuration.title = title(current)
    configuration.image = DesignSystem.icon("chevron.up.chevron.down", pointSize: 11, weight: .semibold)
    configuration.imagePlacement = .trailing
    configuration.imagePadding = 6
    configuration.baseForegroundColor = DesignSystem.Color.secondaryLabel
    configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 0)
    let button = UIButton(configuration: configuration)
    button.showsMenuAsPrimaryAction = true
    button.menu = UIMenu(children: options.map { option in
        UIAction(title: title(option), state: option == current ? .on : .off) { _ in
            Haptics.selection()
            select(option)
        }
    })
    button.sizeToFit()
    return button
}

// MARK: - Hero

/// The top card of Settings: who is signed in and how the server is doing.
struct SettingsHeroConfiguration: UIContentConfiguration {
    let account: Whoami?
    let connection: SettingsViewController.Connection

    @MainActor
    func makeContentView() -> UIView & UIContentView { SettingsHeroView(configuration: self) }

    func updated(for state: UIConfigurationState) -> SettingsHeroConfiguration { self }
}

@MainActor
final class SettingsHeroView: UIView, UIContentView {
    private let avatar = UILabel()
    private let nameLabel = UILabel()
    private let handleLabel = UILabel()
    private let statusDot = UIView()
    private let statusLabel = UILabel()

    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    init(configuration: SettingsHeroConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        avatar.font = DesignSystem.Typography.system(26, weight: .semibold)
        avatar.textColor = .white
        avatar.textAlignment = .center
        avatar.layer.cornerRadius = 30
        avatar.layer.masksToBounds = true
        nameLabel.font = DesignSystem.Typography.system(20, weight: .semibold)
        nameLabel.textColor = DesignSystem.Color.label
        handleLabel.font = DesignSystem.Typography.handle()
        handleLabel.textColor = DesignSystem.Color.secondaryLabel
        statusLabel.font = DesignSystem.Typography.metric()
        statusLabel.textColor = DesignSystem.Color.secondaryLabel
        statusDot.layer.cornerRadius = 4
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusDot.widthAnchor.constraint(equalToConstant: 8),
            statusDot.heightAnchor.constraint(equalToConstant: 8),
        ])

        let status = UIStackView(arrangedSubviews: [statusDot, statusLabel])
        status.spacing = 6
        status.alignment = .center
        let text = UIStackView(arrangedSubviews: [nameLabel, handleLabel, status])
        text.axis = .vertical
        text.spacing = 2
        text.setCustomSpacing(6, after: handleLabel)
        let row = UIStackView(arrangedSubviews: [avatar, text])
        row.spacing = DesignSystem.Spacing.l
        row.alignment = .center
        avatar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: 60),
            avatar.heightAnchor.constraint(equalToConstant: 60),
        ])
        addManaged(row)
        row.pinEdges(to: self, insets: UIEdgeInsets(top: 14, left: 20, bottom: 14, right: 20))
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func apply() {
        guard let configuration = configuration as? SettingsHeroConfiguration else { return }
        if let account = configuration.account {
            avatar.text = String(account.name.first(where: { $0.isLetter || $0.isNumber }) ?? "@").uppercased()
            avatar.backgroundColor = DesignSystem.handleColor(account.handle)
            nameLabel.text = account.name
            handleLabel.text = "@\(account.handle)"
        } else {
            avatar.text = "?"
            avatar.backgroundColor = DesignSystem.Color.tertiaryLabel
            nameLabel.text = "Not signed in"
            handleLabel.text = "Connect to a server to see your account"
        }
        switch configuration.connection {
        case .checking:
            statusDot.backgroundColor = DesignSystem.Color.tertiaryLabel
            statusLabel.text = "Checking the server…"
        case let .online(_, signedInAs):
            statusDot.backgroundColor = DesignSystem.Color.retweet
            statusLabel.text = signedInAs == nil ? "Server connected, X not signed in" : "Server connected"
        case .offline:
            statusDot.backgroundColor = .systemRed
            statusLabel.text = "Server unreachable"
        }
    }
}

// MARK: - Text size

/// The text-size row: a slider across the app's five steps with a line of text
/// that is drawn at the size being chosen.
struct SettingsTextSizeConfiguration: UIContentConfiguration {
    let scale: FontScale
    let onChange: (FontScale) -> Void

    @MainActor
    func makeContentView() -> UIView & UIContentView { SettingsTextSizeView(configuration: self) }

    func updated(for state: UIConfigurationState) -> SettingsTextSizeConfiguration { self }
}

@MainActor
final class SettingsTextSizeView: UIView, UIContentView {
    private let title = UILabel()
    private let valueLabel = UILabel()
    private let slider = UISlider()
    private let preview = UILabel()
    private var shown: FontScale

    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    init(configuration: SettingsTextSizeConfiguration) {
        self.configuration = configuration
        shown = configuration.scale
        super.init(frame: .zero)
        title.text = "Text size"
        valueLabel.textColor = DesignSystem.Color.secondaryLabel
        slider.minimumValue = 0
        slider.maximumValue = Float(FontScale.allCases.count - 1)
        slider.minimumValueImage = DesignSystem.icon("textformat.size.smaller", pointSize: 14)
        slider.maximumValueImage = DesignSystem.icon("textformat.size.larger", pointSize: 18)
        slider.minimumTrackTintColor = DesignSystem.Color.accent
        slider.accessibilityLabel = "Text size"
        slider.addAction(UIAction { [weak self] _ in self?.sliderMoved() }, for: .valueChanged)
        slider.addAction(UIAction { [weak self] _ in self?.settle() }, for: [.touchUpInside, .touchUpOutside])
        preview.text = "Posts will read like this."
        preview.numberOfLines = 0
        preview.textColor = DesignSystem.Color.label

        let header = UIStackView(arrangedSubviews: [title, UIView(), valueLabel])
        let column = UIStackView(arrangedSubviews: [header, slider, preview])
        column.axis = .vertical
        column.spacing = 10
        addManaged(column)
        column.pinEdges(to: self, insets: UIEdgeInsets(top: 12, left: 20, bottom: 12, right: 20))
        NotificationCenter.default.addObserver(
            self, selector: #selector(fontsChanged), name: AppSettings.fontScaleDidChange, object: nil)
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func apply() {
        guard let configuration = configuration as? SettingsTextSizeConfiguration else { return }
        if !slider.isTracking {
            shown = configuration.scale
            slider.value = Float(configuration.scale.rawValue)
        }
        refreshFonts()
    }

    @objc private func fontsChanged() { refreshFonts() }

    private func refreshFonts() {
        title.font = DesignSystem.Typography.body()
        valueLabel.font = DesignSystem.Typography.body()
        valueLabel.text = shown.title
        preview.font = DesignSystem.Typography.body()
    }

    private func sliderMoved() {
        let step = FontScale(rawValue: Int(slider.value.rounded())) ?? .standard
        guard step != shown else { return }
        shown = step
        Haptics.selection()
        (configuration as? SettingsTextSizeConfiguration)?.onChange(step)
    }

    private func settle() {
        slider.setValue(Float(shown.rawValue), animated: true)
    }
}
