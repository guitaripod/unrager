import UIKit

/// What the list looks like before its first page lands: rows of grey shapes in
/// the real rows' proportions, with a soft light passing across them. It stands
/// in for a spinner so the screen already has the right shape when the
/// activity arrives.
final class NotificationSkeletonView: SkeletonView {
    private static let rowCount = 9

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityLabel = "Loading notifications"
        buildRows()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Rows whose shapes vary a little so the block doesn't read as a table.
    private func buildRows() {
        let rows = UIStackView()
        rows.axis = .vertical
        rows.spacing = 0
        rows.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(rows)
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            rows.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        let lines: [(title: CGFloat, card: Bool)] = [
            (0.7, true), (0.5, false), (0.62, true), (0.78, false), (0.55, true),
            (0.66, false), (0.74, true), (0.48, false), (0.6, true),
        ]
        for index in 0..<Self.rowCount {
            rows.addArrangedSubview(makeRow(titleFraction: lines[index % lines.count].title,
                                            withCard: lines[index % lines.count].card))
        }
    }

    private func makeRow(titleFraction: CGFloat, withCard: Bool) -> UIView {
        let row = UIView()
        let face = shape(radius: 23)
        let title = shape(radius: 5)
        let time = shape(radius: 5)
        let card = shape(radius: 12)
        card.isHidden = !withCard
        for view in [face, title, time, card] { row.addSubview(view) }
        NSLayoutConstraint.activate([
            face.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 22),
            face.topAnchor.constraint(equalTo: row.topAnchor, constant: 14),
            face.widthAnchor.constraint(equalToConstant: 46),
            face.heightAnchor.constraint(equalToConstant: 46),
            title.leadingAnchor.constraint(equalTo: face.trailingAnchor, constant: 22),
            title.topAnchor.constraint(equalTo: row.topAnchor, constant: 16),
            title.heightAnchor.constraint(equalToConstant: 14),
            title.widthAnchor.constraint(equalTo: row.widthAnchor, multiplier: titleFraction * 0.6),
            time.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            time.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            time.widthAnchor.constraint(equalToConstant: 26),
            time.heightAnchor.constraint(equalToConstant: 12),
            card.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            card.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            card.heightAnchor.constraint(equalToConstant: 52),
        ])
        let bottom = (withCard ? card.bottomAnchor : face.bottomAnchor).constraint(
            equalTo: row.bottomAnchor, constant: 14)
        bottom.isActive = true
        return row
    }
}
