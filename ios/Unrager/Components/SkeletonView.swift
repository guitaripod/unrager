import UIKit

/// The shared base of the grey placeholder screens shown before a first load
/// lands: shapes in the real rows' proportions with a soft light passing across
/// them. A subclass builds its shapes inside `content`; the sweep runs while the
/// view is on screen and shown, and is left out under Reduce Motion, where the
/// shapes simply sit still.
class SkeletonView: UIView {
    let content = UIView()
    private let sweep = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityLabel = "Loading"
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        content.pinEdges(to: self)

        sweep.colors = [UIColor.black.withAlphaComponent(0.35).cgColor, UIColor.black.cgColor,
                        UIColor.black.withAlphaComponent(0.35).cgColor]
        sweep.startPoint = CGPoint(x: 0, y: 0.5)
        sweep.endPoint = CGPoint(x: 1, y: 0.5)
        sweep.locations = [0, 0.5, 1]
        NotificationCenter.default.addObserver(
            self, selector: #selector(updateAnimation), name: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// A grey rounded shape for a subclass to place.
    func shape(radius: CGFloat) -> UIView {
        let view = UIView()
        view.backgroundColor = .secondarySystemFill
        view.layer.cornerRadius = radius
        view.layer.cornerCurve = .continuous
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    /// How tall the rows stand at `width`, for placing the view by frame.
    func fittingHeight(width: CGFloat) -> CGFloat {
        systemLayoutSizeFitting(CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                                withHorizontalFittingPriority: .required,
                                verticalFittingPriority: .fittingSizeLevel).height
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

    @objc private func updateAnimation() {
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

/// A stack of grey bars, each a share of the width, for the small stretches of
/// a screen that load on their own (a profile's name, bio and counts).
final class BarsSkeletonView: SkeletonView {
    init(bars: [(share: CGFloat, height: CGFloat)], spacing: CGFloat = 8) {
        super.init(frame: .zero)
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        stack.pinEdges(to: content)
        for bar in bars {
            let view = shape(radius: min(6, bar.height / 2))
            stack.addArrangedSubview(view)
            view.heightAnchor.constraint(equalToConstant: bar.height).isActive = true
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: bar.share).isActive = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
