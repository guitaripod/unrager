import UIKit
import UnragerKit

/// A single tweet rendered as a shareable postcard, mirroring the TUI's
/// `screenshot.rs` look: a vertical accent bar down the left edge, generous
/// padding, an avatar + name/handle header, the body in a large editorial
/// font, photo media in a grid, an inset quoted tweet, an optional metrics
/// row, and an `unrager` watermark bottom-right. The view sizes its own height
/// to fit its content at a fixed render width; `render(scale:)` rasterizes it
/// to a crisp `UIImage`.
final class PostcardView: UIView {
    struct Options {
        var showsDisplayName: Bool = true
        var showsMetrics: Bool = false
        var showsThread: Bool = false
    }

    /// One tweet's fully-loaded content for a postcard block (root→focal in a
    /// thread).
    struct Entry {
        let tweet: Tweet
        let avatar: UIImage?
        let photos: [UIImage]
        var quotedPhotos: [UIImage] = []
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
        static let mediaSpacing: CGFloat = 8
        static let quoteGap: CGFloat = 18
        static let quotePadding: CGFloat = 14
        static let metricsGap: CGFloat = 20
        static let watermarkGap: CGFloat = 22
        static let mediaCorner: CGFloat = 16
        static let blockGap: CGFloat = 22
        static let maxPhotos = 4
        static let maxQuotePhotos = 2
    }

    private let theme: PostcardTheme
    private let options: Options
    private let entries: [Entry]

    private let accentBar = UIView()
    private let content = UIStackView()
    private let gradientLayer = CAGradientLayer()
    private let watermark = UILabel()

    /// Renders one block per entry, stacked under a single continuous accent bar
    /// with hairline dividers between blocks — mirroring the TUI's thread
    /// screenshot.
    init(entries: [Entry], theme: PostcardTheme, options: Options) {
        self.theme = theme
        self.options = options
        self.entries = entries
        super.init(frame: CGRect(x: 0, y: 0, width: Self.renderWidth, height: Self.renderWidth))
        translatesAutoresizingMaskIntoConstraints = false
        build(entries: entries)
    }

    /// Single-tweet convenience — the default, unchanged-behavior path.
    ///
    /// - Parameters:
    ///   - avatar: the fully-loaded author avatar, or nil to draw a placeholder.
    ///   - photos: fully-loaded photo (or video poster) images, top-to-bottom.
    convenience init(tweet: Tweet, theme: PostcardTheme, options: Options, avatar: UIImage?, photos: [UIImage]) {
        self.init(entries: [Entry(tweet: tweet, avatar: avatar, photos: photos)], theme: theme, options: options)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradientLayer.frame = bounds
    }

    // MARK: - Build

    private func build(entries: [Entry]) {
        applyBackground()

        accentBar.backgroundColor = theme.accent
        accentBar.layer.cornerRadius = Metrics.accentBarWidth / 2
        accentBar.layer.cornerCurve = .continuous
        addManaged(accentBar)

        content.axis = .vertical
        content.spacing = 0
        content.alignment = .fill
        addManaged(content)

        for (index, entry) in entries.enumerated() {
            if index > 0, let last = content.arrangedSubviews.last {
                content.setCustomSpacing(Metrics.blockGap, after: last)
                let divider = makeDivider()
                content.addArrangedSubview(divider)
                content.setCustomSpacing(Metrics.blockGap, after: divider)
            }
            content.addArrangedSubview(makeBlock(entry: entry))
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

    /// One tweet's vertical column: header, body, media, quoted tweet, optional
    /// metrics.
    private func makeBlock(entry: Entry) -> UIView {
        let block = UIStackView()
        block.axis = .vertical
        block.spacing = 0
        block.alignment = .fill
        block.addArrangedSubview(makeHeader(tweet: entry.tweet, avatar: entry.avatar))
        if let body = makeBody(tweet: entry.tweet) {
            block.setCustomSpacing(Metrics.bodyGap, after: block.arrangedSubviews.last!)
            block.addArrangedSubview(body)
        }
        if !entry.photos.isEmpty {
            block.setCustomSpacing(Metrics.mediaGap, after: block.arrangedSubviews.last!)
            block.addArrangedSubview(makeMedia(photos: Array(entry.photos.prefix(Metrics.maxPhotos))))
        }
        if let quoted = entry.tweet.quotedTweet {
            block.setCustomSpacing(Metrics.quoteGap, after: block.arrangedSubviews.last!)
            block.addArrangedSubview(makeQuote(tweet: quoted, photos: entry.quotedPhotos))
        }
        if options.showsMetrics, let metrics = makeMetrics(tweet: entry.tweet) {
            block.setCustomSpacing(Metrics.metricsGap, after: block.arrangedSubviews.last!)
            block.addArrangedSubview(metrics)
        }
        return block
    }

    /// A hairline between thread blocks; spans only the text column (the accent
    /// bar runs unbroken to its left), echoing the TUI's `paint_block_divider`.
    private func makeDivider() -> UIView {
        let divider = UIView()
        divider.backgroundColor = theme.secondaryText.withAlphaComponent(0.3)
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return divider
    }

    // MARK: - Header

    private func makeHeader(tweet: Tweet, avatar: UIImage?) -> UIView {
        let avatarView = makeAvatar(avatar, accent: theme.accent)

        let nameRow = UIStackView()
        nameRow.axis = .horizontal
        nameRow.spacing = 5
        nameRow.alignment = .center

        let title = UILabel()
        title.text = options.showsDisplayName ? tweet.author.name : "@\(tweet.author.handle)"
        title.font = .systemFont(ofSize: 19, weight: .bold)
        title.textColor = theme.text
        title.numberOfLines = 2
        title.lineBreakMode = .byWordWrapping
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameRow.addArrangedSubview(title)
        if tweet.author.verified {
            nameRow.addArrangedSubview(makeVerifiedBadge())
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
        let text = TweetText.displayText(for: tweet, stripLeadingMentions: true)
        return makeTextLabel(text, size: 22, lineSpacing: 4)
    }

    private func makeTextLabel(_ text: String, size: CGFloat, lineSpacing: CGFloat) -> UILabel? {
        guard !text.isEmpty else { return nil }
        let label = UILabel()
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.textColor = theme.text
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        let font = UIFont.systemFont(ofSize: size, weight: .regular)
        let body = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: theme.text,
            .paragraphStyle: paragraph,
        ])
        TwemojiText.substituteCachedEmoji(in: body, font: font)
        label.attributedText = body
        return label
    }

    // MARK: - Media

    /// A photo grid mirroring X's layouts: one photo keeps its own aspect,
    /// two sit side by side, three put the first full-width above a pair, and
    /// four form a 2×2 grid. Grid cells crop to a uniform aspect so rows stay
    /// level.
    private func makeMedia(photos: [UIImage]) -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = Metrics.mediaSpacing
        stack.alignment = .fill
        switch photos.count {
        case 1:
            stack.addArrangedSubview(makePhoto(photos[0]))
        case 2:
            stack.addArrangedSubview(makePhotoRow([photos[0], photos[1]], aspect: 1.0))
        case 3:
            stack.addArrangedSubview(makePhoto(photos[0]))
            stack.addArrangedSubview(makePhotoRow([photos[1], photos[2]], aspect: 16.0 / 9.0))
        default:
            stack.addArrangedSubview(makePhotoRow([photos[0], photos[1]], aspect: 4.0 / 3.0))
            stack.addArrangedSubview(makePhotoRow([photos[2], photos[3]], aspect: 4.0 / 3.0))
        }
        return stack
    }

    private func makePhotoRow(_ photos: [UIImage], aspect: CGFloat) -> UIView {
        let row = UIStackView(arrangedSubviews: photos.map { makePhotoCell($0, aspect: aspect) })
        row.axis = .horizontal
        row.spacing = Metrics.mediaSpacing
        row.distribution = .fillEqually
        return row
    }

    private func makePhotoCell(_ photo: UIImage, aspect: CGFloat) -> UIView {
        let view = makePhotoView(photo)
        view.heightAnchor.constraint(equalTo: view.widthAnchor, multiplier: 1 / aspect).isActive = true
        return view
    }

    private func makePhoto(_ photo: UIImage) -> UIView {
        let view = makePhotoView(photo)
        let ratio = photo.size.height > 0 ? photo.size.width / photo.size.height : 16.0 / 9.0
        let clamped = min(max(ratio, 0.6), 2.0)
        view.heightAnchor.constraint(equalTo: view.widthAnchor, multiplier: 1 / clamped).isActive = true
        return view
    }

    private func makePhotoView(_ photo: UIImage) -> UIImageView {
        let view = UIImageView(image: photo)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.clipsToBounds = true
        view.contentMode = .scaleAspectFill
        view.layer.cornerRadius = Metrics.mediaCorner
        view.layer.cornerCurve = .continuous
        return view
    }

    // MARK: - Quote

    /// The quoted tweet as an inset, outlined card: a compact author line,
    /// smaller body text, and up to two photos.
    private func makeQuote(tweet: Tweet, photos: [UIImage]) -> UIView {
        let column = UIStackView()
        column.axis = .vertical
        column.spacing = 0
        column.alignment = .fill
        column.isLayoutMarginsRelativeArrangement = true
        column.layoutMargins = UIEdgeInsets(
            top: Metrics.quotePadding, left: Metrics.quotePadding,
            bottom: Metrics.quotePadding, right: Metrics.quotePadding)

        let author = UILabel()
        let name = NSMutableAttributedString(
            string: tweet.author.name,
            attributes: [
                .font: UIFont.systemFont(ofSize: 15, weight: .semibold),
                .foregroundColor: theme.text,
            ])
        name.append(NSAttributedString(
            string: "  @\(tweet.author.handle)",
            attributes: [
                .font: UIFont.systemFont(ofSize: 14, weight: .regular),
                .foregroundColor: theme.secondaryText,
            ]))
        author.attributedText = name
        author.numberOfLines = 1
        column.addArrangedSubview(author)

        let text = TweetText.displayText(for: tweet, stripLeadingMentions: true)
        if let body = makeTextLabel(text, size: 17, lineSpacing: 3) {
            column.setCustomSpacing(8, after: author)
            column.addArrangedSubview(body)
        }
        if !photos.isEmpty, let last = column.arrangedSubviews.last {
            column.setCustomSpacing(12, after: last)
            column.addArrangedSubview(makeMedia(photos: Array(photos.prefix(Metrics.maxQuotePhotos))))
        }

        let card = UIView()
        card.layer.cornerRadius = 14
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = theme.secondaryText.withAlphaComponent(0.35).cgColor
        card.backgroundColor = theme.text.withAlphaComponent(0.04)
        card.addManaged(column)
        column.pinEdges(to: card)
        return card
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

    // MARK: - Emoji

    /// Awaits every Twemoji image the entries' bodies (and quoted bodies) need,
    /// so a `PostcardView` built afterwards substitutes them all as cache hits
    /// and both the preview and the export carry flat Twemoji art. Misses that
    /// can't be fetched (offline) simply keep the native glyph.
    @MainActor
    static func prefetchEmoji(entries: [Entry]) async {
        var graphemes: Set<String> = []
        for entry in entries {
            graphemes.formUnion(entry.tweet.text.emojiGraphemes())
            if let quoted = entry.tweet.quotedTweet {
                graphemes.formUnion(quoted.text.emojiGraphemes())
            }
        }
        for grapheme in graphemes {
            _ = await TwemojiCache.shared.image(for: grapheme)
        }
    }

    // MARK: - Render

    /// Lays out at the fixed render width, then rasterizes to a `UIImage` at
    /// the given scale (use 3 for crisp share output) via `layer.render(in:)` —
    /// fully deterministic and window-free, so nothing behind the sheet can
    /// bleed in and text draws exactly as laid out. Call
    /// `prefetchEmoji(entries:)` before constructing the view so the exported
    /// PNG carries flat Twemoji art rather than the system glyphs.
    func render(scale: CGFloat) -> UIImage {
        translatesAutoresizingMaskIntoConstraints = true
        let targetSize = systemLayoutSizeFitting(
            CGSize(width: Self.renderWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel)
        frame = CGRect(origin: .zero, size: targetSize)
        setNeedsLayout()
        layoutIfNeeded()

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { context in
            layer.render(in: context.cgContext)
        }
    }
}
