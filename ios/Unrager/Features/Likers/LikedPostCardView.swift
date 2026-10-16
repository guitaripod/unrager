import UIKit
import UnragerKit

/// The post a list of likes is about, as far as the screen knows it: the whole
/// tweet when it has one, or only the line a notification quoted.
struct LikedPost {
    var tweet: Tweet?
    var snippet: String?

    var isEmpty: Bool { tweet == nil && (snippet ?? "").isEmpty }
}

/// The post card at the top of the Liked by list: the author, the text, the
/// first attachment and the counts that aren't likes (the ring carries those),
/// on a card with a spine in the author's own handle colour, a glow of the like
/// colour in one corner and a faint heart behind the counts. Tapping it opens
/// the post.
final class LikedPostCardView: UIView {
    var onOpen: (() -> Void)?

    private static let padding: CGFloat = 14
    private static let spineWidth: CGFloat = 4

    private let spine = UIView()
    private let glow = CAGradientLayer()
    private let watermark = UIImageView(image: DesignSystem.icon("heart.fill", pointSize: 120, weight: .black))
    private let avatar = AsyncImageView(frame: .zero)
    private let nameLabel = UILabel()
    private let seal = UIImageView(image: DesignSystem.icon("checkmark.seal.fill", pointSize: 13))
    private let metaLabel = UILabel()
    private let bodyLabel = UILabel()
    private let media = MediaContentView(compact: true)
    private let mediaHolder = UIView()
    private var mediaWidthConstraint: NSLayoutConstraint!
    private let statsLabel = UILabel()
    private let statsColumn = UIStackView()
    private let mediaRow = UIStackView()
    private let authorRow = UIStackView()
    private var showsTweet = false
    private var drawn: Drawn?

    /// What the card was last drawn for, so a header redrawn for the sake of
    /// the figures under it leaves the post alone.
    private struct Drawn: Equatable {
        let tweetID: String?
        let snippet: String?
        let width: CGFloat
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = DesignSystem.Color.surface
        layer.cornerRadius = 22
        layer.cornerCurve = .continuous
        clipsToBounds = true
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityHint = "Opens the post"
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))

        glow.type = .radial
        glow.startPoint = CGPoint(x: 1, y: 0)
        glow.endPoint = CGPoint(x: -0.1, y: 1.15)
        layer.addSublayer(glow)

        watermark.contentMode = .center
        watermark.isUserInteractionEnabled = false
        addSubview(watermark)

        spine.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spine)

        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.setRounded(18)
        nameLabel.font = DesignSystem.Typography.name()
        nameLabel.textColor = DesignSystem.Color.label
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        seal.tintColor = DesignSystem.Color.verified
        seal.setContentHuggingPriority(.required, for: .horizontal)
        seal.setContentCompressionResistancePriority(.required, for: .horizontal)
        let sealSpacer = UIView()
        sealSpacer.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
        let nameRow = UIStackView(arrangedSubviews: [nameLabel, seal, sealSpacer])
        nameRow.spacing = DesignSystem.Spacing.xs
        nameRow.alignment = .center
        metaLabel.font = DesignSystem.Typography.metric()
        metaLabel.textColor = DesignSystem.Color.secondaryLabel
        let names = UIStackView(arrangedSubviews: [nameRow, metaLabel])
        names.axis = .vertical
        names.spacing = 0
        authorRow.addArrangedSubview(avatar)
        authorRow.addArrangedSubview(names)
        authorRow.spacing = DesignSystem.Spacing.s
        authorRow.alignment = .center

        bodyLabel.font = DesignSystem.Typography.handle()
        bodyLabel.textColor = DesignSystem.Color.label
        bodyLabel.numberOfLines = 6

        media.onTapPhoto = { [weak self] _ in self?.tapped() }
        media.onTapCard = { [weak self] _ in self?.tapped() }

        statsLabel.font = DesignSystem.Typography.metric()
        statsLabel.textColor = DesignSystem.Color.secondaryLabel

        mediaHolder.addManaged(media)
        mediaWidthConstraint = media.widthAnchor.constraint(equalToConstant: 200)
        NSLayoutConstraint.activate([
            media.leadingAnchor.constraint(equalTo: mediaHolder.leadingAnchor),
            media.topAnchor.constraint(equalTo: mediaHolder.topAnchor),
            media.bottomAnchor.constraint(equalTo: mediaHolder.bottomAnchor),
            media.trailingAnchor.constraint(equalTo: mediaHolder.trailingAnchor),
            mediaWidthConstraint,
        ])

        statsColumn.axis = .vertical
        statsColumn.alignment = .leading
        statsColumn.spacing = DesignSystem.Spacing.s
        statsColumn.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
        mediaRow.addArrangedSubview(mediaHolder)
        mediaRow.addArrangedSubview(statsColumn)
        mediaRow.alignment = .bottom
        mediaRow.spacing = DesignSystem.Spacing.m + 2

        let stack = UIStackView(arrangedSubviews: [authorRow, bodyLabel, mediaRow, statsLabel])
        stack.axis = .vertical
        stack.spacing = DesignSystem.Spacing.s + 2
        stack.setCustomSpacing(DesignSystem.Spacing.m, after: mediaRow)
        addManaged(stack)
        NSLayoutConstraint.activate([
            spine.leadingAnchor.constraint(equalTo: leadingAnchor),
            spine.topAnchor.constraint(equalTo: topAnchor),
            spine.bottomAnchor.constraint(equalTo: bottomAnchor),
            spine.widthAnchor.constraint(equalToConstant: Self.spineWidth),
            avatar.widthAnchor.constraint(equalToConstant: 36),
            avatar.heightAnchor.constraint(equalToConstant: 36),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Self.padding),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.padding),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding + Self.spineWidth),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.padding),
        ])
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) {
            (view: LikedPostCardView, _) in view.paintGlow()
        }
        paintGlow()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The width the card's own content has inside a row `rowWidth` wide.
    static func contentWidth(rowWidth: CGFloat) -> CGFloat {
        rowWidth - 2 * DesignSystem.Spacing.l - 2 * padding - spineWidth
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glow.frame = bounds
        CATransaction.commit()
        watermark.frame = CGRect(x: bounds.maxX - 96, y: bounds.maxY - 92, width: 150, height: 150)
    }

    private func paintGlow() {
        let like = DesignSystem.Color.like.resolvedColor(with: traitCollection)
        glow.colors = [like.withAlphaComponent(0.2).cgColor, like.withAlphaComponent(0).cgColor]
        watermark.tintColor = like.withAlphaComponent(0.06)
    }

    func prepareForReuse() {
        avatar.cancel()
        media.prepareForReuse()
    }

    /// Shows `post`, with media sized for a card `contentWidth` wide inside. A
    /// card that already shows a quoted line and now learns the whole post
    /// dissolves into it.
    func configure(post: LikedPost, contentWidth: CGFloat) {
        let signature = Drawn(tweetID: post.tweet?.restID, snippet: post.snippet, width: contentWidth)
        guard signature != drawn else { return }
        drawn = signature
        let learnsPost = post.tweet != nil && !showsTweet && window != nil
        showsTweet = post.tweet != nil
        guard learnsPost, !UIAccessibility.isReduceMotionEnabled else {
            apply(post, contentWidth: contentWidth)
            return
        }
        UIView.transition(with: self, duration: 0.3, options: [.transitionCrossDissolve, .allowUserInteraction]) {
            self.apply(post, contentWidth: contentWidth)
        }
    }

    private func apply(_ post: LikedPost, contentWidth: CGFloat) {
        guard let tweet = post.tweet else {
            showSnippet(post.snippet ?? "")
            return
        }
        authorRow.isHidden = false
        spine.backgroundColor = DesignSystem.handleColor(tweet.author.handle)
        nameLabel.attributedText = TwemojiText.attributed(
            tweet.author.name, font: DesignSystem.Typography.name(), color: DesignSystem.Color.label)
        seal.isHidden = !tweet.author.verified
        metaLabel.text = "@\(tweet.author.handle) · \(Format.relativeTime(tweet.createdAt))"
        if AppSettings.imagesEnabled, let url = tweet.author.avatarURL.flatMap(URL.init) {
            avatar.load(url: url, targetSize: CGSize(width: 36, height: 36))
        } else {
            avatar.cancel()
            avatar.image = DesignSystem.icon("person.crop.circle.fill", pointSize: 34)
            avatar.tintColor = DesignSystem.Color.tertiaryLabel
        }
        let body = TweetText.attributed(for: tweet, seen: false, font: DesignSystem.Typography.handle())
        bodyLabel.attributedText = body
        bodyLabel.isHidden = body.length == 0
        let width = Self.mediaWidth(for: tweet, contentWidth: max(120, contentWidth))
        mediaWidthConstraint.constant = width
        media.configure(with: tweet, imagesEnabled: AppSettings.imagesEnabled, contentWidth: width)
        mediaHolder.isHidden = media.isHidden
        mediaRow.isHidden = media.isHidden
        let entries = Self.entries(for: tweet)
        let beside = Self.statsFitBeside(mediaWidth: width, contentWidth: contentWidth) && !media.isHidden
        showStats(entries, beside: beside)
        accessibilityLabel = "Post by \(tweet.author.name), @\(tweet.author.handle). \(body.string). "
            + entries.map { "\($0.count.formatted()) \($0.noun)" }.joined(separator: ", ")
    }

    private func showSnippet(_ text: String) {
        authorRow.isHidden = true
        spine.backgroundColor = DesignSystem.Color.tertiaryLabel
        bodyLabel.font = DesignSystem.Typography.handle()
        bodyLabel.attributedText = TwemojiText.attributed(
            text, font: DesignSystem.Typography.handle(), color: DesignSystem.Color.label)
        bodyLabel.isHidden = text.isEmpty
        mediaRow.isHidden = true
        statsLabel.isHidden = true
        accessibilityLabel = "Post: \(text)"
    }

    @objc private func tapped() { onOpen?() }

    /// The tallest a picture or clip is let be in the card, so the people under
    /// it stay in reach.
    static let mediaHeight: CGFloat = 150

    /// How wide to draw the post's picture or clip so it is no taller than
    /// `mediaHeight`: the full `contentWidth` for a wide one, narrower for a
    /// tall one or a stack of photos. It keeps its own shape, never cropped;
    /// cards, polls and the like are drawn as a post draws them.
    static func mediaWidth(for tweet: Tweet, contentWidth: CGFloat) -> CGFloat {
        guard let rich = MediaContentView.pickRich(tweet.media) else { return contentWidth }
        let height: CGFloat
        switch rich.kind {
        case .photo:
            let photos = tweet.media.filter { if case .photo = $0.kind { true } else { false } }
            height = PhotoMosaic.make(ratios: photos.map(\.aspectRatio), width: contentWidth).height
        case .video, .animatedGif:
            height = contentWidth / MediaShape.frame(source: rich.aspectRatio, fallback: 16.0 / 9.0).ratio
        default:
            return contentWidth
        }
        guard height > mediaHeight else { return contentWidth }
        return max(96, (contentWidth * mediaHeight / height).rounded(.down))
    }

    /// One count under the post: its icon, figure and what it counts.
    struct Entry: Equatable {
        let symbol: String
        let count: Int
        let noun: String
    }

    /// The counts that aren't likes (the ring carries those), left out when
    /// zero.
    static func entries(for tweet: Tweet) -> [Entry] {
        [
            Entry(symbol: "bubble.left", count: tweet.replyCount, noun: "replies"),
            Entry(symbol: "arrow.2.squarepath", count: tweet.retweetCount, noun: "reposts"),
            Entry(symbol: "quote.bubble", count: tweet.quoteCount, noun: "quotes"),
            Entry(symbol: "eye", count: tweet.viewCount ?? 0, noun: "views"),
        ].filter { $0.count > 0 }
    }

    /// Whether the counts have room in a column to the right of a picture drawn
    /// `mediaWidth` wide, instead of in a line under it.
    static func statsFitBeside(mediaWidth: CGFloat, contentWidth: CGFloat) -> Bool {
        contentWidth - mediaWidth >= 104
    }

    /// Shows `entries` in a column beside the picture, or in one line under it.
    private func showStats(_ entries: [Entry], beside: Bool) {
        statsColumn.arrangedSubviews.forEach { $0.removeFromSuperview() }
        statsColumn.isHidden = !beside || entries.isEmpty
        statsLabel.isHidden = beside || entries.isEmpty
        if beside {
            for entry in entries {
                let label = UILabel()
                label.attributedText = Self.attributed(entry)
                statsColumn.addArrangedSubview(label)
            }
            return
        }
        let line = NSMutableAttributedString()
        for (index, entry) in entries.enumerated() {
            if index > 0 { line.append(NSAttributedString(string: "    ", attributes: [.font: DesignSystem.Typography.metric()])) }
            line.append(Self.attributed(entry))
        }
        statsLabel.attributedText = line
    }

    private static func attributed(_ entry: Entry) -> NSAttributedString {
        let text = NSMutableAttributedString()
        let attachment = NSTextAttachment()
        attachment.image = DesignSystem.icon(entry.symbol, pointSize: 12, weight: .medium)?
            .withTintColor(DesignSystem.Color.secondaryLabel, renderingMode: .alwaysOriginal)
        text.append(NSAttributedString(attachment: attachment))
        text.append(NSAttributedString(string: " \(Format.count(entry.count))", attributes: [
            .font: DesignSystem.Typography.metric(), .foregroundColor: DesignSystem.Color.secondaryLabel,
        ]))
        return text
    }
}
