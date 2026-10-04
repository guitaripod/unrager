import UIKit
import UnragerKit

extension Tweet {
    /// The most quote layers a row shows under its post: the post it quotes,
    /// the post that one quotes, and the post that one quotes.
    static let maxQuoteLayers = 3

    /// The posts this one quotes, nearest first, as deep as a row shows them.
    var quoteChain: [Tweet] {
        var chain: [Tweet] = []
        var next = quotedTweet
        while let post = next, chain.count < Self.maxQuoteLayers {
            chain.append(post)
            next = post.quotedTweet
        }
        return chain
    }
}

/// A quoted post inside a row: a bordered card with its author, text and
/// media, and, while the chain goes on, the post it quotes in turn nested
/// inside it, up to `Tweet.maxQuoteLayers` cards deep. Each card opens its own
/// post when tapped; the innermost card under the finger takes the tap.
final class QuotedPostView: UIView {
    /// Fired with the post of the tapped card.
    var onTap: ((Tweet) -> Void)?

    /// Which card this is: 1 for the one a row's post quotes.
    private let layerNumber: Int
    private var post: Tweet?
    private let avatar = AsyncImageView(frame: .zero)
    private let authorLabel = UILabel()
    private let bodyLabel = UILabel()
    private let media = MediaContentView(compact: true)
    private var inner: QuotedPostView?
    private let stack = UIStackView()

    private static let insets = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
    /// What one card's border and insets take from the width of the card inside it.
    static let nestingInset: CGFloat = 22

    init(layerNumber: Int = 1) {
        self.layerNumber = layerNumber
        super.init(frame: .zero)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The clips this card and the cards inside it show, outermost first.
    var videoSurfaces: [MediaContentView] {
        let own = (post == nil || isHidden || media.isHidden) ? [] : [media]
        return own + (inner?.videoSurfaces ?? [])
    }

    func pauseVideo() {
        media.pauseVideo()
        inner?.pauseVideo()
    }

    func releaseVideo() {
        media.releaseVideo()
        inner?.releaseVideo()
    }

    /// Re-resolves the text font after a change of the app's text size.
    func refreshFonts() {
        bodyLabel.font = DesignSystem.Typography.metric()
        inner?.refreshFonts()
    }

    func prepareForReuse() {
        post = nil
        avatar.cancel()
        media.prepareForReuse()
        onTap = nil
        inner?.prepareForReuse()
    }

    /// Shows `quoted` and the posts it quotes. `contentWidth` is the width the
    /// card's own content has, which a card inside this one gets
    /// `nestingInset` less of.
    func configure(with quoted: Tweet, imagesEnabled: Bool, contentWidth: CGFloat) {
        post = quoted
        authorLabel.attributedText = Self.header(for: quoted)
        let body = TweetText.attributed(for: quoted, seen: false, font: DesignSystem.Typography.metric())
        bodyLabel.attributedText = body
        bodyLabel.isHidden = body.length == 0
        if imagesEnabled, let url = quoted.author.avatarURL.flatMap(URL.init) {
            avatar.load(url: url, targetSize: CGSize(width: avatarSize, height: avatarSize))
        } else {
            avatar.cancel()
            avatar.image = DesignSystem.icon("person.crop.circle.fill", pointSize: avatarSize - 2)
            avatar.tintColor = DesignSystem.Color.tertiaryLabel
        }
        media.onTapPhoto = { [weak self] _ in self?.tapped() }
        media.onTapCard = { [weak self] _ in self?.tapped() }
        media.configure(with: quoted, imagesEnabled: imagesEnabled, contentWidth: max(120, contentWidth))
        configureInner(quoted.quotedTweet, imagesEnabled: imagesEnabled, contentWidth: contentWidth - Self.nestingInset)
    }

    private func configureInner(_ quoted: Tweet?, imagesEnabled: Bool, contentWidth: CGFloat) {
        guard layerNumber < Tweet.maxQuoteLayers, let quoted else {
            inner?.isHidden = true
            inner?.prepareForReuse()
            return
        }
        let view = inner ?? makeInner()
        view.isHidden = false
        view.onTap = { [weak self] tapped in self?.onTap?(tapped) }
        view.configure(with: quoted, imagesEnabled: imagesEnabled, contentWidth: contentWidth)
    }

    private func makeInner() -> QuotedPostView {
        let made = QuotedPostView(layerNumber: layerNumber + 1)
        inner = made
        stack.addArrangedSubview(made)
        return made
    }

    private var avatarSize: CGFloat { layerNumber == 1 ? 18 : 16 }

    /// Deeper cards give their text less room, so the whole tree stays a
    /// glance rather than a page.
    private var bodyLines: Int { max(2, 5 - layerNumber) }

    private func build() {
        layer.cornerRadius = DesignSystem.Radius.control
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = DesignSystem.Color.separator.cgColor
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: QuotedPostView, _) in
            view.layer.borderColor = DesignSystem.Color.separator.cgColor
        }
        isUserInteractionEnabled = true
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))

        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.setRounded(avatarSize / 2)

        authorLabel.font = DesignSystem.Typography.handle()
        authorLabel.textColor = DesignSystem.Color.secondaryLabel
        authorLabel.numberOfLines = 1
        bodyLabel.font = DesignSystem.Typography.metric()
        bodyLabel.textColor = DesignSystem.Color.label
        bodyLabel.numberOfLines = bodyLines

        let authorRow = UIStackView(arrangedSubviews: [avatar, authorLabel, UIView()])
        authorRow.axis = .horizontal
        authorRow.spacing = 6
        authorRow.alignment = .center

        media.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(authorRow)
        stack.addArrangedSubview(bodyLabel)
        stack.addArrangedSubview(media)
        stack.axis = .vertical
        stack.spacing = 6
        addManaged(stack)
        stack.pinEdges(to: self, insets: Self.insets)
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: avatarSize),
            avatar.heightAnchor.constraint(equalToConstant: avatarSize),
        ])
    }

    @objc private func tapped() {
        if let post { onTap?(post) }
    }

    /// `Name` + a color-hashed `@handle` + a relative timestamp, the same
    /// fields the TUI's inline quote header shows.
    static func header(for quoted: Tweet) -> NSAttributedString {
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
        TwemojiText.substituteCachedEmoji(in: result, font: DesignSystem.Typography.handle())
        return result
    }
}
