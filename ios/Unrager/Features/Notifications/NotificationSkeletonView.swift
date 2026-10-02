import UIKit

/// What the list looks like before its first page lands: rows of grey shapes in
/// the real rows' proportions, with a soft light passing across them. It stands
/// in for a spinner so the screen already has the right shape when the
/// activity arrives. Still, without the sweep, under Reduce Motion.
final class NotificationSkeletonView: UIView {
    private static let rowCount = 9

    private let content = UIView()
    private let sweep = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityLabel = "Loading notifications"
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        content.pinEdges(to: self)
        buildRows()

        sweep.colors = [UIColor.black.withAlphaComponent(0.35).cgColor, UIColor.black.cgColor,
                        UIColor.black.withAlphaComponent(0.35).cgColor]
        sweep.startPoint = CGPoint(x: 0, y: 0.5)
        sweep.endPoint = CGPoint(x: 1, y: 0.5)
        sweep.locations = [0, 0.5, 1]
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

    private func shape(radius: CGFloat) -> UIView {
        let view = UIView()
        view.backgroundColor = .tertiarySystemFill
        view.layer.cornerRadius = radius
        view.layer.cornerCurve = .continuous
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        sweep.frame = bounds
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateAnimation()
    }

    override var isHidden: Bool {
        didSet { updateAnimation() }
    }

    private func updateAnimation() {
        sweep.removeAllAnimations()
        guard window != nil, !isHidden, !UIAccessibility.isReduceMotionEnabled else {
            content.layer.mask = nil
            return
        }
        content.layer.mask = sweep
        let animation = CABasicAnimation(keyPath: "locations")
        animation.fromValue = [-1.0, -0.5, 0.0]
        animation.toValue = [1.0, 1.5, 2.0]
        animation.duration = 1.4
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        sweep.add(animation, forKey: "sweep")
    }
}
