import AppKit

/// A centered icon + title + subtitle + optional retry button, used for empty
/// feeds, awaiting-query states, and load errors.
final class EmptyStateView: NSView {
    var onRetry: (() -> Void)?

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    private func build() {
        iconView.contentTintColor = DesignSystem.Color.tertiaryLabel
        titleLabel.font = DesignSystem.Typography.name()
        titleLabel.textColor = DesignSystem.Color.label
        titleLabel.alignment = .center
        subtitleLabel.font = DesignSystem.Typography.metric()
        subtitleLabel.textColor = DesignSystem.Color.secondaryLabel
        subtitleLabel.alignment = .center
        subtitleLabel.maximumNumberOfLines = 3

        retryButton.bezelStyle = .rounded
        retryButton.target = self
        retryButton.action = #selector(retryTapped)

        let stack = NSStackView(views: [iconView, titleLabel, subtitleLabel, retryButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = DesignSystem.Spacing.s
        addManaged(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
            iconView.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    func show(symbol: String, title: String, subtitle: String? = nil, showRetry: Bool = false) {
        isHidden = false
        iconView.image = DesignSystem.icon(symbol, pointSize: 36)
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle ?? ""
        subtitleLabel.isHidden = (subtitle ?? "").isEmpty
        retryButton.isHidden = !showRetry
    }

    @objc private func retryTapped() { onRetry?() }
}
