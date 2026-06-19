import AppKit
import UnragerKit

/// A tweet (or thread) rendered as a shareable postcard, mirroring the TUI's
/// `screenshot.rs` look and the iOS `PostcardView`: a vertical accent bar down
/// the left edge, generous padding, one block per entry (avatar + name/handle
/// header, body in a large editorial font, up to two photos, an optional
/// metrics row) stacked under a single continuous accent bar with hairline
/// dividers between blocks, and an `unrager` watermark bottom-right. The view
/// sizes its own height to fit at a fixed render width; `render(scale:)`
/// rasterizes it to a crisp `NSImage`.
///
/// `NSTextField` draws color emoji natively, so — unlike the TUI's `ab_glyph`
/// rasterizer — no emoji compositing is needed here.
final class PostcardView: NSView {
    struct Options {
        var showsDisplayName = true
        var showsMetrics = false
        var showsThread = false
    }

    /// One tweet's fully-loaded content for a postcard block (root→focal in a
    /// thread).
    struct Entry {
        let tweet: Tweet
        let avatar: NSImage?
        let photos: [NSImage]
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

    private let accentBar = NSView()
    private let content = NSStackView()
    private let watermark = NSTextField(labelWithString: "unrager")
    private var bodyLabels: [NSTextField] = []

    /// Renders one block per entry, stacked under a single continuous accent bar
    /// with hairline dividers between blocks — mirroring the TUI's thread
    /// screenshot.
    init(entries: [Entry], theme: PostcardTheme, options: Options) {
        self.theme = theme
        self.options = options
        self.entries = entries
        super.init(frame: NSRect(x: 0, y: 0, width: Self.renderWidth, height: Self.renderWidth))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        build(entries: entries)
    }

    /// Single-tweet convenience — the default, unchanged-behavior path.
    convenience init(tweet: Tweet, theme: PostcardTheme, options: Options, avatar: NSImage?, photos: [NSImage]) {
        self.init(entries: [Entry(tweet: tweet, avatar: avatar, photos: photos)], theme: theme, options: options)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Top-origin layout so the postcard stacks downward like the iOS view.
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        applyBackground()
    }

    // MARK: - Build

    private func build(entries: [Entry]) {
        accentBar.wantsLayer = true
        accentBar.layer?.backgroundColor = theme.accent.cgColor
        accentBar.layer?.cornerRadius = Metrics.accentBarWidth / 2
        accentBar.layer?.cornerCurve = .continuous
        addManaged(accentBar)

        content.orientation = .vertical
        content.spacing = 0
        content.alignment = .leading
        content.distribution = .fill
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

        watermark.font = .systemFont(ofSize: 15, weight: .semibold)
        watermark.textColor = theme.accent.withAlphaComponent(0.55)
        watermark.alignment = .right
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
        guard let layer else { return }
        if let end = theme.backgroundEnd {
            let gradient: CAGradientLayer
            if let existing = layer.sublayers?.first(where: { $0 is CAGradientLayer }) as? CAGradientLayer {
                gradient = existing
            } else {
                gradient = CAGradientLayer()
                layer.insertSublayer(gradient, at: 0)
            }
            gradient.frame = bounds
            gradient.colors = [theme.background.cgColor, end.cgColor]
            gradient.startPoint = CGPoint(x: 0.5, y: 0)
            gradient.endPoint = CGPoint(x: 0.5, y: 1)
        } else {
            layer.backgroundColor = theme.background.cgColor
        }
    }

    /// One tweet's vertical column: header, body, media, optional metrics.
    private func makeBlock(entry: Entry) -> NSView {
        let block = NSStackView()
        block.orientation = .vertical
        block.spacing = 0
        block.alignment = .leading
        block.distribution = .fill
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
        pinWidth(block)
        return block
    }

    /// A hairline between thread blocks; spans the text column (the accent bar
    /// runs unbroken to its left), echoing the TUI's `paint_block_divider`.
    private func makeDivider() -> NSView {
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = theme.secondaryText.withAlphaComponent(0.3).cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        pinWidth(divider)
        return divider
    }

    /// Forces an arranged subview to span the content column's width — AppKit's
    /// `.leading` alignment otherwise sizes rows to their intrinsic width.
    private func pinWidth(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
    }

    // MARK: - Header

    private func makeHeader(tweet: Tweet, avatar: NSImage?) -> NSView {
        let avatarView = makeAvatar(avatar)

        let nameRow = NSStackView()
        nameRow.orientation = .horizontal
        nameRow.spacing = 5
        nameRow.alignment = .centerY

        let primary = NSTextField(labelWithString: options.showsDisplayName ? tweet.author.name : "@\(tweet.author.handle)")
        primary.font = .systemFont(ofSize: 19, weight: .bold)
        primary.textColor = theme.text
        primary.lineBreakMode = .byTruncatingTail
        primary.maximumNumberOfLines = 1
        primary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameRow.addArrangedSubview(primary)
        if tweet.author.verified {
            nameRow.addArrangedSubview(makeVerifiedBadge())
        }

        let subtitle = NSTextField(labelWithString: "")
        subtitle.font = .systemFont(ofSize: 15, weight: .regular)
        subtitle.textColor = theme.secondaryText
        subtitle.maximumNumberOfLines = 1
        subtitle.lineBreakMode = .byTruncatingTail
        let timestamp = Format.absoluteTime(tweet.createdAt)
        subtitle.stringValue = options.showsDisplayName ? "@\(tweet.author.handle) · \(timestamp)" : timestamp

        let textColumn = NSStackView(views: [nameRow, subtitle])
        textColumn.orientation = .vertical
        textColumn.spacing = 3
        textColumn.alignment = .leading

        let header = NSStackView(views: [avatarView, textColumn])
        header.orientation = .horizontal
        header.spacing = Metrics.headerGap
        header.alignment = .centerY

        NSLayoutConstraint.activate([
            avatarView.widthAnchor.constraint(equalToConstant: Metrics.avatarSize),
            avatarView.heightAnchor.constraint(equalToConstant: Metrics.avatarSize),
        ])
        return header
    }

    private func makeAvatar(_ image: NSImage?) -> NSView {
        let view = NSImageView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        view.layer?.cornerRadius = Metrics.avatarSize / 2
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        view.imageScaling = .scaleProportionallyUpOrDown
        view.layer?.contentsGravity = .resizeAspectFill
        if let image {
            view.image = image
        } else {
            view.layer?.backgroundColor = theme.accent.withAlphaComponent(0.22).cgColor
            let glyph = NSImageView(image: DesignSystem.icon("person.fill", pointSize: 24, weight: .semibold)?
                .tintedImage(theme.accent) ?? NSImage())
            glyph.imageScaling = .scaleNone
            glyph.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(glyph)
            NSLayoutConstraint.activate([
                glyph.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                glyph.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            ])
        }
        return view
    }

    private func makeVerifiedBadge() -> NSImageView {
        let badge = NSImageView(image: DesignSystem.icon("checkmark.seal.fill", pointSize: 15, weight: .semibold)?
            .tintedImage(theme.accent) ?? NSImage())
        badge.imageScaling = .scaleNone
        badge.setContentHuggingPriority(.required, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        return badge
    }

    // MARK: - Body

    private func makeBody(tweet: Tweet) -> NSView? {
        guard !tweet.text.isEmpty else { return nil }
        let label = NSTextField(wrappingLabelWithString: "")
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        label.isBezeled = false
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        let font = NSFont.systemFont(ofSize: 22, weight: .regular)
        let body = NSMutableAttributedString(string: tweet.text, attributes: [
            .font: font,
            .foregroundColor: theme.text,
            .paragraphStyle: paragraph,
        ])
        TwemojiText.substituteCachedEmoji(in: body, font: font)
        label.attributedStringValue = body
        bodyLabels.append(label)
        return label
    }

    // MARK: - Media

    private func makeMedia(photos: [NSImage]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = Metrics.mediaSpacing
        stack.alignment = .leading
        stack.distribution = .fill
        for photo in photos {
            let view = makePhoto(photo)
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func makePhoto(_ photo: NSImage) -> NSView {
        let view = NSImageView(image: photo)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        view.layer?.cornerRadius = Metrics.mediaCorner
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        view.imageScaling = .scaleProportionallyUpOrDown
        view.layer?.contentsGravity = .resizeAspectFill
        let ratio = photo.size.height > 0 ? photo.size.width / photo.size.height : 16.0 / 9.0
        let clamped = min(max(ratio, 0.6), 2.0)
        view.heightAnchor.constraint(equalTo: view.widthAnchor, multiplier: 1 / clamped).isActive = true
        return view
    }

    // MARK: - Metrics

    private func makeMetrics(tweet: Tweet) -> NSView? {
        var entries: [(String, String)] = [
            ("bubble.left", Format.count(tweet.replyCount)),
            ("arrow.2.squarepath", Format.count(tweet.retweetCount)),
            ("heart", Format.count(tweet.likeCount)),
        ]
        if let views = tweet.viewCount {
            entries.append(("chart.bar", Format.count(views)))
        }
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 18
        stack.alignment = .centerY
        for (symbol, value) in entries {
            stack.addArrangedSubview(makeMetric(symbol: symbol, value: value))
        }
        return stack
    }

    private func makeMetric(symbol: String, value: String) -> NSView {
        let icon = NSImageView(image: DesignSystem.icon(symbol, pointSize: 14, weight: .regular)?
            .tintedImage(theme.secondaryText) ?? NSImage())
        icon.imageScaling = .scaleNone
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let label = NSTextField(labelWithString: value)
        label.font = .systemFont(ofSize: 15, weight: .regular)
        label.textColor = theme.secondaryText
        let row = NSStackView(views: [icon, label])
        row.orientation = .horizontal
        row.spacing = 5
        row.alignment = .centerY
        return row
    }

    // MARK: - Emoji

    /// Synchronously resolves every Twemoji image the bodies need (awaiting CDN
    /// fetches via a detached task with a bounded wait), then re-substitutes so
    /// the about-to-rasterize labels carry attachments. The postcard renders
    /// once on a user action and is off any scroll path, so the brief wait is
    /// acceptable here. The `TwemojiCache` fetch actor doesn't hop to the main
    /// actor, so blocking main on the semaphore can't deadlock.
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
        let font = NSFont.systemFont(ofSize: 22, weight: .regular)
        for label in bodyLabels {
            let mutable = NSMutableAttributedString(attributedString: label.attributedStringValue)
            TwemojiText.substituteCachedEmoji(in: mutable, font: font)
            label.attributedStringValue = mutable
        }
    }

    // MARK: - Render

    /// Lays out at the fixed render width, then rasterizes to an `NSImage` at the
    /// given scale (use 3 for crisp share output) via an offscreen bitmap rep
    /// whose pixel dimensions are the logical size times `scale`. Resolves the
    /// bodies' Twemoji images first so the exported PNG carries flat Twemoji art.
    func render(scale: CGFloat) -> NSImage {
        resolveBodyEmoji()
        let fitting = fittingSize
        let targetSize = NSSize(width: Self.renderWidth, height: max(fitting.height, Self.renderWidth * 0.4))
        frame = NSRect(origin: .zero, size: targetSize)
        layoutSubtreeIfNeeded()
        applyBackground()

        let pixelWidth = Int((targetSize.width * scale).rounded())
        let pixelHeight = Int((targetSize.height * scale).rounded())
        guard pixelWidth > 0, pixelHeight > 0,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixelWidth, pixelsHigh: pixelHeight,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            return NSImage(size: targetSize)
        }
        rep.size = targetSize
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
            return NSImage(size: targetSize)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        displayIgnoringOpacity(bounds, in: context)
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: targetSize)
        image.addRepresentation(rep)
        return image
    }
}

extension NSImage {
    /// Returns a copy of the (template) symbol image painted in a solid color.
    func tintedImage(_ color: NSColor) -> NSImage {
        let result = NSImage(size: size)
        result.lockFocus()
        color.set()
        let rect = NSRect(origin: .zero, size: size)
        draw(in: rect)
        rect.fill(using: .sourceAtop)
        result.unlockFocus()
        result.isTemplate = false
        return result
    }
}
