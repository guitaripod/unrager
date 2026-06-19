import AppKit
import UnragerKit

/// The leading nesting guides for a thread reply: one rounded vertical rail per
/// depth level, so a reply-to-a-reply shows two aligned rails where a
/// reply-to-the-root shows one — consecutive same-depth replies share rail
/// positions and read as continuous thread lines.
final class ThreadRailView: NSView {
    static let step: CGFloat = 16

    var level = 0 {
        didSet { if level != oldValue { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard level > 0 else { return }
        DesignSystem.Color.separator.setStroke()
        for index in 0..<level {
            let x = CGFloat(index) * Self.step + Self.step / 2
            let path = NSBezierPath()
            path.lineWidth = 2
            path.lineCapStyle = .round
            path.move(to: NSPoint(x: x, y: 3))
            path.line(to: NSPoint(x: x, y: bounds.height - 3))
            path.stroke()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// A view-based table cell rendering one tweet card: avatar, header (name +
/// verified + handle · time), body, optional rich media, an optional
/// quoted-tweet block (avatar + body + media thumbnail), and an action row with
/// reply / retweet / like / views counts. Mirrors the iOS layout and tokens.
final class TweetRowView: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("TweetRowView")

    var onTapAuthor: (() -> Void)?
    var onTapPhoto: ((Int) -> Void)?
    var onTapVideo: (() -> Void)?
    var onTapPoll: (() -> Void)?
    var onTapQuoted: (() -> Void)?
    var onLike: (() -> Void)?
    var onReply: (() -> Void)?

    private let avatar = AsyncImageView()
    private let nameLabel = TweetRowView.label(font: DesignSystem.Typography.name(), color: DesignSystem.Color.label)
    private let verifiedBadge = NSImageView()
    private let handleTimeLabel = TweetRowView.label(font: DesignSystem.Typography.handle(), color: DesignSystem.Color.secondaryLabel)
    private let replyingLabel = TweetRowView.label(font: DesignSystem.Typography.metric(), color: DesignSystem.Color.secondaryLabel)
    private let replyingIcon = NSImageView()
    private let replyingRow = NSStackView()
    private let bodyLabel = TweetRowView.wrappingLabel(font: DesignSystem.Typography.body(), color: DesignSystem.Color.label)
    private let analyticsView = TweetAnalyticsView()

    private let mediaView = TweetMediaView()

    private let quotedContainer = NSView()
    private let quotedAvatar = AsyncImageView()
    private let quotedAuthorLabel = TweetRowView.label(font: DesignSystem.Typography.handle(), color: DesignSystem.Color.secondaryLabel)
    private let quotedBodyLabel = TweetRowView.wrappingLabel(font: DesignSystem.Typography.metric(), color: DesignSystem.Color.label)
    private let quotedThumb = AsyncImageView()
    private var quotedThumbHeight: NSLayoutConstraint!

    private let replyButton = TweetRowView.actionButton(symbol: "bubble.left")
    private let retweetButton = TweetRowView.actionButton(symbol: "arrow.2.squarepath")
    private let likeButton = TweetRowView.actionButton(symbol: "heart")
    private let viewsButton = TweetRowView.actionButton(symbol: "chart.bar")

    private let separator = NSBox()
    private let threadRail = ThreadRailView()
    private var avatarLeading: NSLayoutConstraint!
    private var railWidth: NSLayoutConstraint!
    private var contentWidth: CGFloat = 560
    private let api = AppEnvironment.shared.api

    private static let maxIndent = 3

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    private func build() {
        wantsLayer = true

        avatar.setRounded(DesignSystem.Radius.avatar)
        avatar.setFill()
        let avatarTap = NSClickGestureRecognizer(target: self, action: #selector(authorTapped))
        avatar.addGestureRecognizer(avatarTap)
        avatar.setAccessibilityRole(.button)

        verifiedBadge.image = DesignSystem.icon("checkmark.seal.fill", pointSize: 13)
        verifiedBadge.contentTintColor = DesignSystem.Color.verified
        verifiedBadge.setContentHuggingPriority(.required, for: .horizontal)
        verifiedBadge.setContentCompressionResistancePriority(.required, for: .horizontal)
        verifiedBadge.setAccessibilityLabel("Verified")

        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.lineBreakMode = .byTruncatingTail
        handleTimeLabel.lineBreakMode = .byTruncatingTail
        handleTimeLabel.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)

        let header = NSStackView(views: [nameLabel, verifiedBadge, handleTimeLabel])
        header.orientation = .horizontal
        header.spacing = DesignSystem.Spacing.xs
        header.alignment = .firstBaseline
        header.distribution = .fill
        let headerSpacer = NSView()
        header.addArrangedSubview(headerSpacer)
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        buildReplyingRow()

        mediaView.onTapPhoto = { [weak self] index in self?.onTapPhoto?(index) }
        mediaView.onTapVideo = { [weak self] in self?.onTapVideo?() }
        mediaView.onTapPoll = { [weak self] in self?.onTapPoll?() }
        mediaView.onOpenURL = { url in NSWorkspace.shared.open(url) }
        mediaView.setContentHuggingPriority(.defaultLow, for: .vertical)

        buildQuoted()

        let actionBar = NSStackView(views: [replyButton, retweetButton, likeButton, viewsButton])
        actionBar.orientation = .horizontal
        actionBar.distribution = .fillEqually
        actionBar.alignment = .centerY
        likeButton.target = self
        likeButton.action = #selector(likeTapped)
        likeButton.setAccessibilityLabel("Like")
        replyButton.target = self
        replyButton.action = #selector(replyTapped)
        replyButton.setAccessibilityLabel("Reply")
        retweetButton.setAccessibilityLabel("Reposts")
        viewsButton.setAccessibilityLabel("Views")

        let column = NSStackView(views: [header, replyingRow, bodyLabel, mediaView, quotedContainer, analyticsView, actionBar])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = DesignSystem.Spacing.s
        column.setCustomSpacing(DesignSystem.Spacing.xxs, after: header)
        column.setCustomSpacing(DesignSystem.Spacing.xs, after: replyingRow)
        column.setHuggingPriority(.defaultLow, for: .horizontal)

        addManaged(avatar)
        addManaged(column)
        threadRail.isHidden = true
        addManaged(threadRail)
        addManaged(separator)

        separator.boxType = .separator

        let avatarLeading = avatar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DesignSystem.Spacing.l)
        self.avatarLeading = avatarLeading
        let railWidth = threadRail.widthAnchor.constraint(equalToConstant: 0)
        self.railWidth = railWidth

        header.setContentHuggingPriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: 44),
            avatar.heightAnchor.constraint(equalToConstant: 44),
            avatar.topAnchor.constraint(equalTo: topAnchor, constant: DesignSystem.Spacing.m),
            avatarLeading,

            threadRail.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DesignSystem.Spacing.l),
            railWidth,
            threadRail.topAnchor.constraint(equalTo: topAnchor),
            threadRail.bottomAnchor.constraint(equalTo: bottomAnchor),

            column.topAnchor.constraint(equalTo: topAnchor, constant: DesignSystem.Spacing.m),
            column.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: DesignSystem.Spacing.m),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DesignSystem.Spacing.l),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -DesignSystem.Spacing.s),

            header.widthAnchor.constraint(equalTo: column.widthAnchor),
            replyingRow.widthAnchor.constraint(equalTo: column.widthAnchor),
            bodyLabel.widthAnchor.constraint(equalTo: column.widthAnchor),
            mediaView.widthAnchor.constraint(equalTo: column.widthAnchor),
            quotedContainer.widthAnchor.constraint(equalTo: column.widthAnchor),
            analyticsView.widthAnchor.constraint(equalTo: column.widthAnchor),
            actionBar.widthAnchor.constraint(equalTo: column.widthAnchor),

            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    private func buildQuoted() {
        quotedContainer.wantsLayer = true
        quotedContainer.layer?.borderWidth = 1
        quotedContainer.layer?.borderColor = DesignSystem.Color.separator.cgColor
        quotedContainer.layer?.cornerRadius = DesignSystem.Radius.control
        quotedContainer.layer?.cornerCurve = .continuous
        quotedContainer.isHidden = true
        let quotedTap = NSClickGestureRecognizer(target: self, action: #selector(quotedTapped))
        quotedContainer.addGestureRecognizer(quotedTap)

        quotedAvatar.setRounded(8)
        quotedAvatar.setFill()

        quotedThumb.setRounded(8)
        quotedThumb.setFill()
        quotedThumb.isHidden = true
        quotedThumbHeight = quotedThumb.heightAnchor.constraint(equalToConstant: 120)
        quotedThumbHeight.priority = .defaultHigh

        let authorRow = NSStackView(views: [quotedAvatar, quotedAuthorLabel])
        authorRow.orientation = .horizontal
        authorRow.alignment = .centerY
        authorRow.spacing = DesignSystem.Spacing.xs

        quotedBodyLabel.maximumNumberOfLines = 4
        let stack = NSStackView(views: [authorRow, quotedBodyLabel, quotedThumb])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DesignSystem.Spacing.xxs
        quotedContainer.addManaged(stack)
        stack.pinEdges(to: quotedContainer, insets: NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10))
        NSLayoutConstraint.activate([
            quotedAvatar.widthAnchor.constraint(equalToConstant: 18),
            quotedAvatar.heightAnchor.constraint(equalToConstant: 18),
            quotedThumb.widthAnchor.constraint(equalTo: stack.widthAnchor),
            quotedThumbHeight,
        ])
    }

    /// Configures the cell for a tweet. `isReply` shows the "Replying" affordance
    /// and strips the body's leading mentions; `isFocal` switches the timestamp
    /// to absolute; `showAnalytics` reveals the own-tweet analytics block.
    /// A muted "↩ Replying" caption shown above a feed tweet that is itself a
    /// reply, conveying the same context as the TUI's `⮎` is-a-reply marker.
    private func buildReplyingRow() {
        replyingIcon.image = DesignSystem.icon("arrowshape.turn.up.left", pointSize: 10)
        replyingIcon.contentTintColor = DesignSystem.Color.secondaryLabel
        replyingIcon.setContentHuggingPriority(.required, for: .horizontal)
        replyingLabel.stringValue = "Replying"
        replyingRow.orientation = .horizontal
        replyingRow.alignment = .centerY
        replyingRow.spacing = DesignSystem.Spacing.xxs
        replyingRow.addArrangedSubview(replyingIcon)
        replyingRow.addArrangedSubview(replyingLabel)
        replyingRow.isHidden = true
    }

    /// Configures the cell for a tweet. `isReply` shows the "Replying" affordance;
    /// `inThread` strips the body's leading mentions (the whole conversation reads
    /// cleanly, like X) and applies the reply-depth `indentLevel`; `isFocal`
    /// switches the timestamp to absolute; `showAnalytics` reveals the own-tweet
    /// analytics block.
    func configure(with tweet: Tweet, imagesEnabled: Bool, contentWidth: CGFloat,
                   seen: Bool = false, isReply: Bool = false, isFocal: Bool = false,
                   inThread: Bool = false, indentLevel: Int = 0,
                   showAnalytics: Bool = false) {
        self.contentWidth = contentWidth
        setIndent(inThread ? indentLevel : 0)
        nameLabel.stringValue = tweet.author.name
        verifiedBadge.isHidden = !tweet.author.verified
        configureHandleLine(tweet, isFocal: isFocal)
        configureReplyingRow(tweet, isReply: isReply, inThread: inThread)
        bodyLabel.attributedStringValue = TweetTextRenderer.body(
            for: tweet, font: DesignSystem.Typography.body(), color: DesignSystem.Color.label,
            stripLeadingMentions: inThread || isReply)
        bodyLabel.isHidden = bodyLabel.attributedStringValue.length == 0
        alphaValue = seen ? 0.55 : 1.0

        setAccessibilityLabel("Tweet by \(tweet.author.name), @\(tweet.author.handle): \(tweet.text)")

        configureAvatar(tweet, imagesEnabled: imagesEnabled)
        mediaView.isHidden = !TweetMediaView.hasMedia(tweet)
        if TweetMediaView.hasMedia(tweet) {
            mediaView.configure(with: tweet, api: api, imagesEnabled: imagesEnabled, contentWidth: contentWidth)
        } else {
            mediaView.reset()
        }
        configureQuoted(tweet.quotedTweet, imagesEnabled: imagesEnabled, contentWidth: contentWidth)
        analyticsView.isHidden = !showAnalytics
        if showAnalytics { analyticsView.configure(with: tweet) }
        configureActions(tweet)
    }

    private func configureHandleLine(_ tweet: Tweet, isFocal: Bool) {
        let time = isFocal ? Format.absoluteTime(tweet.createdAt) : Format.relativeTime(tweet.createdAt)
        let handleColor = DesignSystem.handleColor(tweet.author.handle)
        let secondary = DesignSystem.Color.secondaryLabel
        let font = DesignSystem.Typography.handle()
        let result = NSMutableAttributedString(
            string: "@\(tweet.author.handle)", attributes: [.font: font, .foregroundColor: handleColor])
        result.append(NSAttributedString(
            string: " · \(time)", attributes: [.font: font, .foregroundColor: secondary]))
        handleTimeLabel.attributedStringValue = result
    }

    private func configureReplyingRow(_ tweet: Tweet, isReply: Bool, inThread: Bool) {
        let isAReply = tweet.inReplyToTweetID != nil
        replyingRow.isHidden = inThread || !(isAReply && !isReply)
    }

    /// Indents the row by reply depth so a reply-to-a-reply sits further right
    /// than a reply-to-the-root; level 0 (feed / focal / ancestors) is flush. A
    /// thin gutter spine ties nested replies to the conversation. Mirrors the iOS
    /// `TweetCell.setIndent`.
    private func setIndent(_ level: Int) {
        let clamped = min(max(0, level), Self.maxIndent)
        avatarLeading.constant = DesignSystem.Spacing.l + CGFloat(clamped) * ThreadRailView.step
        railWidth.constant = CGFloat(clamped) * ThreadRailView.step
        threadRail.level = clamped
        threadRail.isHidden = clamped == 0
    }

    private func configureAvatar(_ tweet: Tweet, imagesEnabled: Bool) {
        avatar.setAccessibilityLabel("\(tweet.author.name) profile")
        if imagesEnabled, let url = tweet.author.avatarURL.flatMap(URL.init) {
            avatar.load(url: url, targetSize: CGSize(width: 44, height: 44))
        } else {
            avatar.cancel()
            avatar.image = DesignSystem.icon("person.crop.circle.fill", pointSize: 36)
            avatar.contentTintColor = DesignSystem.Color.tertiaryLabel
        }
    }

    private func configureQuoted(_ quoted: Tweet?, imagesEnabled: Bool, contentWidth: CGFloat) {
        guard let quoted else {
            quotedContainer.isHidden = true
            quotedAvatar.cancel()
            quotedThumb.cancel()
            return
        }
        quotedContainer.isHidden = false
        let font = DesignSystem.Typography.handle()
        let header = NSMutableAttributedString(
            string: quoted.author.name,
            attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                         .foregroundColor: DesignSystem.Color.label])
        header.append(NSAttributedString(
            string: " @\(quoted.author.handle)",
            attributes: [.font: font, .foregroundColor: DesignSystem.handleColor(quoted.author.handle)]))
        header.append(NSAttributedString(
            string: " · \(Format.relativeTime(quoted.createdAt))",
            attributes: [.font: font, .foregroundColor: DesignSystem.Color.secondaryLabel]))
        quotedAuthorLabel.attributedStringValue = header
        quotedBodyLabel.attributedStringValue = TweetTextRenderer.plain(
            quoted.text, font: DesignSystem.Typography.metric(),
            color: DesignSystem.Color.label, urls: quoted.urls)
        quotedBodyLabel.isHidden = quoted.text.isEmpty

        if imagesEnabled, let url = quoted.author.avatarURL.flatMap(URL.init) {
            quotedAvatar.isHidden = false
            quotedAvatar.load(url: url, targetSize: CGSize(width: 18, height: 18))
        } else {
            quotedAvatar.isHidden = true
        }

        if imagesEnabled, let thumbURL = quotedThumbnailURL(for: quoted) {
            quotedThumb.isHidden = false
            let width = contentWidth - 20
            let height = max(100, (width * 9 / 16).rounded())
            quotedThumbHeight.constant = height
            quotedThumb.load(url: thumbURL, targetSize: CGSize(width: width, height: height))
        } else {
            quotedThumb.isHidden = true
            quotedThumb.cancel()
        }
    }

    private func quotedThumbnailURL(for quoted: Tweet) -> URL? {
        guard let first = quoted.media.first else { return nil }
        switch first.kind {
        case .poll: return nil
        default: return first.url.isEmpty ? nil : URL(string: first.url)
        }
    }

    private func configureActions(_ tweet: Tweet) {
        let likeColor = tweet.favorited ? DesignSystem.Color.like : DesignSystem.Color.secondaryLabel
        setTitle(replyButton, countLabel(tweet.replyCount), color: DesignSystem.Color.secondaryLabel)
        setTitle(retweetButton, countLabel(tweet.retweetCount), color: DesignSystem.Color.secondaryLabel)
        setTitle(likeButton, countLabel(tweet.likeCount), color: likeColor)
        setTitle(viewsButton, tweet.viewCount.map { Format.count($0) } ?? "", color: DesignSystem.Color.secondaryLabel)

        let likeSymbol = tweet.favorited ? "heart.fill" : "heart"
        likeButton.image = DesignSystem.icon(likeSymbol, pointSize: 13)
        likeButton.contentTintColor = likeColor
        likeButton.setAccessibilityLabel(tweet.favorited ? "Unlike" : "Like")
    }

    /// Flips the like button's filled/colored state and adjusts the count
    /// without reloading the row — used for optimistic engagement. `baseCount`
    /// is the server count for the tweet's *current* favorited state, so liking
    /// adds one and unliking removes one.
    func applyOptimisticLike(_ liked: Bool, baseCount: Int) {
        let color = liked ? DesignSystem.Color.like : DesignSystem.Color.secondaryLabel
        let count = max(0, baseCount + (liked ? 1 : -1))
        likeButton.image = DesignSystem.icon(liked ? "heart.fill" : "heart", pointSize: 13)
        likeButton.contentTintColor = color
        likeButton.setAccessibilityLabel(liked ? "Unlike" : "Like")
        setTitle(likeButton, countLabel(count), color: color)
    }

    private func setTitle(_ button: NSButton, _ text: String, color: NSColor) {
        button.attributedTitle = NSAttributedString(
            string: text.isEmpty ? "" : " \(text)",
            attributes: [.foregroundColor: color, .font: DesignSystem.Typography.metric()])
    }

    private func countLabel(_ count: Int) -> String {
        count > 0 ? Format.count(count) : ""
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        avatar.cancel()
        mediaView.reset()
        quotedAvatar.cancel()
        quotedThumb.cancel()
        replyingRow.isHidden = true
        analyticsView.isHidden = true
        setIndent(0)
        alphaValue = 1.0
        onTapAuthor = nil
        onTapPhoto = nil
        onTapVideo = nil
        onTapPoll = nil
        onTapQuoted = nil
        onLike = nil
        onReply = nil
    }

    override func layout() {
        super.layout()
        updateQuotedBorderColor()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateQuotedBorderColor()
        threadRail.needsDisplay = true
    }

    private func updateQuotedBorderColor() {
        var resolved = DesignSystem.Color.separator.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = DesignSystem.Color.separator.cgColor
        }
        quotedContainer.layer?.borderColor = resolved
    }

    @objc private func authorTapped() { onTapAuthor?() }
    @objc private func quotedTapped() { onTapQuoted?() }
    @objc private func likeTapped() { onLike?() }
    @objc private func replyTapped() { onReply?() }

    private static func label(font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.allowsDefaultTighteningForTruncation = true
        return field
    }

    private static func wrappingLabel(font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: "")
        field.font = font
        field.textColor = color
        field.isSelectable = true
        field.isEditable = false
        field.allowsEditingTextAttributes = false
        field.drawsBackground = false
        field.isBordered = false
        field.preferredMaxLayoutWidth = 500
        field.lineBreakMode = .byWordWrapping
        field.cell?.usesSingleLineMode = false
        return field
    }

    private static func actionButton(symbol: String) -> NSButton {
        let button = NSButton(title: "", target: nil, action: nil)
        button.bezelStyle = .inline
        button.isBordered = false
        button.image = DesignSystem.icon(symbol, pointSize: 13)
        button.imagePosition = .imageLeading
        button.contentTintColor = DesignSystem.Color.secondaryLabel
        button.font = DesignSystem.Typography.metric()
        button.alignment = .left
        button.imageHugsTitle = true
        button.attributedTitle = NSAttributedString(
            string: "",
            attributes: [.foregroundColor: DesignSystem.Color.secondaryLabel, .font: DesignSystem.Typography.metric()])
        return button
    }
}

/// The own-tweet post-analytics block shown on the focal tweet in a thread:
/// views · likes · reposts · replies · quotes · bookmarks plus an engagement
/// rate. Mirrors the TUI's `analytics_lines`.
final class TweetAnalyticsView: NSView {
    private let heading = NSTextField(labelWithString: "Post analytics")
    private let metricsRow = NSStackView()
    private let rateLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        wantsLayer = true
        layer?.cornerRadius = DesignSystem.Radius.control
        layer?.cornerCurve = .continuous
        applyLayerBackground(DesignSystem.Color.surface)

        let chartIcon = NSImageView()
        chartIcon.image = DesignSystem.icon("chart.bar.xaxis", pointSize: 11, weight: .semibold)
        chartIcon.contentTintColor = DesignSystem.Color.accent
        chartIcon.setContentHuggingPriority(.required, for: .horizontal)
        heading.font = .systemFont(ofSize: 12, weight: .bold)
        heading.textColor = DesignSystem.Color.label
        let headingRow = NSStackView(views: [chartIcon, heading])
        headingRow.orientation = .horizontal
        headingRow.alignment = .centerY
        headingRow.spacing = DesignSystem.Spacing.xs

        metricsRow.orientation = .horizontal
        metricsRow.alignment = .firstBaseline
        metricsRow.spacing = DesignSystem.Spacing.l
        metricsRow.distribution = .fill

        rateLabel.font = DesignSystem.Typography.metric()
        rateLabel.textColor = DesignSystem.Color.secondaryLabel

        let column = NSStackView(views: [headingRow, metricsRow, rateLabel])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = DesignSystem.Spacing.s
        addManaged(column)
        column.pinEdges(to: self, insets: NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12))
    }

    func configure(with tweet: Tweet) {
        metricsRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let views = tweet.viewCount {
            metricsRow.addArrangedSubview(metric("Views", value: views, color: DesignSystem.Color.secondaryLabel))
        }
        metricsRow.addArrangedSubview(metric("Likes", value: tweet.likeCount, color: DesignSystem.Color.like))
        metricsRow.addArrangedSubview(metric("Reposts", value: tweet.retweetCount, color: DesignSystem.Color.retweet))
        metricsRow.addArrangedSubview(metric("Replies", value: tweet.replyCount, color: DesignSystem.Color.secondaryLabel))
        metricsRow.addArrangedSubview(metric("Quotes", value: tweet.quoteCount, color: DesignSystem.Color.quote))
        metricsRow.addArrangedSubview(metric("Bookmarks", value: tweet.bookmarkCount, color: DesignSystem.Color.secondaryLabel))
        metricsRow.addArrangedSubview(NSView())

        let total = tweet.likeCount + tweet.retweetCount + tweet.replyCount + tweet.quoteCount + tweet.bookmarkCount
        if let views = tweet.viewCount, views > 0 {
            let rate = Double(total) / Double(views) * 100
            let formatted = rate >= 10 ? String(format: "%.1f%%", rate) : String(format: "%.2f%%", rate)
            rateLabel.stringValue = "Engagement rate \(formatted)  (\(Format.count(total)) / \(Format.count(views)) views)"
            rateLabel.isHidden = false
        } else if total > 0 {
            rateLabel.stringValue = "Total engagements \(Format.count(total))"
            rateLabel.isHidden = false
        } else {
            rateLabel.isHidden = true
        }
    }

    private func metric(_ title: String, value: Int, color: NSColor) -> NSView {
        let valueField = NSTextField(labelWithString: Format.count(value))
        valueField.font = .systemFont(ofSize: 15, weight: .bold)
        valueField.textColor = DesignSystem.Color.label
        let titleField = NSTextField(labelWithString: title)
        titleField.font = DesignSystem.Typography.caption()
        titleField.textColor = color
        let stack = NSStackView(views: [valueField, titleField])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        return stack
    }
}
