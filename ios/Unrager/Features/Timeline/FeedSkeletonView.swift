import UIKit

/// What a feed looks like before its first page lands: post-shaped rows of grey
/// shapes, some with a picture, under a soft sweep of light. It sits where the
/// posts will be (below a profile's header, say) so the screen already has its
/// shape when they arrive, and stands in for a spinner. Where the feed lays its
/// posts out as a board of cards it waits as cards in the same columns, so the
/// board doesn't arrive as a different shape from the one that held its place.
final class FeedSkeletonView: SkeletonView {
    private static let rowCount = 6
    private static let avatarSide: CGFloat = 44
    private static let variants: [(lines: [CGFloat], picture: Bool)] = [
        ([0.94, 0.88, 0.5], true), ([0.9, 0.62], false), ([0.96, 0.9, 0.84, 0.4], false),
        ([0.86, 0.58], true), ([0.92, 0.7], false), ([0.9, 0.8, 0.46], true),
    ]

    private let board = UIStackView()
    private var shape: Shape?

    /// How the placeholder is laid out: one list, or cards in columns.
    struct Shape: Equatable {
        var columns: Int
        var spacing: CGFloat
        var inset: CGFloat
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityLabel = "Loading posts"
        board.axis = .horizontal
        board.alignment = .top
        board.distribution = .fillEqually
        board.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(board)
        NSLayoutConstraint.activate([
            board.topAnchor.constraint(equalTo: content.topAnchor),
            board.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            board.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            board.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        arrange(Shape(columns: 1, spacing: 0, inset: 0))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Lays the placeholder out as the feed will be: a list, or a board of
    /// `columns` cards across with the board's own gutters.
    func arrange(_ next: Shape) {
        guard next != shape else { return }
        shape = next
        board.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let cards = next.columns > 1
        board.spacing = next.spacing
        board.isLayoutMarginsRelativeArrangement = true
        board.directionalLayoutMargins = cards
            ? NSDirectionalEdgeInsets(top: 8, leading: next.inset, bottom: 0, trailing: next.inset)
            : .zero
        for column in 0..<max(next.columns, 1) {
            let rows = UIStackView()
            rows.axis = .vertical
            rows.spacing = cards ? next.spacing : 0
            for index in 0..<Self.rowCount {
                let variant = Self.variants[(index + column * 3) % Self.variants.count]
                let row = makeRow(lines: variant.lines, picture: variant.picture)
                if cards {
                    row.backgroundColor = DesignSystem.Color.elevatedBackground
                    row.setFixedCorners(18)
                }
                rows.addArrangedSubview(row)
            }
            board.addArrangedSubview(rows)
        }
    }

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
