import UIKit
import UnragerKit

/// A single tweet rendered as a shareable postcard, mirroring the TUI's
/// `screenshot.rs` look: a vertical accent bar down the left edge, generous
/// padding, an avatar + name/handle header, the body in a large editorial
/// font, optional photo media, an optional metrics row, and an `unrager`
/// watermark bottom-right. The view sizes its own height to fit its content at
/// a fixed render width; `render(scale:)` rasterizes it to a crisp `UIImage`.
///
/// `UILabel`/`UITextView` draw color emoji natively, so — unlike the TUI's
/// `ab_glyph` rasterizer — no emoji compositing is needed here.
final class PostcardView: UIView {
    struct Options {
        var showsDisplayName: Bool = true
        var showsMetrics: Bool = false
    }

    /// Logical render width. At scale 3 this yields a ~1620px-wide PNG —
    /// retina-crisp and share-ready.
    static let renderWidth: CGFloat = 540

    private enum Metrics {
        static let padding: CGFloat = 28
        static let accentBarWidth: CGFloat = 5
        static let accentBarGap: CGFloat = 18
        static let avatarSize: CGFloat = 52
        static let headerGap: CGFloat = 14
        static let bodyGap: CGFloat = 20
        static let mediaGap: CGFloat = 18
        static let mediaSpacing: CGFloat = 10
        static let metricsGap: CGFloat = 20
        static let watermarkGap: CGFloat = 22
        static let mediaCorner: CGFloat = 16
        static let maxPhotos = 2
    }

    private let theme: PostcardTheme
    private let options: Options

    private let accentBar = UIView()
    private let content = UIStackView()
    private let gradientLayer = CAGradientLayer()
    private let watermark = UILabel()

    /// - Parameters:
    ///   - avatar: the fully-loaded author avatar, or nil to draw a placeholder.
    ///   - photos: fully-loaded photo (or video poster) images, top-to-bottom.
    init(tweet: Tweet, theme: PostcardTheme, options: Options, avatar: UIImage?, photos: [UIImage]) {
        self.theme = theme
        self.options = options
        super.init(frame: CGRect(x: 0, y: 0, width: Self.renderWidth, height: Self.renderWidth))
        translatesAutoresizingMaskIntoConstraints = false
        build(tweet: tweet, avatar: avatar, photos: photos)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradientLayer.frame = bounds
    }

    // MARK: - Build

    private func build(tweet: Tweet, avatar: UIImage?, photos: [UIImage]) {
        applyBackground()

        accentBar.backgroundColor = theme.accent
        accentBar.layer.cornerRadius = Metrics.accentBarWidth / 2
        accentBar.layer.cornerCurve = .continuous
        addManaged(accentBar)

        content.axis = .vertical
        content.spacing = 0
        content.alignment = .fill
        addManaged(content)

        content.addArrangedSubview(makeHeader(tweet: tweet, avatar: avatar))
        if let body = makeBody(tweet: tweet) {
            content.setCustomSpacing(Metrics.bodyGap, after: content.arrangedSubviews.last!)
            content.addArrangedSubview(body)
        }
        if !photos.isEmpty {
            content.setCustomSpacing(Metrics.mediaGap, after: content.arrangedSubviews.last!)
            content.addArrangedSubview(makeMedia(photos: Array(photos.prefix(Metrics.maxPhotos))))
        }
        if options.showsMetrics, let metrics = makeMetrics(tweet: tweet) {
            content.setCustomSpacing(Metrics.metricsGap, after: content.arrangedSubviews.last!)
            content.addArrangedSubview(metrics)
        }

        watermark.text = "unrager"
        watermark.font = .systemFont(ofSize: 15, weight: .semibold)
        watermark.textColor = theme.accent.withAlphaComponent(0.55)
        watermark.textAlignment = .right
        addManaged(watermark)

        let leadingInset = Metrics.padding + Metrics.accentBarWidth + Metrics.accentBarGap
        NSLayoutConstraint.activate([
            accentBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.padding),
            accentBar.topAnchor.constraint(equalTo: content.topAnchor),
            accentBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            accentBar.widthAnchor.constraint(equalToConstant: Metrics.accentBarWidth),

            content.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.padding),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leadingInset),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.padding),

            watermark.topAnchor.constraint(equalTo: content.bottomAnchor, constant: Metrics.watermarkGap),
            watermark.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.padding),
            watermark.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metrics.padding),
        ])
    }

    private func applyBackground() {
        if let end = theme.backgroundEnd {
            gradientLayer.colors = [theme.background.cgColor, end.cgColor]
            gradientLayer.startPoint = CGPoint(x: 0.5, y: 0)
            gradientLayer.endPoint = CGPoint(x: 0.5, y: 1)
            layer.insertSublayer(gradientLayer, at: 0)
            backgroundColor = theme.background
        } else {
            backgroundColor = theme.background
        }
    }

    // MARK: - Header

    private func makeHeader(tweet: Tweet, avatar: UIImage?) -> UIView {
        let avatarView = makeAvatar(avatar, accent: theme.accent)

        let nameRow = UIStackView()
        nameRow.axis = .horizontal
        nameRow.spacing = 5
        nameRow.alignment = .center

        if options.showsDisplayName {
            let name = UILabel()
            name.text = tweet.author.name
            name.font = .systemFont(ofSize: 19, weight: .bold)
            name.textColor = theme.text
            name.numberOfLines = 1
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            nameRow.addArrangedSubview(name)
            if tweet.author.verified {
                nameRow.addArrangedSubview(makeVerifiedBadge())
            }
        } else {
            let handle = UILabel()
            handle.text = "@\(tweet.author.handle)"
            handle.font = .systemFont(ofSize: 19, weight: .bold)
            handle.textColor = theme.text
            handle.numberOfLines = 1
            handle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            nameRow.addArrangedSubview(handle)
            if tweet.author.verified {
                nameRow.addArrangedSubview(makeVerifiedBadge())
            }
        }
        nameRow.addArrangedSubview(UIView())

        let subtitle = UILabel()
        subtitle.font = .systemFont(ofSize: 15, weight: .regular)
        subtitle.textColor = theme.secondaryText
        subtitle.numberOfLines = 1
        let timestamp = Format.absoluteTime(tweet.createdAt)
        subtitle.text = options.showsDisplayName ? "@\(tweet.author.handle) · \(timestamp)" : timestamp

        let textColumn = UIStackView(arrangedSubviews: [nameRow, subtitle])
        textColumn.axis = .vertical
        textColumn.spacing = 3
        textColumn.alignment = .leading

        let header = UIStackView(arrangedSubviews: [avatarView, textColumn])
        header.axis = .horizontal
        header.spacing = Metrics.headerGap
        header.alignment = .center

        NSLayoutConstraint.activate([
            avatarView.widthAnchor.constraint(equalToConstant: Metrics.avatarSize),
            avatarView.heightAnchor.constraint(equalToConstant: Metrics.avatarSize),
        ])
        return header
    }

    private func makeAvatar(_ image: UIImage?, accent: UIColor) -> UIView {
        let view = UIImageView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.clipsToBounds = true
        view.contentMode = .scaleAspectFill
        view.layer.cornerRadius = Metrics.avatarSize / 2
        view.layer.cornerCurve = .continuous
        if let image {
            view.image = image
        } else {
            view.backgroundColor = accent.withAlphaComponent(0.22)
            let glyph = UIImageView(image: DesignSystem.icon("person.fill", pointSize: 24, weight: .semibold))
            glyph.translatesAutoresizingMaskIntoConstraints = false
            glyph.tintColor = accent
            glyph.contentMode = .center
            view.addSubview(glyph)
            glyph.pinEdges(to: view)
        }
        return view
    }

    private func makeVerifiedBadge() -> UIImageView {
        let badge = UIImageView(image: DesignSystem.icon("checkmark.seal.fill", pointSize: 15, weight: .semibold))
        badge.tintColor = theme.accent
        badge.setContentHuggingPriority(.required, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        return badge
    }

    // MARK: - Body

    private func makeBody(tweet: Tweet) -> UIView? {
        let text = tweet.text
        guard !text.isEmpty else { return nil }
        let label = UILabel()
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.textColor = theme.text
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        label.attributedText = NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: 22, weight: .regular),
            .foregroundColor: theme.text,
            .paragraphStyle: paragraph,
        ])
        return label
    }

    // MARK: - Media

    private func makeMedia(photos: [UIImage]) -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = Metrics.mediaSpacing
        stack.alignment = .fill
        for photo in photos {
            stack.addArrangedSubview(makePhoto(photo))
        }
        return stack
    }

    private func makePhoto(_ photo: UIImage) -> UIView {
        let view = UIImageView(image: photo)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.clipsToBounds = true
        view.contentMode = .scaleAspectFill
        view.layer.cornerRadius = Metrics.mediaCorner
        view.layer.cornerCurve = .continuous
        let ratio = photo.size.height > 0 ? photo.size.width / photo.size.height : 16.0 / 9.0
        let clamped = min(max(ratio, 0.6), 2.0)
        view.heightAnchor.constraint(equalTo: view.widthAnchor, multiplier: 1 / clamped).isActive = true
        return view
    }

    // MARK: - Metrics

    private func makeMetrics(tweet: Tweet) -> UIView? {
        var entries: [(String, String)] = [
            ("bubble.left", Format.count(tweet.replyCount)),
            ("arrow.2.squarepath", Format.count(tweet.retweetCount)),
            ("heart", Format.count(tweet.likeCount)),
        ]
        if let views = tweet.viewCount {
            entries.append(("chart.bar", Format.count(views)))
        }
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 18
        stack.alignment = .center
        for (symbol, value) in entries {
            stack.addArrangedSubview(makeMetric(symbol: symbol, value: value))
        }
        stack.addArrangedSubview(UIView())
        return stack
    }

    private func makeMetric(symbol: String, value: String) -> UIView {
        let icon = UIImageView(image: DesignSystem.icon(symbol, pointSize: 14, weight: .regular))
        icon.tintColor = theme.secondaryText
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let label = UILabel()
        label.text = value
        label.font = .systemFont(ofSize: 15, weight: .regular)
        label.textColor = theme.secondaryText
        let row = UIStackView(arrangedSubviews: [icon, label])
        row.axis = .horizontal
        row.spacing = 5
        row.alignment = .center
        return row
    }

    // MARK: - Render

    /// Lays out at the fixed render width, then rasterizes to a `UIImage` at the
    /// given scale (use 3 for crisp share output).
    func render(scale: CGFloat) -> UIImage {
        let targetSize = systemLayoutSizeFitting(
            CGSize(width: Self.renderWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel)
        frame = CGRect(origin: .zero, size: targetSize)
        layoutIfNeeded()

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { _ in
            drawHierarchy(in: CGRect(origin: .zero, size: targetSize), afterScreenUpdates: true)
        }
    }
}
