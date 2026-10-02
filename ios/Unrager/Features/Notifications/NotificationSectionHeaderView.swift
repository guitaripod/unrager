import UIKit

/// A day heading in the list. The New section carries a one-line digest of what
/// the unread activity added up to and a button that clears it.
final class NotificationSectionHeaderView: UICollectionReusableView {
    var onAction: (() -> Void)?

    private let titleLabel = UILabel()
    private let digestLabel = UILabel()
    private let actionButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.font = DesignSystem.Typography.system(20, weight: .bold)
        titleLabel.textColor = DesignSystem.Color.label
        titleLabel.accessibilityTraits = .header
        digestLabel.font = DesignSystem.Typography.metric()
        digestLabel.textColor = DesignSystem.Color.secondaryLabel
        digestLabel.numberOfLines = 0

        let texts = UIStackView(arrangedSubviews: [titleLabel, digestLabel])
        texts.axis = .vertical
        texts.spacing = 2

        var config = UIButton.Configuration.plain()
        config.baseForegroundColor = DesignSystem.Color.accent
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 0)
        config.title = "Mark all read"
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = DesignSystem.Typography.system(14, weight: .semibold)
            return outgoing
        }
        actionButton.configuration = config
        actionButton.setContentHuggingPriority(.required, for: .horizontal)
        actionButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        actionButton.addAction(UIAction { [weak self] _ in self?.onAction?() }, for: .touchUpInside)

        let row = UIStackView(arrangedSubviews: [texts, actionButton])
        row.alignment = .center
        row.spacing = DesignSystem.Spacing.s
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, digest: String?, offersMarkRead: Bool) {
        titleLabel.text = title
        digestLabel.text = digest
        digestLabel.isHidden = digest == nil
        actionButton.isHidden = !offersMarkRead
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onAction = nil
    }
}
