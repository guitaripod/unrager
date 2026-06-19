import AppKit
import UnragerKit

/// The profile header row: avatar, name, handle, follower/following counts, and
/// a "Brief" button that triggers the brief token stream.
final class ProfileHeaderView: NSView {
    var onBrief: (() -> Void)?

    private let avatar = AsyncImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let handleLabel = NSTextField(labelWithString: "")
    private let countsLabel = NSTextField(labelWithString: "")
    private let briefButton = NSButton(title: "Brief", target: nil, action: nil)
    private let separator = NSBox()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    private func build() {
        wantsLayer = true
        avatar.setRounded(32)
        avatar.setFill()

        nameLabel.font = DesignSystem.Typography.title()
        nameLabel.textColor = DesignSystem.Color.label
        handleLabel.font = DesignSystem.Typography.handle()
        handleLabel.textColor = DesignSystem.Color.secondaryLabel
        countsLabel.font = DesignSystem.Typography.metric()
        countsLabel.textColor = DesignSystem.Color.secondaryLabel

        briefButton.bezelStyle = .rounded
        briefButton.image = DesignSystem.icon("sparkles", pointSize: 13)
        briefButton.imagePosition = .imageLeading
        briefButton.contentTintColor = DesignSystem.Color.accent
        briefButton.target = self
        briefButton.action = #selector(briefTapped)

        let textColumn = NSStackView(views: [nameLabel, handleLabel, countsLabel])
        textColumn.orientation = .vertical
        textColumn.alignment = .leading
        textColumn.spacing = DesignSystem.Spacing.xxs

        let topRow = NSStackView(views: [avatar, textColumn])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = DesignSystem.Spacing.m

        let column = NSStackView(views: [topRow, briefButton])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = DesignSystem.Spacing.m

        separator.boxType = .separator

        addManaged(column)
        addManaged(separator)
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: 64),
            avatar.heightAnchor.constraint(equalToConstant: 64),
            column.topAnchor.constraint(equalTo: topAnchor, constant: DesignSystem.Spacing.l),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DesignSystem.Spacing.l),
            column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -DesignSystem.Spacing.l),
            column.bottomAnchor.constraint(equalTo: separator.topAnchor, constant: -DesignSystem.Spacing.m),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    func configure(with user: User, imagesEnabled: Bool) {
        nameLabel.stringValue = user.name
        handleLabel.stringValue = "@\(user.handle)"
        countsLabel.stringValue = "\(Format.count(user.following)) Following · \(Format.count(user.followers)) Followers"
        if user.verified {
            nameLabel.stringValue = "\(user.name)  ✓"
        }
        if imagesEnabled, let url = user.avatarURL.flatMap(URL.init) {
            avatar.load(url: url, targetSize: CGSize(width: 64, height: 64))
        } else {
            avatar.image = DesignSystem.icon("person.crop.circle.fill", pointSize: 52)
            avatar.contentTintColor = DesignSystem.Color.tertiaryLabel
        }
    }

    @objc private func briefTapped() { onBrief?() }
}
