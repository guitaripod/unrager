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
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = DesignSystem.Typography.metric()
        label.textColor = DesignSystem.Color.tertiaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0

        var config = UIButton.Configuration.plain()
        config.title = "Retry"
        config.image = DesignSystem.icon("arrow.clockwise", pointSize: 13)
        config.imagePadding = DesignSystem.Spacing.xs
        config.baseForegroundColor = DesignSystem.Color.accent
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var out = incoming
            out.font = DesignSystem.Typography.metric()
            return out
        }
        button.configuration = config
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.isHidden = true
        button.addAction(UIAction { [weak self] _ in self?.onRetry?() }, for: .touchUpInside)

        spinner.hidesWhenStopped = true
        spinner.color = DesignSystem.Color.tertiaryLabel

        stack.axis = .horizontal
        stack.spacing = DesignSystem.Spacing.xs
        stack.alignment = .center
        stack.addArrangedSubview(spinner)
        stack.addArrangedSubview(label)
        stack.addArrangedSubview(button)
        addManaged(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: DesignSystem.Spacing.l),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -DesignSystem.Spacing.l),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
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
        spinner.stopAnimating()
        label.text = text
        label.textColor = showsRetry ? DesignSystem.Color.secondaryLabel : DesignSystem.Color.tertiaryLabel
        button.isHidden = !showsRetry
    }

    /// A spinner + "Loading more…" while the next page is in flight, so reaching
    /// the bottom of the feed clearly shows fresh tweets are on the way.
    func showLoading(_ text: String = "Loading more…") {
        isHidden = false
        button.isHidden = true
        spinner.startAnimating()
        label.text = text
        label.textColor = DesignSystem.Color.tertiaryLabel
    }

    func setHidden() {
        isHidden = true
        spinner.stopAnimating()
        label.text = nil
    }
}
