import UIKit

final class EmptyStateView: UIView {
    private let imageView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let retryButton = UIButton(configuration: .tinted())

    var onRetry: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.tintColor = DesignSystem.Color.tertiaryLabel
        imageView.contentMode = .scaleAspectFit

        titleLabel.font = DesignSystem.Typography.name()
        titleLabel.textColor = DesignSystem.Color.label
        titleLabel.textAlignment = .center

        subtitleLabel.font = DesignSystem.Typography.metric()
        subtitleLabel.textColor = DesignSystem.Color.secondaryLabel
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 0

        retryButton.setTitle("Retry", for: .normal)
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [imageView, titleLabel, subtitleLabel, retryButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = DesignSystem.Spacing.m
        addManaged(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -32),
            imageView.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(symbol: String, title: String, subtitle: String, showRetry: Bool) {
        imageView.image = DesignSystem.icon(symbol, pointSize: 40)
        titleLabel.text = title
        subtitleLabel.text = subtitle
        retryButton.isHidden = !showRetry
    }

    @objc private func retryTapped() { onRetry?() }
}
