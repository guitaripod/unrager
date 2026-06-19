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
        var showsThread: Bool = false
    }

    /// One tweet's fully-loaded content for a postcard block (root→focal in a
    /// thread).
    struct Entry {
        let tweet: Tweet
        let avatar: UIImage?
        let photos: [UIImage]
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
        static let blockGap: CGFloat = 22
        static let maxPhotos = 2
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

    private var bodyLabels: [UILabel] = []

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

    /// One tweet's vertical column: header, body, media, optional metrics.
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

        if options.showsDisplayName {
            let name = UILabel()
            name.text = tweet.author.name
            name.font = .systemFont(ofSize: 19, weight: .bold)
            name.textColor = theme.text
            name.numberOfLines = 2
            name.lineBreakMode = .byWordWrapping
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
            handle.numberOfLines = 2
            handle.lineBreakMode = .byWordWrapping
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
        let text = TweetText.displayText(for: tweet, stripLeadingMentions: true)
        guard !text.isEmpty else { return nil }
        let label = UILabel()
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.textColor = theme.text
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        let font = UIFont.systemFont(ofSize: 22, weight: .regular)
        let body = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: theme.text,
            .paragraphStyle: paragraph,
        ])
        TwemojiText.substituteCachedEmoji(in: body, font: font)
        label.attributedText = body
        bodyLabels.append(label)
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

    // MARK: - Emoji

    /// Synchronously resolves every Twemoji image the bodies need (awaiting CDN
    /// fetches via a detached task with a bounded wait), then re-substitutes so
    /// the about-to-rasterize labels carry attachments. The postcard renders
    /// once on a user action and is off any scroll path, so the brief wait is
    /// acceptable here — the feed never takes this path. The `TwemojiCache`
    /// fetch actor doesn't hop to the main actor, so blocking main on the
    /// semaphore can't deadlock.
    private func resolveBodyEmoji() {
        let graphemes = Set(entries.flatMap { $0.tweet.text.emojiGraphemes() })
        guard !graphemes.isEmpty else { return }
        let needsFetch = graphemes.contains { TwemojiCache.shared.cachedImage(for: $0) == nil }
        if needsFetch {
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                for grapheme in graphemes {
                    _ = await TwemojiCache.shared.image(for: grapheme)
                }
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 4)
        }
        let font = UIFont.systemFont(ofSize: 22, weight: .regular)
        for label in bodyLabels {
            guard let current = label.attributedText else { continue }
            let mutable = NSMutableAttributedString(attributedString: current)
            TwemojiText.substituteCachedEmoji(in: mutable, font: font)
            label.attributedText = mutable
        }
    }

    // MARK: - Render

    /// Lays out at the fixed render width, then rasterizes to a `UIImage` at the
    /// given scale (use 3 for crisp share output). Resolves the bodies' Twemoji
    /// images first so the exported PNG carries flat Twemoji art (most visibly
    /// flags) rather than the system glyphs.
    func render(scale: CGFloat) -> UIImage {
        resolveBodyEmoji()
        let targetSize = systemLayoutSizeFitting(
            CGSize(width: Self.renderWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel)

        // Host in a throwaway off-screen window so `drawHierarchy` captures only
        // this card. Off-window, `afterScreenUpdates: true` can bleed the live
        // screen behind the sheet (the thread) into the image — which made the
        // export look broken. Added and torn down within this call stack, so the
        // window never actually appears.
        let host = UIWindow(frame: CGRect(origin: .zero, size: targetSize))
        host.windowLevel = UIWindow.Level.normal - 1
        host.backgroundColor = .clear
        host.isHidden = false
        frame = CGRect(origin: .zero, size: targetSize)
        host.addSubview(self)
        setNeedsLayout()
        layoutIfNeeded()

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let image = renderer.image { _ in
            drawHierarchy(in: CGRect(origin: .zero, size: targetSize), afterScreenUpdates: true)
        }
        removeFromSuperview()
        return image
    }
}
