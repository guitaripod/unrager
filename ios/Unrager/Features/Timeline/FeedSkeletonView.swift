import UIKit

/// What a feed looks like before its first page lands: post-shaped rows of grey
/// shapes, some with a picture, under a soft sweep of light. It sits where the
/// posts will be (below a profile's header, say) so the screen already has its
/// shape when they arrive, and stands in for a spinner.
final class FeedSkeletonView: SkeletonView {
    private static let rowCount = 6
    private static let avatarSide: CGFloat = 44

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityLabel = "Loading posts"
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
        let variants: [(lines: [CGFloat], picture: Bool)] = [
            ([0.94, 0.88, 0.5], true), ([0.9, 0.62], false), ([0.96, 0.9, 0.84, 0.4], false),
            ([0.86, 0.58], true), ([0.92, 0.7], false), ([0.9, 0.8, 0.46], true),
        ]
        for index in 0..<Self.rowCount {
            let variant = variants[index % variants.count]
            rows.addArrangedSubview(makeRow(lines: variant.lines, picture: variant.picture))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func makeRow(lines: [CGFloat], picture: Bool) -> UIView {
        let row = UIView()
        let avatar = shape(radius: Self.avatarSide / 2)
        let name = shape(radius: 5)
        let handle = shape(radius: 5)
        row.addSubview(avatar)
        row.addSubview(name)
        row.addSubview(handle)
        let column = UIStackView()
        column.axis = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(column)
        for fraction in lines {
            let line = shape(radius: 5)
            column.addArrangedSubview(line)
            line.heightAnchor.constraint(equalToConstant: 13).isActive = true
            line.widthAnchor.constraint(equalTo: column.widthAnchor, multiplier: fraction).isActive = true
        }
        let tail: UIView
        if picture {
            let media = shape(radius: DesignSystem.Radius.media)
            row.addSubview(media)
            NSLayoutConstraint.activate([
                media.topAnchor.constraint(equalTo: column.bottomAnchor, constant: 12),
                media.leadingAnchor.constraint(equalTo: column.leadingAnchor),
                media.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
                media.heightAnchor.constraint(equalTo: media.widthAnchor, multiplier: 0.58),
            ])
            tail = media
        } else {
            tail = column
        }
        let actions = shape(radius: 5)
        row.addSubview(actions)
        NSLayoutConstraint.activate([
            avatar.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            avatar.topAnchor.constraint(equalTo: row.topAnchor, constant: 14),
            avatar.widthAnchor.constraint(equalToConstant: Self.avatarSide),
            avatar.heightAnchor.constraint(equalToConstant: Self.avatarSide),
            name.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 12),
            name.topAnchor.constraint(equalTo: row.topAnchor, constant: 16),
            name.heightAnchor.constraint(equalToConstant: 14),
            name.widthAnchor.constraint(equalTo: row.widthAnchor, multiplier: 0.3),
            handle.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 8),
            handle.centerYAnchor.constraint(equalTo: name.centerYAnchor),
            handle.heightAnchor.constraint(equalToConstant: 12),
            handle.widthAnchor.constraint(equalTo: row.widthAnchor, multiplier: 0.16),
            column.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            column.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 12),
            actions.topAnchor.constraint(equalTo: tail.bottomAnchor, constant: 14),
            actions.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            actions.widthAnchor.constraint(equalTo: row.widthAnchor, multiplier: 0.5),
            actions.heightAnchor.constraint(equalToConstant: 12),
            actions.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -16),
        ])
        return row
    }
}
