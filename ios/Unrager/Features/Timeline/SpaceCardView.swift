import UIKit

/// The card an X Space link becomes. X sends nothing about a Space with the
/// post that links it, so the card says what it is and where a tap goes, over
/// the purple X gives Spaces and a waveform drawn from the Space's id (every
/// Space gets its own, the same each time).
final class SpaceCardView: UIView {
    var onTap: (() -> Void)?

    private static let startColor = UIColor(red: 0.471, green: 0.337, blue: 0.980, alpha: 1)
    private static let endColor = UIColor(red: 0.263, green: 0.188, blue: 0.690, alpha: 1)

    private let gradient = CAGradientLayer()
    private let waveform = SpaceWaveformView()
    private let micBadge = UIView()
    private let micIcon = UIImageView()
    private let kindLabel = UILabel()
    private let titleLabel = UILabel()
    private let openIcon = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = DesignSystem.Radius.media
        layer.cornerCurve = .continuous
        clipsToBounds = true
        isUserInteractionEnabled = true
        isAccessibilityElement = true
        accessibilityLabel = "X Space. Opens in X"
        accessibilityTraits = .link
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))

        gradient.colors = [Self.startColor.cgColor, Self.endColor.cgColor]
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        layer.insertSublayer(gradient, at: 0)

        waveform.translatesAutoresizingMaskIntoConstraints = false
        waveform.isUserInteractionEnabled = false
        addSubview(waveform)

        micBadge.backgroundColor = UIColor.white.withAlphaComponent(0.22)
        micBadge.layer.cornerRadius = 22
        micBadge.translatesAutoresizingMaskIntoConstraints = false
        micIcon.image = DesignSystem.icon("mic.fill", pointSize: 20, weight: .semibold)
        micIcon.tintColor = .white
        micIcon.contentMode = .center
        micBadge.addManaged(micIcon)
        micIcon.pinEdges(to: micBadge)

        kindLabel.text = "X SPACE"
        kindLabel.font = DesignSystem.Typography.system(11, weight: .heavy)
        kindLabel.textColor = UIColor.white.withAlphaComponent(0.78)
        titleLabel.text = "Tap to listen on X"
        titleLabel.font = DesignSystem.Typography.name()
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 2

        let text = UIStackView(arrangedSubviews: [kindLabel, titleLabel])
        text.axis = .vertical
        text.spacing = 2

        openIcon.image = DesignSystem.icon("arrow.up.right", pointSize: 15, weight: .bold)
        openIcon.tintColor = UIColor.white.withAlphaComponent(0.9)
        openIcon.setContentHuggingPriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [micBadge, text, UIView(), openIcon])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = .init(top: 14, leading: 14, bottom: 14, trailing: 16)
        addManaged(row)
        row.pinEdges(to: self)

        NSLayoutConstraint.activate([
            micBadge.widthAnchor.constraint(equalToConstant: 44),
            micBadge.heightAnchor.constraint(equalToConstant: 44),
            waveform.trailingAnchor.constraint(equalTo: trailingAnchor),
            waveform.topAnchor.constraint(equalTo: topAnchor),
            waveform.bottomAnchor.constraint(equalTo: bottomAnchor),
            waveform.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.55),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(spaceID: String) {
        waveform.seed = SpaceWaveformView.seed(for: spaceID)
    }

    func prepareForReuse() {
        onTap = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = bounds
    }

    @objc private func tapped() { onTap?() }
}

/// A row of rounded bars of varying height, drawn faintly behind the card's
/// content, fading out toward the leading edge.
private final class SpaceWaveformView: UIView {
    var seed: UInt64 = 1 { didSet { if seed != oldValue { setNeedsLayout() } } }

    private let barLayers = (0..<22).map { _ in CALayer() }
    private let fade = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        for bar in barLayers {
            bar.backgroundColor = UIColor.white.withAlphaComponent(0.2).cgColor
            layer.addSublayer(bar)
        }
        fade.colors = [UIColor.clear.cgColor, UIColor.white.cgColor]
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 0.7, y: 0.5)
        layer.mask = fade
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// FNV-1a over the id's bytes: the same Space always draws the same bars,
    /// which Swift's per-process `hashValue` would not give.
    static func seed(for id: String) -> UInt64 {
        id.utf8.reduce(14_695_981_039_346_656_037) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        fade.frame = bounds
        let count = CGFloat(barLayers.count)
        let slot = bounds.width / count
        let barWidth = max(2, slot * 0.5)
        var state = seed
        for (index, bar) in barLayers.enumerated() {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = CGFloat((state >> 33) % 1000) / 1000
            let height = bounds.height * (0.22 + 0.62 * unit)
            bar.frame = CGRect(x: slot * CGFloat(index) + (slot - barWidth) / 2,
                               y: (bounds.height - height) / 2, width: barWidth, height: height)
            bar.cornerRadius = barWidth / 2
        }
    }
}
