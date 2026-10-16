import UIKit
import UnragerKit

/// The like count wrapped in a ring that splits by how the people who liked it
/// stand with the viewer: mutuals, followers not yet followed back, people only
/// the viewer follows, and everyone else. The arcs grow into place when the
/// first page lands and slide to their new shares as more pages and follows
/// change the counts.
final class HeartRingView: UIView {
    static let side: CGFloat = 112
    private static let lineWidth: CGFloat = 11
    private static let visualGap: CGFloat = 4
    private static let order: [Standing] = [.mutual, .followsYou, .youFollow, .stranger]

    private let track = CAShapeLayer()
    private let arcs: [Standing: CAShapeLayer]
    private let heart = UIImageView(image: DesignSystem.icon("heart.fill", pointSize: 15, weight: .bold))
    private let countLabel = UILabel()
    private let captionLabel = UILabel()
    private var hasDrawn = false
    private var tally = LikerTally([])

    override init(frame: CGRect) {
        arcs = Dictionary(uniqueKeysWithValues: Self.order.map { ($0, CAShapeLayer()) })
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = .staticText

        for layer in [track] + Self.order.compactMap({ arcs[$0] }) {
            layer.fillColor = nil
            layer.lineWidth = Self.lineWidth
            layer.lineCap = .round
            layer.strokeStart = 0
            layer.strokeEnd = layer === track ? 1 : 0
            self.layer.addSublayer(layer)
        }

        heart.tintColor = DesignSystem.Color.like
        heart.contentMode = .center
        countLabel.font = DesignSystem.Typography.system(26, weight: .heavy)
        countLabel.textColor = DesignSystem.Color.label
        countLabel.textAlignment = .center
        countLabel.adjustsFontSizeToFitWidth = true
        countLabel.minimumScaleFactor = 0.5
        captionLabel.font = DesignSystem.Typography.system(11, weight: .semibold)
        captionLabel.textColor = DesignSystem.Color.secondaryLabel
        captionLabel.textAlignment = .center
        let center = UIStackView(arrangedSubviews: [heart, countLabel, captionLabel])
        center.axis = .vertical
        center.alignment = .center
        center.spacing = 0
        addManaged(center)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.side),
            heightAnchor.constraint(equalToConstant: Self.side),
            center.centerXAnchor.constraint(equalTo: centerXAnchor),
            center.centerYAnchor.constraint(equalTo: centerYAnchor),
            center.widthAnchor.constraint(lessThanOrEqualToConstant: Self.side - 2 * Self.lineWidth - 14),
        ])
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) {
            (view: HeartRingView, _) in view.paint()
        }
        paint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var radius: CGFloat { (Self.side - Self.lineWidth) / 2 }

    override func layoutSubviews() {
        super.layoutSubviews()
        let path = UIBezierPath(arcCenter: CGPoint(x: bounds.midX, y: bounds.midY), radius: radius,
                                startAngle: -.pi / 2, endAngle: 1.5 * .pi, clockwise: true).cgPath
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [track] + Self.order.compactMap({ arcs[$0] }) {
            layer.frame = bounds
            layer.path = path
        }
        CATransaction.commit()
    }

    /// Shows `count` in the middle and splits the ring by `tally`.
    func configure(likeCount: Int?, tally: LikerTally, spoken: String) {
        countLabel.text = likeCount.map { Format.count($0) } ?? "–"
        captionLabel.text = likeCount == 1 ? "like" : "likes"
        accessibilityLabel = spoken
        self.tally = tally
        paint()
        sweep(to: ranges(for: tally))
        guard !hasDrawn, likeCount != nil else { return }
        hasDrawn = true
        if !UIAccessibility.isReduceMotionEnabled {
            heart.addSymbolEffect(.bounce, options: .nonRepeating)
        }
    }

    private func paint() {
        let hasStandings = tally.hasStandings
        track.strokeColor = (hasStandings
            ? UIColor.quaternarySystemFill
            : DesignSystem.Color.like.withAlphaComponent(0.28)).resolvedColor(with: traitCollection).cgColor
        for (standing, layer) in arcs {
            layer.strokeColor = standing.tint.resolvedColor(with: traitCollection).cgColor
        }
    }

    /// Each arc's start and end as fractions of the ring, with a gap between
    /// neighbours wide enough for their rounded ends. A standing nobody holds
    /// has no arc.
    private func ranges(for tally: LikerTally) -> [Standing: (start: Double, end: Double)] {
        let counts = Self.order.map { ($0, tally.count(of: $0)) }
        let total = counts.reduce(0) { $0 + $1.1 }
        let present = counts.filter { $0.1 > 0 }
        guard total > 0 else { return [:] }
        let circumference = 2 * Double.pi * Double(radius)
        let gap = present.count > 1 ? (Double(Self.visualGap) + Double(Self.lineWidth)) / circumference : 0
        let available = 1 - Double(present.count) * gap
        var cursor = 0.0
        var result: [Standing: (start: Double, end: Double)] = [:]
        for (standing, count) in present {
            let length = Double(count) / Double(total) * available
            let start = cursor + gap / 2
            result[standing] = (start, start + max(length, 0.0004))
            cursor += length + gap
        }
        return result
    }

    private func sweep(to ranges: [Standing: (start: Double, end: Double)]) {
        let animated = window != nil && !UIAccessibility.isReduceMotionEnabled
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.6)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        for (standing, layer) in arcs {
            let range = ranges[standing]
            layer.strokeStart = CGFloat(range?.start ?? 0)
            layer.strokeEnd = CGFloat(range?.end ?? 0)
            layer.opacity = range == nil ? 0 : 1
        }
        CATransaction.commit()
    }
}
