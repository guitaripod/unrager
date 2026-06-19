import UIKit

/// The end-of-feed footer. Shows a muted caption — "You're all caught up" when
/// the cursor is exhausted, or a tappable "Scroll to retry" when paging stalled
/// but more may exist — mirroring the TUI's `[end of timeline]` /
/// `[caught up · scroll to retry]` header states. Collapses to zero height when
/// there's nothing to say.
final class FeedFooterView: UICollectionReusableView {
    var onRetry: (() -> Void)?

    private let label = UILabel()
    private let button = UIButton(configuration: .plain())
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = DesignSystem.Typography.metric()
        label.textColor = DesignSystem.Color.tertiaryLabel
        label.textAlignment = .center

        var config = UIButton.Configuration.plain()
        config.image = DesignSystem.icon("arrow.clockwise", pointSize: 13)
        config.baseForegroundColor = DesignSystem.Color.accent
        button.configuration = config
        button.isHidden = true
        button.addAction(UIAction { [weak self] _ in self?.onRetry?() }, for: .touchUpInside)

        stack.axis = .horizontal
        stack.spacing = DesignSystem.Spacing.xs
        stack.alignment = .center
        stack.addArrangedSubview(label)
        stack.addArrangedSubview(button)
        addManaged(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: DesignSystem.Spacing.l),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -DesignSystem.Spacing.l),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        onRetry = nil
    }

    func show(text: String, showsRetry: Bool) {
        isHidden = false
        label.text = text
        button.isHidden = !showsRetry
    }

    func setHidden() {
        isHidden = true
        label.text = nil
    }
}
