import UIKit

/// One control of a post's action bar: a symbol and a count. A plain
/// `UIControl` drawing an image view and a label, because a `UIButton` with a
/// configuration re-resolves its whole content on every assignment, and
/// binding a row set five of them: it was the biggest single cost of putting a
/// post on screen.
final class ActionButton: UIControl {
    private static let gap: CGFloat = 6
    private static let verticalPadding: CGFloat = 6

    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private var title = ""

    init(symbol: String) {
        super.init(frame: .zero)
        iconView.image = DesignSystem.icon(symbol, pointSize: 15)
        iconView.tintColor = DesignSystem.Color.secondaryLabel
        iconView.contentMode = .center
        titleLabel.font = DesignSystem.Typography.actionMetric()
        titleLabel.textColor = DesignSystem.Color.secondaryLabel
        titleLabel.lineBreakMode = .byClipping
        addSubview(iconView)
        addSubview(titleLabel)
        isAccessibilityElement = true
        accessibilityTraits = .button
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Sets what changed: the count, the symbol, the colour of both. Anything
    /// left nil or equal is not touched, so rebinding a row to a post that looks
    /// the same does no work.
    func set(title newTitle: String, image: UIImage? = nil, tint: UIColor? = nil) {
        if newTitle != title {
            title = newTitle
            titleLabel.text = newTitle
            titleLabel.isHidden = newTitle.isEmpty
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
        if let image, iconView.image !== image { iconView.image = image }
        if let tint, titleLabel.textColor != tint {
            titleLabel.textColor = tint
            iconView.tintColor = tint
        }
    }

    /// Re-resolves the count's font after a text-size change.
    func refreshFont() {
        titleLabel.font = DesignSystem.Typography.actionMetric()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override var intrinsicContentSize: CGSize {
        let icon = iconView.image?.size ?? .zero
        let label = title.isEmpty ? .zero : titleLabel.intrinsicContentSize
        let width = icon.width + (title.isEmpty ? 0 : Self.gap + label.width)
        return CGSize(width: ceil(width), height: max(icon.height, label.height) + 2 * Self.verticalPadding)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let icon = iconView.image?.size ?? .zero
        iconView.frame = CGRect(x: 0, y: (bounds.height - icon.height) / 2, width: icon.width, height: icon.height)
        let label = titleLabel.intrinsicContentSize
        titleLabel.frame = CGRect(x: icon.width + Self.gap, y: (bounds.height - label.height) / 2,
                                  width: min(label.width, max(0, bounds.width - icon.width - Self.gap)),
                                  height: label.height)
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.55 : 1 }
    }

    /// Builds the menu a tap opens, each time it opens, so its items can
    /// reflect what the row shows at that moment. Setting it makes a tap open
    /// the menu instead of sending actions.
    var menuProvider: (() -> UIMenu)? {
        didSet {
            isContextMenuInteractionEnabled = menuProvider != nil
            showsMenuAsPrimaryAction = menuProvider != nil
        }
    }

    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let menuProvider else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menuProvider() }
    }
}
