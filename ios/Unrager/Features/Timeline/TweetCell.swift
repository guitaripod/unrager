import UIKit
import UnragerKit

/// The leading nesting guides for a thread reply: one rounded vertical rail per
/// depth level, so a reply-to-a-reply shows two aligned rails where a
/// reply-to-the-root shows one. Consecutive same-depth replies share rail
/// positions, reading as continuous thread lines. Drawn (not subviews) so the
/// count is cheap to change on reuse.
final class ThreadRailView: UIView {
    static let step: CGFloat = 16

    var level = 0 {
        didSet { if level != oldValue { setNeedsDisplay() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: ThreadRailView, _) in
            view.setNeedsDisplay()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard level > 0, let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setStrokeColor(DesignSystem.Color.separator.cgColor)
        ctx.setLineWidth(2)
        ctx.setLineCap(.round)
        for index in 0..<level {
            let x = CGFloat(index) * Self.step + Self.step / 2
            ctx.move(to: CGPoint(x: x, y: 3))
            ctx.addLine(to: CGPoint(x: x, y: rect.height - 3))
        }
        ctx.strokePath()
    }
}

/// The feed's tweet card. Custom cell (not list configuration), opaque
/// background, rounded corners on the image views themselves, no shadows or
/// sublayer masks — so it scrolls without off-screen render passes. Images
/// decode off-main via `AsyncImageView`; rich media (polls, cards, video,
/// photo grids) lives in `MediaContentView`, which is torn down on reuse.
final class TweetCell: UICollectionViewCell {
    static let reuseID = "TweetCell"

    var onTapAuthor: (() -> Void)?
    var onTapPhoto: ((Int) -> Void)?
    var onTapCard: ((URL) -> Void)?
    var onLike: (() -> Void)?
    var onReply: (() -> Void)?
    var onTapQuoted: (() -> Void)?
    /// Routes a tapped `@mention` to a profile, or `#hashtag` to search.
    var onTapMention: ((String) -> Void)?
    var onTapHashtag: ((String) -> Void)?

    private let avatar = AsyncImageView(frame: .zero)
    private let nameLabel = UILabel()
    private let verifiedBadge = UIImageView()
    private let replyMarker = UIImageView()
    private let handleTimeLabel = UILabel()
    private let bodyView = TweetBodyTextView()
    private let mediaContent = MediaContentView(compact: false)
    private let quotedContainer = UIView()
    private let quotedAvatar = AsyncImageView(frame: .zero)
    private let quotedAuthorLabel = UILabel()
    private let quotedBodyLabel = UILabel()
    private let quotedMedia = MediaContentView(compact: true)
    private let actionBar = UIStackView()
    private let analyticsView = TweetAnalyticsView()
    private let separator = UIView()
    private let threadRail = ThreadRailView()
    private var avatarLeading: NSLayoutConstraint!
    private var railWidth: NSLayoutConstraint!

    private static let maxIndent = 3

    private let replyButton = TweetCell.makeActionButton(symbol: "bubble.left")
    private let retweetButton = TweetCell.makeActionButton(symbol: "arrow.2.squarepath")
    private let likeButton = TweetCell.makeActionButton(symbol: "heart")
    private let viewsButton = TweetCell.makeActionButton(symbol: "chart.bar")

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = DesignSystem.Color.background
        contentView.isOpaque = true
        buildHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        avatar.cancel()
        quotedAvatar.cancel()
        mediaContent.prepareForReuse()
        quotedMedia.prepareForReuse()
        contentView.alpha = 1
        setIndent(0)
        onTapAuthor = nil
        onTapPhoto = nil
        onTapCard = nil
        onLike = nil
        onReply = nil
        onTapQuoted = nil
        onTapMention = nil
        onTapHashtag = nil
    }

    /// Inline-video playback control, driven by the feed so only the most-visible
    /// clip plays while at rest (and nothing plays mid-scroll).
    var hasVideo: Bool { mediaContent.hasVideo }
    /// The media surface, used as the source for the App Store–style zoom into
    /// the full-screen viewer.
    var mediaSourceView: UIView { mediaContent }
    func playVideo() { mediaContent.playVideo() }
    func pauseVideo() { mediaContent.pauseVideo() }

    /// `inReplyContext` strips the leading `@handle` prefix from replies (only
    /// meaningful in the thread's replies section) and suppresses the standalone
    /// is-a-reply marker, mirroring the TUI. `focal` switches the timestamp to an
    /// absolute one and, when `ownTweet`, appends the post-analytics block — the
    /// same emphasis the TUI gives the open tweet.
    func configure(
        with tweet: Tweet, imagesEnabled: Bool, contentWidth: CGFloat,
        seen: Bool = false, inReplyContext: Bool = false,
        focal: Bool = false, ownTweet: Bool = false, indentLevel: Int = 0
    ) {
        setIndent(indentLevel)
        nameLabel.text = tweet.author.name
        verifiedBadge.isHidden = !tweet.author.verified
        replyMarker.isHidden = !(tweet.inReplyToTweetID != nil && !inReplyContext)
        handleTimeLabel.attributedText = Self.handleTime(tweet, absolute: focal)
        let body = TweetText.attributed(
            for: tweet, stripLeadingMentions: inReplyContext, seen: seen,
            font: DesignSystem.Typography.body())
        bodyView.attributedText = body
        bodyView.isHidden = body.length == 0
        bodyView.onTapMention = { [weak self] in self?.onTapMention?($0) }
        bodyView.onTapHashtag = { [weak self] in self?.onTapHashtag?($0) }
        bodyView.onTapURL = { [weak self] in self?.onTapCard?($0) }
        contentView.alpha = seen ? 0.55 : 1

        loadAvatar(into: avatar, url: tweet.author.avatarURL, size: 44, fallbackPoint: 36, enabled: imagesEnabled)

        mediaContent.onTapPhoto = { [weak self] index in self?.onTapPhoto?(index) }
        mediaContent.onTapCard = { [weak self] url in self?.onTapCard?(url) }
        mediaContent.configure(with: tweet, imagesEnabled: imagesEnabled, contentWidth: contentWidth)

        configureQuoted(tweet.quotedTweet, imagesEnabled: imagesEnabled, contentWidth: contentWidth - 20)
        configureActions(tweet)
        analyticsView.configure(tweet, visible: focal && ownTweet)
        configureAccessibility(tweet, seen: seen)
    }

    /// Indents the card by reply depth so a reply-to-a-reply sits further right
    /// than a reply-to-the-root; level 0 (feed / root / focal) is flush. A thin
    /// gutter spine ties consecutive nested replies together. Threads pass a
    /// depth; the postcard renders flat and never calls this.
    func setIndent(_ level: Int) {
        let clamped = min(max(0, level), Self.maxIndent)
        avatarLeading.constant = DesignSystem.Spacing.l + CGFloat(clamped) * ThreadRailView.step
        railWidth.constant = CGFloat(clamped) * ThreadRailView.step
        threadRail.level = clamped
        threadRail.isHidden = clamped == 0
    }

    /// `@handle` color-hashed + a separator + the relative (feed) or absolute
    /// (focal) timestamp in muted gray.
    private static func handleTime(_ tweet: Tweet, absolute: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "@\(tweet.author.handle)", attributes: [
            .font: DesignSystem.Typography.handle(),
            .foregroundColor: DesignSystem.handleColor(tweet.author.handle),
        ])
        let time = absolute ? Format.absoluteTime(tweet.createdAt) : Format.relativeTime(tweet.createdAt)
        result.append(NSAttributedString(string: " · \(time)", attributes: [
            .font: DesignSystem.Typography.handle(),
            .foregroundColor: DesignSystem.Color.secondaryLabel,
        ]))
        return result
    }

    private func loadAvatar(into view: AsyncImageView, url: String?, size: CGFloat, fallbackPoint: CGFloat, enabled: Bool) {
        if enabled, let url = url.flatMap(URL.init) {
            view.load(url: url, targetSize: CGSize(width: size, height: size))
        } else {
            view.cancel()
            view.image = DesignSystem.icon("person.crop.circle.fill", pointSize: fallbackPoint)
            view.tintColor = DesignSystem.Color.tertiaryLabel
        }
    }

    private func configureQuoted(_ quoted: Tweet?, imagesEnabled: Bool, contentWidth: CGFloat) {
        guard let quoted else {
            quotedContainer.isHidden = true
            quotedMedia.prepareForReuse()
            quotedMedia.isHidden = true
            return
        }
        quotedContainer.isHidden = false
        quotedAuthorLabel.attributedText = Self.quotedHeader(quoted)
        quotedBodyLabel.text = quoted.text
        quotedBodyLabel.isHidden = quoted.text.isEmpty
        loadAvatar(into: quotedAvatar, url: quoted.author.avatarURL, size: 18, fallbackPoint: 16, enabled: imagesEnabled)
        quotedMedia.onTapPhoto = { [weak self] _ in self?.onTapQuoted?() }
        quotedMedia.onTapCard = { [weak self] _ in self?.onTapQuoted?() }
        quotedMedia.configure(with: quoted, imagesEnabled: imagesEnabled, contentWidth: max(120, contentWidth))
    }

    /// `Name` + a color-hashed `@handle` + a relative timestamp — the same fields
    /// the TUI's inline quote header shows.
    private static func quotedHeader(_ quoted: Tweet) -> NSAttributedString {
        let result = NSMutableAttributedString(string: quoted.author.name, attributes: [
            .font: DesignSystem.Typography.handle(),
            .foregroundColor: DesignSystem.Color.label,
        ])
        result.append(NSAttributedString(string: " @\(quoted.author.handle)", attributes: [
            .font: DesignSystem.Typography.handle(),
            .foregroundColor: DesignSystem.handleColor(quoted.author.handle),
        ]))
        result.append(NSAttributedString(string: " · \(Format.relativeTime(quoted.createdAt))", attributes: [
            .font: DesignSystem.Typography.handle(),
            .foregroundColor: DesignSystem.Color.secondaryLabel,
        ]))
        return result
    }

    private func configureActions(_ tweet: Tweet) {
        replyButton.configuration?.title = label(tweet.replyCount)
        retweetButton.configuration?.title = label(tweet.retweetCount)
        likeButton.configuration?.title = label(tweet.likeCount)
        viewsButton.configuration?.title = tweet.viewCount.map { Format.count($0) } ?? ""

        let liked = tweet.favorited
        likeButton.configuration?.image = DesignSystem.icon(liked ? "heart.fill" : "heart", pointSize: 15)
        likeButton.configuration?.baseForegroundColor = liked ? DesignSystem.Color.like : DesignSystem.Color.secondaryLabel
    }

    /// Reflects an optimistic like toggle without re-running the full config —
    /// the feed calls this the instant the user taps so the heart fills before
    /// the network confirms.
    func applyLike(favorited: Bool, count: Int) {
        likeButton.configuration?.title = label(count)
        likeButton.configuration?.image = DesignSystem.icon(favorited ? "heart.fill" : "heart", pointSize: 15)
        likeButton.configuration?.baseForegroundColor = favorited ? DesignSystem.Color.like : DesignSystem.Color.secondaryLabel
        likeButton.accessibilityLabel = favorited ? "Unlike" : "Like"
    }

    private func configureAccessibility(_ tweet: Tweet, seen: Bool) {
        avatar.isAccessibilityElement = true
        avatar.accessibilityTraits = .button
        avatar.accessibilityLabel = "\(tweet.author.name), profile"

        replyButton.accessibilityLabel = "Reply, \(tweet.replyCount)"
        retweetButton.accessibilityLabel = "Reposts, \(tweet.retweetCount)"
        likeButton.accessibilityLabel = tweet.favorited ? "Unlike, \(tweet.likeCount)" : "Like, \(tweet.likeCount)"
        viewsButton.accessibilityLabel = tweet.viewCount.map { "\(Format.count($0)) views" }
        viewsButton.isAccessibilityElement = tweet.viewCount != nil

        let verified = tweet.author.verified ? ", verified" : ""
        let seenSuffix = seen ? ", already seen" : ""
        let reply = (tweet.inReplyToTweetID != nil) ? ", replying" : ""
        bodyView.accessibilityLabel = "\(tweet.author.name)\(verified)\(reply). \(tweet.text)\(seenSuffix)"
    }

    private func label(_ count: Int) -> String { count > 0 ? Format.count(count) : "" }

    // MARK: - Hierarchy

    private func buildHierarchy() {
        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.setRounded(22)
        avatar.isUserInteractionEnabled = true
        avatar.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(authorTapped)))

        nameLabel.font = DesignSystem.Typography.name()
        nameLabel.textColor = DesignSystem.Color.label
        nameLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        verifiedBadge.image = DesignSystem.icon("checkmark.seal.fill", pointSize: 13)
        verifiedBadge.tintColor = DesignSystem.Color.verified
        verifiedBadge.setContentHuggingPriority(.required, for: .horizontal)
        verifiedBadge.isAccessibilityElement = false

        replyMarker.image = DesignSystem.icon("arrowshape.turn.up.left.fill", pointSize: 11)
        replyMarker.tintColor = DesignSystem.Color.secondaryLabel
        replyMarker.setContentHuggingPriority(.required, for: .horizontal)
        replyMarker.isAccessibilityElement = false
        replyMarker.isHidden = true

        handleTimeLabel.font = DesignSystem.Typography.handle()
        handleTimeLabel.textColor = DesignSystem.Color.secondaryLabel
        handleTimeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let header = UIStackView(arrangedSubviews: [replyMarker, nameLabel, verifiedBadge, handleTimeLabel, UIView()])
        header.axis = .horizontal
        header.spacing = 4
        header.alignment = .center
        header.isAccessibilityElement = false

        mediaContent.translatesAutoresizingMaskIntoConstraints = false

        buildQuoted()

        actionBar.axis = .horizontal
        actionBar.distribution = .fillEqually
        actionBar.addArrangedSubview(replyButton)
        actionBar.addArrangedSubview(retweetButton)
        actionBar.addArrangedSubview(likeButton)
        actionBar.addArrangedSubview(viewsButton)
        likeButton.addTarget(self, action: #selector(likeTapped), for: .touchUpInside)
        replyButton.addTarget(self, action: #selector(replyTapped), for: .touchUpInside)
        replyButton.accessibilityHint = "Reply to this tweet"
        retweetButton.isUserInteractionEnabled = false

        let column = UIStackView(arrangedSubviews: [header, bodyView, mediaContent, quotedContainer, actionBar, analyticsView])
        column.axis = .vertical
        column.spacing = DesignSystem.Spacing.s
        column.setCustomSpacing(DesignSystem.Spacing.xs, after: header)

        contentView.addManaged(avatar)
        contentView.addManaged(column)
        threadRail.isHidden = true
        contentView.addManaged(threadRail)
        separator.backgroundColor = DesignSystem.Color.separator
        contentView.addManaged(separator)

        let avatarLeading = avatar.leadingAnchor.constraint(
            equalTo: contentView.leadingAnchor, constant: DesignSystem.Spacing.l)
        self.avatarLeading = avatarLeading
        let railWidth = threadRail.widthAnchor.constraint(equalToConstant: 0)
        self.railWidth = railWidth

        NSLayoutConstraint.activate([
            avatar.topAnchor.constraint(equalTo: contentView.topAnchor, constant: DesignSystem.Spacing.m),
            avatarLeading,
            avatar.widthAnchor.constraint(equalToConstant: 44),
            avatar.heightAnchor.constraint(equalToConstant: 44),

            threadRail.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: DesignSystem.Spacing.l),
            railWidth,
            threadRail.topAnchor.constraint(equalTo: contentView.topAnchor),
            threadRail.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            column.topAnchor.constraint(equalTo: contentView.topAnchor, constant: DesignSystem.Spacing.m),
            column.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: DesignSystem.Spacing.m),
            column.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -DesignSystem.Spacing.l),
            column.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -DesignSystem.Spacing.s),

            separator.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1.0 / max(1, UITraitCollection.current.displayScale)),
        ])
    }

    private func buildQuoted() {
        quotedContainer.layer.cornerRadius = DesignSystem.Radius.control
        quotedContainer.layer.cornerCurve = .continuous
        quotedContainer.layer.borderWidth = 1
        quotedContainer.layer.borderColor = DesignSystem.Color.separator.cgColor
        quotedContainer.isUserInteractionEnabled = true
        quotedContainer.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(quotedTapped)))

        quotedAvatar.translatesAutoresizingMaskIntoConstraints = false
        quotedAvatar.setRounded(9)

        quotedAuthorLabel.font = DesignSystem.Typography.handle()
        quotedAuthorLabel.textColor = DesignSystem.Color.secondaryLabel
        quotedAuthorLabel.numberOfLines = 1
        quotedBodyLabel.font = DesignSystem.Typography.metric()
        quotedBodyLabel.textColor = DesignSystem.Color.label
        quotedBodyLabel.numberOfLines = 4

        let authorRow = UIStackView(arrangedSubviews: [quotedAvatar, quotedAuthorLabel, UIView()])
        authorRow.axis = .horizontal
        authorRow.spacing = 6
        authorRow.alignment = .center

        quotedMedia.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [authorRow, quotedBodyLabel, quotedMedia])
        stack.axis = .vertical
        stack.spacing = 6
        quotedContainer.addManaged(stack)
        stack.pinEdges(to: quotedContainer, insets: UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10))
        NSLayoutConstraint.activate([
            quotedAvatar.widthAnchor.constraint(equalToConstant: 18),
            quotedAvatar.heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    private static func makeActionButton(symbol: String) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = DesignSystem.icon(symbol, pointSize: 15)
        config.baseForegroundColor = DesignSystem.Color.secondaryLabel
        config.imagePadding = 6
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var out = incoming
            out.font = DesignSystem.Typography.metric()
            return out
        }
        let button = UIButton(configuration: config)
        button.contentHorizontalAlignment = .leading
        return button
    }

    @objc private func authorTapped() { onTapAuthor?() }
    @objc private func quotedTapped() { onTapQuoted?() }
    @objc private func replyTapped() {
        Haptics.tap()
        onReply?()
    }
    @objc private func likeTapped() {
        Haptics.tap()
        onLike?()
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        quotedContainer.layer.borderColor = DesignSystem.Color.separator.cgColor
    }
}
