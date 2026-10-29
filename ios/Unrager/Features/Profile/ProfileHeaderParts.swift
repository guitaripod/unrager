import UIKit
import UnragerKit

/// The profile's picture on a disc of the page colour, ringed in the colour of
/// how the person stands with the viewer (amber for a follower not followed
/// back, teal for a mutual) when there is a standing worth showing. The ring
/// draws itself round the picture the first time the account appears.
final class ProfileAvatarView: UIView {
    static let diameter: CGFloat = 76
    private static let gap: CGFloat = 3
    private static let ringWidth: CGFloat = 3
    private static let halo: CGFloat = 4
    static let total: CGFloat = diameter + 2 * (gap + ringWidth + halo)

    private let content = UIView()
    private let disc = UIView()
    private let ring = CAShapeLayer()
    private let picture = AsyncImageView(frame: .zero)
    private var tint: UIColor?

    override init(frame: CGRect) {
        super.init(frame: frame)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        disc.backgroundColor = DesignSystem.Color.background
        disc.layer.cornerRadius = Self.total / 2
        disc.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(disc)
        picture.setRounded(Self.diameter / 2)
        picture.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(picture)
        ring.fillColor = nil
        ring.lineWidth = Self.ringWidth
        ring.lineCap = .round
        ring.strokeStart = 0
        ring.strokeEnd = 1
        ring.isHidden = true
        content.layer.addSublayer(ring)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.total),
            heightAnchor.constraint(equalToConstant: Self.total),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            disc.centerXAnchor.constraint(equalTo: centerXAnchor),
            disc.centerYAnchor.constraint(equalTo: centerYAnchor),
            disc.widthAnchor.constraint(equalToConstant: Self.total),
            disc.heightAnchor.constraint(equalToConstant: Self.total),
            picture.centerXAnchor.constraint(equalTo: centerXAnchor),
            picture.centerYAnchor.constraint(equalTo: centerYAnchor),
            picture.widthAnchor.constraint(equalToConstant: Self.diameter),
            picture.heightAnchor.constraint(equalToConstant: Self.diameter),
        ])
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) {
            (view: ProfileAvatarView, _) in view.paint()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = content.bounds
        let radius = Self.diameter / 2 + Self.gap + Self.ringWidth / 2
        ring.path = UIBezierPath(arcCenter: CGPoint(x: content.bounds.midX, y: content.bounds.midY), radius: radius,
                                 startAngle: -.pi / 2, endAngle: 1.5 * .pi, clockwise: true).cgPath
        CATransaction.commit()
    }

    /// Shows the picture at `url`, or clears it.
    func load(url: URL?) {
        picture.load(url: url, targetSize: CGSize(width: Self.diameter, height: Self.diameter))
    }

    /// Rings the picture for `standing` when it calls for one, and takes the ring
    /// away otherwise.
    func setStanding(_ standing: Standing?) {
        tint = standing?.drawsRing == true ? standing?.tint : nil
        paint()
    }

    private func paint() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.isHidden = tint == nil
        ring.strokeColor = tint?.resolvedColor(with: traitCollection).cgColor
        CATransaction.commit()
    }

    /// The picture settles into place from a little small, and the ring draws
    /// round it.
    func reveal() {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        content.alpha = 0
        content.transform = CGAffineTransform(scaleX: 0.84, y: 0.84)
        UIView.animate(withDuration: 0.55, delay: 0, usingSpringWithDamping: 0.78, initialSpringVelocity: 0,
                       options: [.allowUserInteraction]) {
            self.content.alpha = 1
            self.content.transform = .identity
        }
        guard !ring.isHidden else { return }
        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.toValue = 1
        draw.beginTime = CACurrentMediaTime() + 0.12
        draw.duration = 0.7
        draw.fillMode = .backwards
        draw.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.7, 0.2, 1)
        ring.add(draw, forKey: "draw")
    }
}

/// A small tinted capsule that says how the person stands with the viewer:
/// "Follows you" or "Mutual".
final class StandingCapsule: UIView {
    private let icon = UIImageView()
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerCurve = .continuous
        icon.contentMode = .center
        icon.setContentHuggingPriority(.required, for: .horizontal)
        label.numberOfLines = 1
        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.spacing = 4
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
        ])
        isAccessibilityElement = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = min(bounds.height / 2, 14)
    }

    /// Shows the capsule for `standing`, or hides it when there is nothing to say.
    func configure(_ standing: Standing?) {
        guard let standing, let phrase = standing.phrase else {
            isHidden = true
            return
        }
        isHidden = false
        let tint = standing.tint
        backgroundColor = tint.withAlphaComponent(0.14)
        let font = DesignSystem.Typography.system(12, weight: .semibold)
        label.font = font
        label.textColor = tint
        label.text = phrase
        icon.image = UIImage(systemName: standing == .mutual ? "arrow.left.arrow.right" : "person.fill.checkmark",
                             withConfiguration: UIImage.SymbolConfiguration(font: font, scale: .small))
        icon.tintColor = tint
        accessibilityLabel = phrase
    }
}

/// One line of a profile's facts as a capsule: a symbol and a few words. A link
/// takes taps.
final class ProfileFactChip: UIControl {
    let fact: ProfileFact
    var onTap: ((URL) -> Void)?

    init(fact: ProfileFact) {
        self.fact = fact
        super.init(frame: .zero)
        backgroundColor = DesignSystem.Color.surface
        layer.cornerCurve = .continuous
        let color = fact.url == nil ? DesignSystem.Color.secondaryLabel : DesignSystem.Color.accent
        let font = DesignSystem.Typography.system(13, weight: .medium)
        let icon = UIImageView(image: UIImage(systemName: fact.symbol,
                                              withConfiguration: UIImage.SymbolConfiguration(font: font, scale: .small)))
        icon.tintColor = color
        icon.contentMode = .center
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let label = UILabel()
        label.attributedText = TwemojiText.attributed(fact.text, font: font, color: color)
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.spacing = 5
        stack.alignment = .center
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
        ])
        isAccessibilityElement = true
        accessibilityLabel = fact.spoken
        if fact.url != nil {
            accessibilityTraits = .link
            addAction(UIAction { [weak self] _ in
                guard let self, let url = self.fact.url else { return }
                Haptics.selection()
                self.onTap?(url)
            }, for: .touchUpInside)
        } else {
            accessibilityTraits = .staticText
            isUserInteractionEnabled = false
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }
}

/// An account's facts (where it is, its website, when it joined) as capsules
/// that wrap onto further lines a whole capsule at a time, never in the middle
/// of a phrase.
final class ProfileFactsView: UIView {
    var onTapURL: ((URL) -> Void)?

    private static let spacing: CGFloat = 8
    private var chips: [ProfileFactChip] = []
    private var facts: [ProfileFact] = []
    private var measuredWidth: CGFloat = 0

    /// The width the capsules wrap within; set by the header when it knows its
    /// own.
    var preferredWidth: CGFloat = 0 {
        didSet {
            guard preferredWidth != oldValue else { return }
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: flow(width: preferredWidth, apply: false))
    }

    func configure(_ newFacts: [ProfileFact], force: Bool = false) {
        guard force || newFacts != facts else { return }
        facts = newFacts
        chips.forEach { $0.removeFromSuperview() }
        chips = newFacts.map { fact in
            let chip = ProfileFactChip(fact: fact)
            chip.onTap = { [weak self] url in self?.onTapURL?(url) }
            addSubview(chip)
            return chip
        }
        isHidden = newFacts.isEmpty
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    /// Lays the capsules out in rows within `width`; returns the height used.
    @discardableResult
    private func flow(width: CGFloat, apply: Bool) -> CGFloat {
        guard width > 0, !chips.isEmpty else { return 0 }
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for chip in chips {
            var size = chip.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
            size.width = min(size.width, width)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + Self.spacing
                rowHeight = 0
            }
            if apply { chip.frame = CGRect(origin: CGPoint(x: x, y: y), size: size) }
            x += size.width + Self.spacing
            rowHeight = max(rowHeight, size.height)
        }
        return y + rowHeight
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width > 0 ? bounds.width : preferredWidth
        flow(width: width, apply: true)
        if bounds.width > 0, abs(bounds.width - preferredWidth) > 0.5 { preferredWidth = bounds.width }
    }
}

/// The followers, following and account-age figures as three tiles in one
/// panel. Followers and following open their lists; the figures count up when
/// they first appear and slide to new values after.
final class ProfileStatTiles: UIView {
    var onTapFollowers: (() -> Void)?
    var onTapFollowing: (() -> Void)?

    private let followers = StatTile(caption: "followers", opensList: true)
    private let following = StatTile(caption: "following", opensList: true)
    private let age = StatTile(caption: "on X", opensList: false)
    private let stack = UIStackView()
    private let dividers = [UIView(), UIView()]

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = DesignSystem.Color.surface
        layer.cornerRadius = DesignSystem.Radius.card
        layer.cornerCurve = .continuous
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        [followers, following, age].forEach(stack.addArrangedSubview)
        addSubview(stack)
        for divider in dividers {
            divider.backgroundColor = DesignSystem.Color.separator
            addSubview(divider)
        }
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        followers.addAction(UIAction { [weak self] _ in self?.onTapFollowers?() }, for: .touchUpInside)
        following.addAction(UIAction { [weak self] _ in self?.onTapFollowing?() }, for: .touchUpInside)
        followers.accessibilityHint = "Shows this user's followers"
        following.accessibilityHint = "Shows the accounts this user follows"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Hairlines between the tiles on show, a third (or half) of the way across.
    override func layoutSubviews() {
        super.layoutSubviews()
        let shown = [followers, following, age].filter { !$0.isHidden }.count
        let thickness = 1 / traitCollection.displayScale
        for (index, divider) in dividers.enumerated() {
            divider.isHidden = index >= shown - 1
            divider.frame = CGRect(x: bounds.width * CGFloat(index + 1) / CGFloat(max(shown, 1)) - thickness / 2,
                                   y: 14, width: thickness, height: max(0, bounds.height - 28))
        }
    }

    /// Re-resolves the tiles' fonts after a change of text size.
    func applyFonts() {
        [followers, following, age].forEach { $0.applyFonts() }
    }

    /// Shows the figures. `reveal` climbs them from zero; otherwise they slide
    /// from what they showed. The age tile is left out for an account that
    /// doesn't say when it joined.
    func configure(followers followerCount: Int, following followingCount: Int, joinedAt: Date?, reveal: Bool) {
        followers.set(count: followerCount, reveal: reveal, delay: 0.18)
        following.set(count: followingCount, reveal: reveal, delay: 0.26)
        if let joinedAt, let tenure = ProfileText.accountAge(since: joinedAt) {
            age.set(text: tenure.figure, spoken: tenure.spoken, reveal: reveal, delay: 0.34)
            age.isHidden = false
        } else {
            age.isHidden = true
        }
        setNeedsLayout()
    }
}

/// One figure over its caption.
private final class StatTile: UIControl {
    private let number = CountingLabel()
    private let caption = UILabel()
    private let opensList: Bool

    init(caption text: String, opensList: Bool) {
        self.opensList = opensList
        super.init(frame: .zero)
        number.font = DesignSystem.Typography.system(21, weight: .bold)
        number.textColor = DesignSystem.Color.label
        number.textAlignment = .center
        number.adjustsFontSizeToFitWidth = true
        number.minimumScaleFactor = 0.6
        number.format = { Format.count($0) }
        caption.font = DesignSystem.Typography.caption()
        caption.textColor = DesignSystem.Color.secondaryLabel
        caption.text = text
        caption.textAlignment = .center
        let stack = UIStackView(arrangedSubviews: [number, caption])
        stack.axis = .vertical
        stack.spacing = 1
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 64),
        ])
        isAccessibilityElement = true
        accessibilityTraits = opensList ? .button : .staticText
        isUserInteractionEnabled = opensList
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? DesignSystem.Color.separator.withAlphaComponent(0.4) : .clear }
    }

    func applyFonts() {
        number.font = DesignSystem.Typography.system(21, weight: .bold)
        caption.font = DesignSystem.Typography.caption()
    }

    func set(count: Int, reveal: Bool, delay: TimeInterval) {
        if reveal {
            number.setValue(count, from: 0, delay: delay, duration: 0.8)
        } else {
            number.setValue(count)
        }
        accessibilityLabel = "\(Format.count(count)) \(caption.text ?? "")"
    }

    func set(text: String, spoken: String, reveal: Bool, delay: TimeInterval) {
        number.format = { _ in text }
        number.setValue(1, animated: false)
        accessibilityLabel = spoken
        guard reveal, !UIAccessibility.isReduceMotionEnabled, window != nil else { return }
        number.alpha = 0
        UIView.animate(withDuration: 0.4, delay: delay, options: [.allowUserInteraction]) { self.number.alpha = 1 }
    }
}

/// The Posts / Replies / Media control: a capsule with a lighter pill that
/// slides to the chosen title.
final class ProfileTabStrip: UIControl {
    var onChange: ((Int) -> Void)?

    private(set) var selectedIndex = 0
    private let pill = UIView()
    private var buttons: [UIButton] = []
    private let stack = UIStackView()

    /// `onGlass` draws the strip for sitting on glass: no fill of its own, and a
    /// faint pill instead of a raised one.
    init(titles: [String], onGlass: Bool = false) {
        super.init(frame: .zero)
        backgroundColor = onGlass ? .clear : DesignSystem.Color.surface
        layer.cornerCurve = .continuous
        pill.backgroundColor = onGlass ? UIColor.label.withAlphaComponent(0.12) : DesignSystem.Color.background
        pill.layer.cornerCurve = .continuous
        if !onGlass {
            pill.layer.shadowColor = UIColor.black.cgColor
            pill.layer.shadowOpacity = 0.12
            pill.layer.shadowRadius = 5
            pill.layer.shadowOffset = CGSize(width: 0, height: 1.5)
        }
        addSubview(pill)
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        for (index, title) in titles.enumerated() {
            let button = UIButton(type: .custom)
            button.setTitle(title, for: .normal)
            button.titleLabel?.font = DesignSystem.Typography.system(15, weight: .semibold)
            button.addAction(UIAction { [weak self] _ in self?.choose(index) }, for: .touchUpInside)
            button.accessibilityLabel = title
            buttons.append(button)
            stack.addArrangedSubview(button)
        }
        refreshColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        placePill()
    }

    /// Re-resolves the titles' fonts after a change of text size.
    func applyFonts() {
        buttons.forEach { $0.titleLabel?.font = DesignSystem.Typography.system(15, weight: .semibold) }
        setNeedsLayout()
    }

    private func placePill() {
        guard selectedIndex < buttons.count else { return }
        let slot = bounds.width / CGFloat(max(buttons.count, 1))
        pill.frame = CGRect(x: slot * CGFloat(selectedIndex), y: 0, width: slot, height: bounds.height)
            .insetBy(dx: 3, dy: 3)
        pill.layer.cornerRadius = pill.bounds.height / 2
    }

    private func refreshColors() {
        for (index, button) in buttons.enumerated() {
            let chosen = index == selectedIndex
            button.setTitleColor(chosen ? DesignSystem.Color.label : DesignSystem.Color.secondaryLabel, for: .normal)
            button.accessibilityTraits = chosen ? [.button, .selected] : .button
        }
    }

    private func choose(_ index: Int) {
        guard index != selectedIndex else { return }
        select(index, animated: true)
        onChange?(index)
    }

    /// Moves the pill to `index`, with a spring when `animated`.
    func select(_ index: Int, animated: Bool) {
        guard index != selectedIndex, index < buttons.count else { return }
        selectedIndex = index
        refreshColors()
        guard animated, window != nil, !UIAccessibility.isReduceMotionEnabled else {
            placePill()
            return
        }
        UIView.animate(withDuration: 0.42, delay: 0, usingSpringWithDamping: 0.82, initialSpringVelocity: 0.4,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.placePill()
        }
    }
}

/// The tab strip as it floats under the navigation bar once the header's own
/// has scrolled away: a glass capsule holding the same three titles.
final class PinnedTabsView: UIVisualEffectView {
    private let strip = ProfileTabStrip(titles: ["Posts", "Replies", "Media"], onGlass: true)

    var onChange: ((Int) -> Void)? {
        get { strip.onChange }
        set { strip.onChange = newValue }
    }

    init() {
        super.init(effect: nil)
        let glass = UIGlassEffect(style: .regular)
        glass.isInteractive = true
        glass.tintColor = DesignSystem.Color.background.withAlphaComponent(0.6)
        effect = glass
        setCapsuleCorners()
        strip.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(strip)
        NSLayoutConstraint.activate([
            strip.topAnchor.constraint(equalTo: contentView.topAnchor),
            strip.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            strip.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
        alpha = 0
        isUserInteractionEnabled = false
        strip.accessibilityLabel = "Timeline mode"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func select(_ index: Int) {
        strip.select(index, animated: true)
    }

    func applyFonts() {
        strip.applyFonts()
    }

    /// Fades the capsule in as `progress` (0 to 1) says the header's strip has
    /// slipped under the bar, rising a few points into place.
    func setProgress(_ progress: CGFloat) {
        let clamped = min(max(progress, 0), 1)
        alpha = clamped
        transform = CGAffineTransform(translationX: 0, y: -8 * (1 - clamped))
        isUserInteractionEnabled = clamped > 0.6
    }
}
