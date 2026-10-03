import UIKit

/// The first row of a list of people that is about something: a round symbol, a
/// headline figure and a line saying what it counts. It scrolls away with the
/// list.
struct UserListHeader: Hashable {
    let symbol: String
    let tint: UIColor
    let title: String
    let subtitle: String?
}

final class UserListHeaderCell: UICollectionViewListCell {
    private let disc = UIView()
    private let badge = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        disc.layer.cornerRadius = 26
        disc.layer.cornerCurve = .continuous
        disc.translatesAutoresizingMaskIntoConstraints = false
        badge.contentMode = .center
        badge.translatesAutoresizingMaskIntoConstraints = false
        disc.addSubview(badge)

        titleLabel.font = DesignSystem.Typography.system(22, weight: .bold)
        titleLabel.textColor = DesignSystem.Color.label
        titleLabel.accessibilityTraits = .header
        subtitleLabel.font = DesignSystem.Typography.metric()
        subtitleLabel.textColor = DesignSystem.Color.secondaryLabel
        subtitleLabel.numberOfLines = 2
        let texts = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        texts.axis = .vertical
        texts.spacing = 2
        texts.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(disc)
        contentView.addSubview(texts)
        let bottom = texts.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -DesignSystem.Spacing.l)
        bottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            disc.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: DesignSystem.Spacing.l),
            disc.topAnchor.constraint(equalTo: contentView.topAnchor, constant: DesignSystem.Spacing.l),
            disc.widthAnchor.constraint(equalToConstant: 52),
            disc.heightAnchor.constraint(equalToConstant: 52),
            disc.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -DesignSystem.Spacing.l),
            badge.centerXAnchor.constraint(equalTo: disc.centerXAnchor),
            badge.centerYAnchor.constraint(equalTo: disc.centerYAnchor),
            texts.leadingAnchor.constraint(equalTo: disc.trailingAnchor, constant: DesignSystem.Spacing.m),
            texts.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -DesignSystem.Spacing.l),
            texts.topAnchor.constraint(equalTo: contentView.topAnchor, constant: DesignSystem.Spacing.l + 2),
            bottom,
        ])
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(with header: UserListHeader) {
        badge.image = DesignSystem.icon(header.symbol, pointSize: 24, weight: .semibold)
        badge.tintColor = header.tint
        disc.backgroundColor = header.tint.withAlphaComponent(0.14)
        titleLabel.text = header.title
        subtitleLabel.text = header.subtitle
        subtitleLabel.isHidden = header.subtitle == nil
        isAccessibilityElement = true
        accessibilityLabel = [header.title, header.subtitle].compactMap { $0 }.joined(separator: ". ")
    }
}
