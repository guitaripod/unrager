import UIKit
import UnragerKit

/// A post's impressions hour by hour: gradient bars that rise in one after
/// another with the peak picked out, a thin line of how the reach added up with
/// a dot where half of it had arrived, and hour marks underneath. Pressing and
/// dragging reads any hour's figure. With no curve it is a pulsing outline of
/// one, holding the chart's place while X's numbers load.
final class EngagementChartView: UIView {
    static let height: CGFloat = 116
    private static let labelBand: CGFloat = 24
    private static let axisBand: CGFloat = 16

    private(set) var curve: EngagementCurve?
    private var bars: [CAGradientLayer] = []
    private let grid = CAShapeLayer()
    private let line = CAShapeLayer()
    private let halfDot = CAShapeLayer()
    private let rule = CALayer()
    private let tooltip = EngagementTip()
    private let peakTip = EngagementTip()
    private var axisLabels: [UILabel] = []
    private var scrubbing: Int?
    private var playsOnLayout = false
    private var isOutline = false

    private static let outlineShape: [Double] = (0..<30).map { index in
        let x = Double(index) / 29
        return 0.18 + 0.82 * exp(-pow((x - 0.18) / 0.22, 2))
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        grid.fillColor = nil
        grid.lineWidth = 0.5
        grid.lineDashPattern = [2, 3]
        layer.addSublayer(grid)
        line.fillColor = nil
        line.lineWidth = 1.5
        line.lineCap = .round
        line.lineJoin = .round
        layer.addSublayer(line)
        halfDot.lineWidth = 2
        layer.addSublayer(halfDot)
        rule.cornerRadius = 0.5
        rule.opacity = 0
        layer.addSublayer(rule)
        for tip in [tooltip, peakTip] {
            tip.alpha = 0
            addSubview(tip)
        }
        let press = UILongPressGestureRecognizer(target: self, action: #selector(scrub(_:)))
        press.minimumPressDuration = 0.12
        press.allowableMovement = .greatestFiniteMagnitude
        addGestureRecognizer(press)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) {
            (view: EngagementChartView, _) in view.paint()
        }
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Content

    /// Draws `curve`, or the placeholder outline when it is nil.
    func show(_ curve: EngagementCurve?) {
        guard curve != self.curve || (curve == nil) != isOutline else { return }
        self.curve = curve
        isOutline = curve == nil
        scrubbing = nil
        bars.forEach { $0.removeFromSuperlayer() }
        let count = curve?.hourly.count ?? Self.outlineShape.count
        bars = (0..<count).map { _ in
            let bar = CAGradientLayer()
            bar.masksToBounds = true
            bar.anchorPoint = CGPoint(x: 0.5, y: 1)
            layer.insertSublayer(bar, below: line)
            return bar
        }
        axisLabels.forEach { $0.removeFromSuperview() }
        axisLabels = []
        if let curve {
            for hour in EngagementCurve.axisTicks(hours: curve.hourly.count) {
                let label = UILabel()
                label.font = DesignSystem.Typography.system(10, weight: .regular)
                label.textColor = DesignSystem.Color.tertiaryLabel
                label.text = "\(hour)h"
                label.tag = hour
                addSubview(label)
                axisLabels.append(label)
            }
            isAccessibilityElement = true
            accessibilityLabel = curve.spoken
        } else {
            isAccessibilityElement = false
        }
        peakTip.alpha = curve == nil ? 0 : 1
        line.isHidden = curve == nil
        halfDot.isHidden = curve == nil
        paint()
        setNeedsLayout()
        if isOutline { pulse() } else { layer.removeAnimation(forKey: "pulse") }
    }

    /// Lets the bars rise from the baseline the next time the chart is laid out
    /// with a size: left to right, each a beat after the last, then the reach
    /// line draws itself across and the peak is named.
    func play() {
        playsOnLayout = true
        setNeedsLayout()
    }

    // MARK: - Geometry

    private var plot: CGRect {
        CGRect(x: 0, y: Self.labelBand, width: bounds.width,
               height: max(0, bounds.height - Self.labelBand - Self.axisBand))
    }

    private func values() -> [Double] {
        if let curve {
            let peak = Double(curve.peak)
            return curve.hourly.map { Double($0) / peak }
        }
        return Self.outlineShape
    }

    private func slot() -> CGFloat {
        bounds.width / CGFloat(max(bars.count, 1))
    }

    private func barFrame(_ index: Int, value: Double) -> CGRect {
        let slot = slot()
        let width = min(8, max(1.5, slot * 0.68))
        let height = max(2, plot.height * CGFloat(value))
        return CGRect(x: CGFloat(index) * slot + (slot - width) / 2, y: plot.maxY - height, width: width, height: height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, !bars.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let heights = values()
        for (index, bar) in bars.enumerated() {
            let frame = barFrame(index, value: heights[index])
            bar.bounds = CGRect(origin: .zero, size: frame.size)
            bar.position = CGPoint(x: frame.midX, y: frame.maxY)
            bar.cornerRadius = min(frame.width / 2, 2.5)
        }
        let guides = UIBezierPath()
        for fraction in [0.5, 1.0] {
            let y = plot.maxY - plot.height * fraction
            guides.move(to: CGPoint(x: 0, y: y))
            guides.addLine(to: CGPoint(x: bounds.width, y: y))
        }
        grid.path = guides.cgPath
        if let curve {
            let points = curve.cumulative.enumerated().map { index, share in
                CGPoint(x: (CGFloat(index) + 0.5) * slot(), y: plot.maxY - plot.height * CGFloat(share))
            }
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 0, y: plot.maxY))
            points.forEach { path.addLine(to: $0) }
            line.path = path.cgPath
            let half = points[curve.halfLife - 1]
            halfDot.bounds = CGRect(x: 0, y: 0, width: 10, height: 10)
            halfDot.position = half
            halfDot.path = UIBezierPath(ovalIn: CGRect(x: 1, y: 1, width: 8, height: 8)).cgPath
            for label in axisLabels {
                label.sizeToFit()
                let x = min(max(label.frame.width / 2, CGFloat(label.tag) * slot()), bounds.width - label.frame.width / 2)
                label.center = CGPoint(x: x, y: plot.maxY + 4 + label.frame.height / 2)
            }
            placePeakTip(curve)
        }
        CATransaction.commit()
        if playsOnLayout {
            playsOnLayout = false
            animateIn()
        }
    }

    private func placePeakTip(_ curve: EngagementCurve) {
        peakTip.set("Peak · \(Format.count(curve.peak))")
        let frame = barFrame(curve.peakIndex, value: 1)
        let size = peakTip.intrinsicContentSize
        let x = min(max(0, frame.midX - size.width / 2), bounds.width - size.width)
        peakTip.frame = CGRect(x: x, y: frame.minY - size.height - 3, width: size.width, height: size.height)
    }

    // MARK: - Colour

    private func paint() {
        let accent = DesignSystem.Color.accent.resolvedColor(with: traitCollection)
        let spark = DesignSystem.Color.spark.resolvedColor(with: traitCollection)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        grid.strokeColor = DesignSystem.Color.separator.resolvedColor(with: traitCollection).cgColor
        line.strokeColor = spark.withAlphaComponent(0.85).cgColor
        halfDot.strokeColor = spark.cgColor
        halfDot.fillColor = DesignSystem.Color.surface.resolvedColor(with: traitCollection).cgColor
        rule.backgroundColor = DesignSystem.Color.label.withAlphaComponent(0.35).cgColor
        for (index, bar) in bars.enumerated() {
            if isOutline {
                let grey = UIColor.secondarySystemFill.resolvedColor(with: traitCollection)
                bar.colors = [grey.cgColor, grey.cgColor]
            } else if index == curve?.peakIndex {
                bar.colors = [accent.cgColor, accent.withAlphaComponent(0.7).cgColor]
            } else {
                bar.colors = [accent.withAlphaComponent(0.8).cgColor, accent.withAlphaComponent(0.3).cgColor]
            }
        }
        CATransaction.commit()
    }

    private func pulse() {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 0.45
        breathe.toValue = 1
        breathe.duration = 0.85
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(breathe, forKey: "pulse")
    }

    // MARK: - Motion

    private func animateIn() {
        guard !UIAccessibility.isReduceMotionEnabled, window != nil, !isOutline else { return }
        let now = CACurrentMediaTime()
        for (index, bar) in bars.enumerated() {
            let rise = CASpringAnimation(keyPath: "transform.scale.y")
            rise.fromValue = 0.001
            rise.toValue = 1
            rise.damping = 13
            rise.stiffness = 170
            rise.mass = 1
            rise.beginTime = now + 0.04 + Double(index) * 0.011
            rise.duration = rise.settlingDuration
            rise.fillMode = .backwards
            bar.add(rise, forKey: "rise")
        }
        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.toValue = 1
        draw.beginTime = now + 0.3
        draw.duration = 0.85
        draw.fillMode = .backwards
        draw.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.7, 0.2, 1)
        line.add(draw, forKey: "draw")
        let pop = CASpringAnimation(keyPath: "transform.scale")
        pop.fromValue = 0
        pop.toValue = 1
        pop.damping = 9
        pop.stiffness = 220
        pop.mass = 1
        pop.beginTime = now + 0.3 + 0.85 * Double((curve?.halfLife ?? 1)) / Double(max(bars.count, 1)) + 0.1
        pop.duration = pop.settlingDuration
        pop.fillMode = .backwards
        halfDot.add(pop, forKey: "pop")
        peakTip.alpha = 0
        UIView.animate(withDuration: 0.3, delay: 0.55 + Double((curve?.peakIndex ?? 0)) * 0.011,
                       options: [.allowUserInteraction]) {
            self.peakTip.alpha = self.scrubbing == nil ? 1 : 0
        }
    }

    // MARK: - Scrubbing

    @objc private func scrub(_ press: UILongPressGestureRecognizer) {
        guard let curve, bounds.width > 0 else { return }
        switch press.state {
        case .began, .changed:
            let index = min(max(0, Int(press.location(in: self).x / slot())), curve.hourly.count - 1)
            guard index != scrubbing else { return }
            if scrubbing == nil { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
            else { UISelectionFeedbackGenerator().selectionChanged() }
            scrubbing = index
            highlight(index, curve: curve)
        default:
            scrubbing = nil
            release()
        }
    }

    private func highlight(_ index: Int, curve: EngagementCurve) {
        let frame = barFrame(index, value: Double(curve.hourly[index]) / Double(curve.peak))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (position, bar) in bars.enumerated() { bar.opacity = position == index ? 1 : 0.38 }
        rule.frame = CGRect(x: frame.midX - 0.5, y: Self.labelBand - 4, width: 1, height: plot.height + 4)
        rule.opacity = 1
        CATransaction.commit()
        tooltip.set("\(EngagementCurve.hourRange(index)) · \(Format.count(curve.hourly[index])) · "
            + EngagementMix.percent(curve.share(at: index)))
        let size = tooltip.intrinsicContentSize
        let x = min(max(0, frame.midX - size.width / 2), bounds.width - size.width)
        tooltip.frame = CGRect(x: x, y: 0, width: size.width, height: size.height)
        UIView.animate(withDuration: 0.12) {
            self.tooltip.alpha = 1
            self.peakTip.alpha = 0
        }
    }

    private func release() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        bars.forEach { $0.opacity = 1 }
        rule.opacity = 0
        CATransaction.commit()
        UIView.animate(withDuration: 0.2) {
            self.tooltip.alpha = 0
            self.peakTip.alpha = 1
        }
    }
}

/// A small capsule label that floats over the chart.
private final class EngagementTip: UIView {
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = DesignSystem.Color.elevatedBackground
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.12
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: 1)
        label.font = DesignSystem.Typography.system(11, weight: .semibold)
        label.textColor = DesignSystem.Color.label
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        let text = label.intrinsicContentSize
        return CGSize(width: text.width + 16, height: text.height + 6)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }

    func set(_ text: String) {
        label.text = text
        invalidateIntrinsicContentSize()
    }
}

/// How a post's engagement splits between likes, reposts, replies, quotes and
/// saves: one rounded bar cut into coloured segments that grow out from the left,
/// and under it the biggest few with their shares.
final class EngagementMixView: UIView {
    private let track = UIView()
    private var segments: [CALayer] = []
    private let legend = UIStackView()
    private var mix: EngagementMix?
    private var playsOnLayout = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        track.layer.cornerCurve = .continuous
        track.layer.cornerRadius = 5
        track.clipsToBounds = true
        track.backgroundColor = UIColor.secondarySystemFill
        track.translatesAutoresizingMaskIntoConstraints = false
        legend.axis = .horizontal
        legend.spacing = DesignSystem.Spacing.m
        legend.alignment = .center
        legend.translatesAutoresizingMaskIntoConstraints = false
        addSubview(track)
        addSubview(legend)
        NSLayoutConstraint.activate([
            track.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            track.leadingAnchor.constraint(equalTo: leadingAnchor),
            track.trailingAnchor.constraint(equalTo: trailingAnchor),
            track.heightAnchor.constraint(equalToConstant: 10),
            legend.topAnchor.constraint(equalTo: track.bottomAnchor, constant: 10),
            legend.leadingAnchor.constraint(equalTo: leadingAnchor),
            legend.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            legend.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) {
            (view: EngagementMixView, _) in view.paint()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static func color(for kind: EngagementMix.Kind) -> UIColor {
        switch kind {
        case .likes: return DesignSystem.Color.like
        case .reposts: return DesignSystem.Color.retweet
        case .replies: return DesignSystem.Color.accent
        case .quotes: return DesignSystem.Color.quote
        case .bookmarks: return DesignSystem.Color.spark
        }
    }

    func show(_ newMix: EngagementMix?) {
        guard newMix != mix else { return }
        mix = newMix
        segments.forEach { $0.removeFromSuperlayer() }
        segments = (newMix?.slices ?? []).map { _ in
            let segment = CALayer()
            segment.anchorPoint = CGPoint(x: 0, y: 0.5)
            track.layer.addSublayer(segment)
            return segment
        }
        legend.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for slice in (newMix?.slices ?? []).prefix(4) {
            legend.addArrangedSubview(legendItem(slice))
        }
        isAccessibilityElement = newMix != nil
        accessibilityLabel = newMix.map { mix in
            "Engagement: " + mix.slices.map { "\($0.kind.title) \(EngagementMix.percent($0.share))" }.joined(separator: ", ")
        }
        paint()
        setNeedsLayout()
    }

    private func legendItem(_ slice: EngagementMix.Slice) -> UIView {
        let dot = UIView()
        dot.backgroundColor = Self.color(for: slice.kind)
        dot.layer.cornerRadius = 3.5
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
        ])
        let label = UILabel()
        label.font = DesignSystem.Typography.system(11, weight: .medium)
        label.textColor = DesignSystem.Color.secondaryLabel
        label.text = "\(slice.kind.title) \(EngagementMix.percent(slice.share))"
        let item = UIStackView(arrangedSubviews: [dot, label])
        item.spacing = 4
        item.alignment = .center
        return item
    }

    /// Grows the segments out from the left, each a beat after the one before.
    func play() {
        playsOnLayout = true
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let mix, track.bounds.width > 0 else { return }
        let gap: CGFloat = 2
        let usable = track.bounds.width - gap * CGFloat(max(mix.slices.count - 1, 0))
        var x: CGFloat = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, slice) in mix.slices.enumerated() {
            let width = max(3, usable * CGFloat(slice.share))
            segments[index].bounds = CGRect(x: 0, y: 0, width: width, height: track.bounds.height)
            segments[index].position = CGPoint(x: x, y: track.bounds.midY)
            x += width + gap
        }
        CATransaction.commit()
        if playsOnLayout {
            playsOnLayout = false
            guard !UIAccessibility.isReduceMotionEnabled, window != nil else { return }
            let now = CACurrentMediaTime()
            for (index, segment) in segments.enumerated() {
                let grow = CASpringAnimation(keyPath: "transform.scale.x")
                grow.fromValue = 0.001
                grow.toValue = 1
                grow.damping = 16
                grow.stiffness = 150
                grow.mass = 1
                grow.beginTime = now + 0.05 + Double(index) * 0.07
                grow.duration = grow.settlingDuration
                grow.fillMode = .backwards
                segment.add(grow, forKey: "grow")
            }
        }
    }

    private func paint() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, slice) in (mix?.slices ?? []).enumerated() where index < segments.count {
            segments[index].backgroundColor = Self.color(for: slice.kind).resolvedColor(with: traitCollection).cgColor
        }
        CATransaction.commit()
    }
}
