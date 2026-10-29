import UIKit
import UnragerKit

/// The like count wrapped in a ring that splits by how the people who liked it
/// stand with the viewer: mutuals, followers not yet followed back, people only
/// the viewer follows, and everyone else. While the first page is on its way a
/// short arc circles the ring; when the people land it gives way to the real
/// arcs, which sweep in clockwise from the top. After that the arcs slide to
/// their new shares as more pages and follows change the counts.
final class HeartRingView: UIView {
    static let side: CGFloat = 112
    private static let lineWidth: CGFloat = 11
    private static let visualGap: CGFloat = 4
    private static let order: [Standing] = [.mutual, .followsYou, .youFollow, .stranger]

    private let track = CAShapeLayer()
    private let container = CALayer()
    private let pulse = CAShapeLayer()
    private let arcs: [Standing: CAShapeLayer]
    private let heart = UIImageView(image: DesignSystem.icon("heart.fill", pointSize: 15, weight: .bold))
    private let countLabel = CountingLabel()
    private let captionLabel = UILabel()
    private var isPulsing = false
    private var hasBounced = false
    private var tally = LikerTally([])

    override init(frame: CGRect) {
        arcs = Dictionary(uniqueKeysWithValues: Self.order.map { ($0, CAShapeLayer()) })
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = .staticText

        for layer in [track, pulse] + Self.order.compactMap({ arcs[$0] }) {
            layer.fillColor = nil
            layer.lineWidth = Self.lineWidth
            layer.lineCap = .round
        }
        track.strokeEnd = 1
        pulse.strokeEnd = 0.2
        pulse.opacity = 0
        for standing in Self.order {
            arcs[standing]?.strokeEnd = 0
            arcs[standing]?.opacity = 0
            if let arc = arcs[standing] { container.addSublayer(arc) }
        }
        layer.addSublayer(track)
        layer.addSublayer(pulse)
        layer.addSublayer(container)

        heart.tintColor = DesignSystem.Color.like
        heart.contentMode = .center
        countLabel.font = DesignSystem.Typography.system(26, weight: .heavy)
        countLabel.format = { Format.count($0) }
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

    private var circle: CGPath {
        UIBezierPath(arcCenter: CGPoint(x: bounds.midX, y: bounds.midY), radius: radius,
                     startAngle: -.pi / 2, endAngle: 1.5 * .pi, clockwise: true).cgPath
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.frame = bounds
        for layer in [track, pulse] + Self.order.compactMap({ arcs[$0] }) {
            layer.frame = bounds
            layer.path = circle
        }
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyPulse()
    }

    /// Shows `likeCount` in the middle and splits the ring by `tally`. While
    /// `loading` a short arc circles instead. `reveal` is for the first time
    /// the people are known: the arcs sweep in rather than slide.
    func configure(likeCount: Int?, tally: LikerTally, loading: Bool, reveal: Bool, spoken: String) {
        if let likeCount { countLabel.setValue(likeCount) } else { countLabel.text = "–" }
        captionLabel.text = likeCount == 1 ? "like" : "likes"
        accessibilityLabel = spoken
        self.tally = tally
        paint()
        isPulsing = loading && !tally.hasStandings
        applyPulse()
        let ranges = ranges(for: tally)
        if reveal, tally.hasStandings, window != nil, !UIAccessibility.isReduceMotionEnabled {
            place(ranges)
            sweepIn()
        } else {
            slide(to: ranges)
        }
        guard !hasBounced, likeCount != nil, !loading else { return }
        hasBounced = true
        if window != nil, !UIAccessibility.isReduceMotionEnabled {
            heart.addSymbolEffect(.bounce, options: .nonRepeating)
        }
    }

    private func paint() {
        let hasStandings = tally.hasStandings
        let like = DesignSystem.Color.like.resolvedColor(with: traitCollection)
        track.strokeColor = (hasStandings
            ? UIColor.quaternarySystemFill.resolvedColor(with: traitCollection)
            : like.withAlphaComponent(0.2)).cgColor
        pulse.strokeColor = like.cgColor
        for (standing, layer) in arcs {
            layer.strokeColor = standing.tint.resolvedColor(with: traitCollection).cgColor
        }
    }

    /// Circles a short arc that breathes while the first page loads, and lets it
    /// fade when it is done. Left out under Reduce Motion, where the empty
    /// track just waits.
    private func applyPulse() {
        pulse.removeAnimation(forKey: "spin")
        pulse.removeAnimation(forKey: "breathe")
        let animates = isPulsing && window != nil && !UIAccessibility.isReduceMotionEnabled
        if animates {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = 2 * Double.pi
            spin.duration = 1.15
            spin.repeatCount = .infinity
            pulse.add(spin, forKey: "spin")
            let breathe = CABasicAnimation(keyPath: "strokeEnd")
            breathe.fromValue = 0.1
            breathe.toValue = 0.34
            breathe.duration = 0.9
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            pulse.add(breathe, forKey: "breathe")
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        CATransaction.setDisableActions(window == nil)
        pulse.opacity = animates ? 1 : 0
        CATransaction.commit()
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

    private func place(_ ranges: [Standing: (start: Double, end: Double)]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (standing, layer) in arcs {
            let range = ranges[standing]
            layer.strokeStart = CGFloat(range?.start ?? 0)
            layer.strokeEnd = CGFloat(range?.end ?? 0)
            layer.opacity = range == nil ? 0 : 1
        }
        CATransaction.commit()
    }

    /// Draws the arcs on clockwise from the top, a wide stroke wiping across
    /// them, then lets go of it.
    private func sweepIn() {
        let wipe = CAShapeLayer()
        wipe.frame = bounds
        wipe.path = circle
        wipe.fillColor = nil
        wipe.strokeColor = UIColor.white.cgColor
        wipe.lineWidth = Self.lineWidth + 8
        wipe.strokeEnd = 0
        container.mask = wipe
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in self?.container.mask = nil }
        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.toValue = 1
        draw.duration = 0.75
        draw.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.7, 0.2, 1)
        wipe.strokeEnd = 1
        wipe.add(draw, forKey: "draw")
        CATransaction.commit()
    }

    private func slide(to ranges: [Standing: (start: Double, end: Double)]) {
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
