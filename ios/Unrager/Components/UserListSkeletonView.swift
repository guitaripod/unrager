import UIKit

/// What a list of people looks like before its first page lands: avatars with
/// a name, a handle and a line of bio, in the real rows' proportions.
final class UserListSkeletonView: SkeletonView {
    private static let rowCount = 10

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityLabel = "Loading people"
        let rows = UIStackView()
        rows.axis = .vertical
        rows.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(rows)
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: content.topAnchor),
            rows.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            rows.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        let widths: [(name: CGFloat, bio: CGFloat?)] = [
            (0.34, 0.7), (0.42, nil), (0.28, 0.58), (0.38, 0.74), (0.3, nil), (0.46, 0.62),
        ]
        for index in 0..<Self.rowCount {
            let variant = widths[index % widths.count]
            rows.addArrangedSubview(makeRow(nameShare: variant.name, bioShare: variant.bio))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func makeRow(nameShare: CGFloat, bioShare: CGFloat?) -> UIView {
        let row = UIView()
        let avatar = shape(radius: UserRowCell.avatarSize / 2)
        let name = shape(radius: 5)
        let handle = shape(radius: 5)
        let bio = shape(radius: 5)
        let button = shape(radius: 15)
        for view in [avatar, name, handle, bio, button] { row.addSubview(view) }
        bio.isHidden = bioShare == nil
        let bottomAnchorView = bioShare == nil ? handle : bio
        NSLayoutConstraint.activate([
            avatar.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: DesignSystem.Spacing.l),
            avatar.topAnchor.constraint(equalTo: row.topAnchor, constant: DesignSystem.Spacing.m),
            avatar.widthAnchor.constraint(equalToConstant: UserRowCell.avatarSize),
            avatar.heightAnchor.constraint(equalToConstant: UserRowCell.avatarSize),
            name.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: DesignSystem.Spacing.m),
            name.topAnchor.constraint(equalTo: row.topAnchor, constant: DesignSystem.Spacing.m + 3),
            name.heightAnchor.constraint(equalToConstant: 14),
            name.widthAnchor.constraint(equalTo: row.widthAnchor, multiplier: nameShare),
            handle.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            handle.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 7),
            handle.heightAnchor.constraint(equalToConstant: 11),
            handle.widthAnchor.constraint(equalTo: row.widthAnchor, multiplier: 0.24),
            bio.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            bio.topAnchor.constraint(equalTo: handle.bottomAnchor, constant: 8),
            bio.heightAnchor.constraint(equalToConstant: 11),
            bio.widthAnchor.constraint(equalTo: row.widthAnchor, multiplier: bioShare ?? 0.5),
            button.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -DesignSystem.Spacing.l),
            button.topAnchor.constraint(equalTo: row.topAnchor, constant: DesignSystem.Spacing.m),
            button.widthAnchor.constraint(equalToConstant: 84),
            button.heightAnchor.constraint(equalToConstant: 30),
            row.bottomAnchor.constraint(greaterThanOrEqualTo: avatar.bottomAnchor, constant: DesignSystem.Spacing.m),
            row.bottomAnchor.constraint(equalTo: bottomAnchorView.bottomAnchor, constant: DesignSystem.Spacing.m + 2),
        ])
        return row
    }
}
