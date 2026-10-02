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
    /// Fired by the repost menu's Repost / Undo repost item; the host flips
    /// the state optimistically via `applyRetweet` and confirms server-side.
    var onToggleRetweet: (() -> Void)?
    /// Fired by the repost menu's Quote item; opens the compose screen with a
    /// quote preview.
    var onQuote: (() -> Void)?
    var onToggleBookmark: (() -> Void)?
    var onShare: (() -> Void)?
    /// Fired by a press-and-hold on the like button. Enabled per-config via
    /// `enableLikers(_:)` — only where the viewer can actually see the likers
    /// (their own tweets), so a long-hold elsewhere leaves the tap-to-like intact.
    var onShowLikers: (() -> Void)?
    var onTapQuoted: (() -> Void)?
    /// Routes a tapped `@mention` to a profile, or `#hashtag` to search.
    var onTapMention: ((String) -> Void)?
    var onTapHashtag: ((String) -> Void)?
    /// Fired by the "Show more" affordance under a truncated feed body; the
    /// feed re-renders this row with the full text.
    var onShowMore: (() -> Void)?
    /// Fired by a tap on the views count: shows or hides the post's stats.
    var onToggleStats: (() -> Void)?
    /// Fired by a tap on the "Replying to" caption: opens the post being answered.
    var onTapReplyCaption: (() -> Void)?
    /// Fired by a tap on the "reposted" line above a repost: opens the
    /// reposter's profile.
    var onTapReposter: (() -> Void)?
    /// Set only on the signed-in account's own posts: VoiceOver's "Delete".
    var onDelete: (() -> Void)?
    /// Opens the list of posts quoting this one, offered from the repost menu
    /// and the stats strip's "Quotes" figure when the post has any.
    var onViewQuotes: (() -> Void)?

    private let repostRow = UIStackView()
    private let repostLabel = UILabel()
    /// The repost line the row shows ("Kit Wren reposted"), nil for a post
    /// that isn't a repost; VoiceOver reads it first.
    private var repostText: String?
    private let avatar = AsyncImageView(frame: .zero)
    private let nameLabel = UILabel()
    private let flagLabel = UILabel()
    private let verifiedBadge = UIImageView()
    private let replyCaption = LinkLabel()
    private let handleTimeLabel = UILabel()
    private let bodyView = LinkLabel()
    private let mediaContent = MediaContentView(compact: false)
    private let quotedContainer = UIView()
    private let quotedWrap = UIView()
    private let quotedAvatar = AsyncImageView(frame: .zero)
    private let quotedAuthorLabel = UILabel()
    private let quotedBodyLabel = UILabel()
    private let quotedMedia = MediaContentView(compact: true)
    private let actionBar = UIStackView()
    private let separator = HairlineView()
    private let threadRail = ThreadRailView()
    private var columnLeading: NSLayoutConstraint!
    private var railWidth: NSLayoutConstraint!

    private static let maxIndent = 3

    private let replyButton = ActionButton(symbol: "bubble.left")
    private let retweetButton = ActionButton(symbol: "arrow.2.squarepath")
    private let likeButton = ActionButton(symbol: "heart")
    private let bookmarkButton = ActionButton(symbol: "bookmark")
    private let shareButton = ActionButton(symbol: "square.and.arrow.up")
    private let viewsLabel = UILabel()
    private let viewsTap = UITapGestureRecognizer()
    private let statsView = PostStatsView()
    private var statsShown = false
    private let showMoreButton = TweetCell.makeShowMoreButton()
    private let likeLongPress = UILongPressGestureRecognizer()
    /// Live engagement state — the optimistic truth the cell currently shows,
    /// updated by `configure` and the `apply*` calls. Toggle handlers read
    /// these instead of the tweet captured at bind time, so tapping a menu
    /// item (e.g. "Undo repost") before the confirmed write-back reconfigures
    /// the row acts on what the user sees, not a stale snapshot.
    private(set) var isRetweeted = false
    private(set) var isLiked = false
    private(set) var isBookmarked = false
    /// The tweet this cell currently shows, so asynchronous results (a rollback
    /// after a slow failure) can tell whether the cell has since been reused.
    private(set) var tweetID: String?
    private var boundTweet: Tweet?
    private var shownLikeCount = 0
    private var shownRetweetCount = 0
    private var shownBookmarkCount = 0

    /// Feed-context body cap (v. the unlimited focal/thread rendering).
    static let feedBodyLineLimit = 10

    static let avatarSize: CGFloat = 36
    private static let sideMargin = DesignSystem.Spacing.l
    private static let sideInsets = NSDirectionalEdgeInsets(
        top: 0, leading: sideMargin, bottom: 0, trailing: sideMargin)

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = DesignSystem.Color.background
        contentView.isOpaque = true
        buildHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func preferredLayoutAttributesFitting(
        _ layoutAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
        PerfProbe.time("sizing") { super.preferredLayoutAttributesFitting(layoutAttributes) }
    }

    override func layoutSubviews() {
        PerfProbe.time("layout") { super.layoutSubviews() }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        tweetID = nil
        boundTweet = nil
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
        onToggleRetweet = nil
        onQuote = nil
        onToggleBookmark = nil
        onShare = nil
        onShowLikers = nil
        likeLongPress.isEnabled = false
        onTapQuoted = nil
        onTapMention = nil
        onTapHashtag = nil
        onShowMore = nil
        onToggleStats = nil
        statsView.isHidden = true
        statsShown = false
        onTapReplyCaption = nil
        replyCaption.capturesPlainTaps = false
        onTapReposter = nil
        onDelete = nil
        onViewQuotes = nil
        repostText = nil
        repostRow.isHidden = true
    }

    /// Inline-video playback control, driven by the feed so only the most-visible
    /// clip plays while at rest (and nothing plays mid-scroll).
    var hasVideo: Bool { mediaContent.hasVideo }
    /// The media surface, used as the source for the App Store–style zoom into
    /// the full-screen viewer.
    var mediaSourceView: UIView { mediaContent }
    /// The exact tapped photo tile, so the zoom grows from that image (not the
    /// whole grid) when a tweet has several pictures.
    func mediaSourceView(at index: Int) -> UIView? { mediaContent.photoSourceView(at: index) }
    func playVideo() { mediaContent.playVideo() }
    func pauseVideo() { mediaContent.pauseVideo() }
    func releaseVideo() {
        mediaContent.releaseVideo()
        quotedMedia.releaseVideo()
    }

    /// A reply's leading `@mentions` are taken out of its text and summed up in
    /// a caption (see `ReplyContext`): `impliedReplyHandles` holds the accounts
    /// whose posts the layout already shows it under, so it names only others,
    /// and is nil for a reply that stands alone, which names them all.
    /// `focal` switches the timestamp to an absolute one, the same emphasis the
    /// TUI gives the open tweet. `stats` opens the strip of figures under the
    /// action bar (nil keeps it closed). `bodyLineLimit` caps a
    /// note-length feed body behind a "Show more" affordance (0 = unlimited,
    /// the focal/thread rendering). `viewerHandle` is the signed-in account, so
    /// its own repost reads "You reposted".
    func configure(
        with tweet: Tweet, imagesEnabled: Bool, contentWidth: CGFloat,
        seen: Bool = false, impliedReplyHandles: Set<String>? = nil,
        focal: Bool = false, indentLevel: Int = 0,
        bodyLineLimit: Int = 0, stats: PostStatsContent? = nil,
        viewerHandle: String? = nil, pinned: Bool = false
    ) {
        tweetID = tweet.restID
        boundTweet = tweet
        statsShown = stats != nil
        applyFonts()
        setIndent(indentLevel)
        PerfProbe.time("cfg.name") {
            nameLabel.attributedText = TwemojiText.attributed(
                tweet.author.name, font: DesignSystem.Typography.name(), color: DesignSystem.Color.label)
        }
        setFlag(nil)
        verifiedBadge.isHidden = !tweet.author.verified
        configureRepost(for: tweet, viewerHandle: viewerHandle, pinned: pinned)
        configureReplyCaption(for: tweet, implied: impliedReplyHandles)
        handleTimeLabel.attributedText = Self.handleTime(tweet, absolute: focal)
        let body = PerfProbe.time("cfg.text") {
            TweetText.attributed(for: tweet, seen: seen, font: DesignSystem.Typography.body())
        }
        PerfProbe.time("cfg.limit") {
            applyBodyLimit(body, limit: bodyLineLimit, contentWidth: contentWidth - 2 * Self.sideMargin)
        }
        PerfProbe.time("cfg.body") { bodyView.attributedText = body }
        bodyView.isHidden = body.length == 0
        bodyView.onTapMention = { [weak self] in self?.onTapMention?($0) }
        bodyView.onTapHashtag = { [weak self] in self?.onTapHashtag?($0) }
        bodyView.onTapURL = { [weak self] in self?.onTapCard?($0) }
        contentView.alpha = seen ? 0.85 : 1

        PerfProbe.time("cfg.avatar") {
            loadAvatar(into: avatar, url: tweet.author.avatarURL, size: Self.avatarSize, fallbackPoint: 30,
                       enabled: imagesEnabled)
        }

        mediaContent.onTapPhoto = { [weak self] index in self?.onTapPhoto?(index) }
        mediaContent.onTapCard = { [weak self] url in self?.onTapCard?(url) }
        mediaContent.bleedsEdgeToEdge = indentLevel == 0
        PerfProbe.time("cfg.media") {
            mediaContent.configure(with: tweet, imagesEnabled: imagesEnabled, contentWidth: contentWidth)
        }

        PerfProbe.time("cfg.quote") {
            configureQuoted(tweet.quotedTweet, imagesEnabled: imagesEnabled,
                            contentWidth: contentWidth - 2 * Self.sideMargin - 22)
        }
        PerfProbe.time("cfg.actions") { configureActions(tweet) }
        configureStats(tweet, content: stats)
        pendingEmoji = TwemojiText.uncachedEmoji(in: [
            tweet.author.name, body.string, tweet.quotedTweet?.author.name ?? "", tweet.quotedTweet?.text ?? "",
        ])
        boundSeen = seen
        isAccessibilityElement = true
    }

    /// Shows or hides the stats strip under the action bar, and makes the views
    /// count tappable when a tap is how the strip opens.
    private func configureStats(_ tweet: Tweet, content: PostStatsContent?) {
        if let content {
            statsView.configure(tweet: tweet, content: content)
            statsView.isHidden = false
        } else {
            statsView.isHidden = true
        }
        viewsTap.isEnabled = AppSettings.postStatsMode == .onTap && (tweet.viewCount ?? 0) > 0
        viewsLabel.isUserInteractionEnabled = viewsTap.isEnabled
    }

    /// Shows the "reposted" line above the author of a repost, or takes it out
    /// of the column (no gap) for any other post.
    private func configureRepost(for tweet: Tweet, viewerHandle: String?, pinned: Bool) {
        repostText = RepostLine.text(for: tweet, viewerHandle: viewerHandle) ?? (pinned ? "Pinned" : nil)
        guard let repostText else {
            repostRow.isHidden = true
            return
        }
        let line = Self.repostLineText(repostText, symbol: tweet.retweetedBy == nil ? "pin.fill" : "arrow.2.squarepath")
        repostLabel.attributedText = line.text
        repostRow.directionalLayoutMargins.leading = max(
            Self.sideMargin, Self.sideMargin + Self.avatarSize + DesignSystem.Spacing.m - line.leadWidth)
        repostRow.isHidden = false
    }

    /// The repost line's font: a small caption that follows Dynamic Type but,
    /// like the action bar's counts, stops at 20 pt.
    static func repostFont() -> UIFont {
        UIFontMetrics(forTextStyle: .footnote).scaledFont(
            for: DesignSystem.Typography.system(13, weight: .semibold), maximumPointSize: 20)
    }

    /// The repost symbol and `text` in the muted caption colour, and how wide
    /// the symbol and its gap are, so the words line up with the author's name
    /// while the symbol hangs to their left.
    private static func repostLineText(_ text: String, symbol: String) -> (text: NSAttributedString, leadWidth: CGFloat) {
        let font = repostFont()
        let color = DesignSystem.Color.secondaryLabel
        let result = NSMutableAttributedString()
        var leadWidth: CGFloat = 0
        if let glyph = UIImage(systemName: symbol,
                               withConfiguration: UIImage.SymbolConfiguration(font: font, scale: .small))?
            .withTintColor(color, renderingMode: .alwaysOriginal) {
            result.append(NSAttributedString(attachment: NSTextAttachment(image: glyph)))
            let gap = NSAttributedString(string: "  ", attributes: [.font: font])
            result.append(gap)
            leadWidth = ceil(glyph.size.width + gap.size().width)
        }
        result.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        return (result, leadWidth)
    }

    /// Shows the small "Replying to @a" line above a reply's text, or hides it
    /// when the layout already says whom the reply is to.
    private func configureReplyCaption(for tweet: Tweet, implied: Set<String>?) {
        guard let caption = ReplyContext.caption(for: tweet, implied: implied) else {
            replyCaption.isHidden = true
            replyCaption.capturesPlainTaps = false
            return
        }
        replyCaption.attributedText = Self.captionText(for: caption)
        replyCaption.capturesPlainTaps = implied == nil && tweet.inReplyToTweetID != nil
        replyCaption.isHidden = false
    }

    /// The caption in the muted caption style, led by a small turn arrow, with
    /// each named account tinted and tappable like any other mention.
    private static func captionText(for caption: ReplyContext.Caption) -> NSAttributedString {
        let font = DesignSystem.Typography.caption()
        let result = NSMutableAttributedString()
        if let arrow = UIImage(systemName: "arrow.turn.up.left",
                               withConfiguration: UIImage.SymbolConfiguration(font: font, scale: .small))?
            .withTintColor(DesignSystem.Color.secondaryLabel, renderingMode: .alwaysOriginal) {
            result.append(NSAttributedString(attachment: NSTextAttachment(image: arrow)))
            result.append(NSAttributedString(string: " ", attributes: [.font: font]))
        }
        result.append(TweetText.attributed(
            for: ReplyContext.sentence(for: caption), urls: [], seen: true, font: font))
        return result
    }

    /// Re-resolves the fonts that were set once at build time, so a change of
    /// the app's text size reaches the name, flag and quote on rows that were
    /// already built rather than waiting for a relaunch.
    private func applyFonts() {
        quotedBodyLabel.font = DesignSystem.Typography.metric()
        [replyButton, retweetButton, likeButton, bookmarkButton].forEach { $0.refreshFont() }
    }

    /// Dims or restores the row for a changed read state without rebuilding it:
    /// only the body text and the row's opacity depend on it, and a full
    /// reconfigure would also tear down the photo grid and any playing video.
    func setSeen(_ seen: Bool) {
        guard let tweet = boundTweet else { return }
        let body = TweetText.attributed(
            for: tweet, seen: seen, font: DesignSystem.Typography.body())
        bodyView.attributedText = body
        contentView.alpha = seen ? 0.85 : 1
        boundSeen = seen
    }

    /// Collapses a note-length body to `limit` lines behind a tappable
    /// "Show more" (X's feed truncation). Only kicks in when the full text
    /// meaningfully exceeds the cap — truncating to reclaim a line or two
    /// would make "Show more" feel like a cheat — and measures against the
    /// row's real text width so the decision matches what renders.
    private func applyBodyLimit(_ body: NSAttributedString, limit: Int, contentWidth: CGFloat) {
        guard limit > 0, Self.mayExceedLimit(body.string, limit: limit),
              Self.bodyExceedsLimit(body, limit: limit, contentWidth: contentWidth) else {
            setBodyLines(0, truncating: false)
            showMoreButton.isHidden = true
            return
        }
        setBodyLines(limit, truncating: true)
        showMoreButton.isHidden = false
    }

    /// Caps the body at `lines` (0 = unlimited) and makes it measure again, so
    /// "Show more" reveals the rest of the text.
    private func setBodyLines(_ lines: Int, truncating: Bool) {
        bodyView.numberOfLines = lines
        bodyView.lineBreakMode = truncating ? .byTruncatingTail : .byWordWrapping
        bodyView.invalidateIntrinsicContentSize()
    }

    /// A cheap test that rules out the many posts too short to reach `limit`
    /// lines, so only long ones pay for measuring the text.
    static func mayExceedLimit(_ text: String, limit: Int) -> Bool {
        guard !text.isEmpty else { return false }
        let characters = text.utf16.count
        guard characters > limit * 20 else {
            return text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 } >= limit / 2
        }
        return true
    }

    /// Whether `body` renders meaningfully past `limit` lines at `contentWidth`
    /// — the +2 slack keeps "Show more" from hiding a mere line or two. Line
    /// count divides the measured height by the full per-line advance
    /// (lineHeight + leading, matching `.usesFontLeading`).
    static func bodyExceedsLimit(_ body: NSAttributedString, limit: Int, contentWidth: CGFloat) -> Bool {
        let prefix = measuredPrefix(of: body, limit: limit)
        if linesNeeded(by: prefix, contentWidth: contentWidth) > limit + 2 { return true }
        guard prefix.length < body.length else { return false }
        return linesNeeded(by: body, contentWidth: contentWidth) > limit + 2
    }

    /// The start of `body` long enough to fill `limit` + 3 lines at any width
    /// a phone shows, so a long Note is measured by its head instead of all of
    /// it on the main thread; the cut never splits a character.
    private static func measuredPrefix(of body: NSAttributedString, limit: Int) -> NSAttributedString {
        let budget = (limit + 3) * 120
        guard body.length > budget else { return body }
        let cut = (body.string as NSString).rangeOfComposedCharacterSequence(at: budget).location
        return body.attributedSubstring(from: NSRange(location: 0, length: cut))
    }

    private static func linesNeeded(by text: NSAttributedString, contentWidth: CGFloat) -> Int {
        let bounds = text.boundingRect(
            with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        let font = DesignSystem.Typography.body()
        let lineAdvance = max(1, font.lineHeight + max(0, font.leading))
        return Int((bounds.height / lineAdvance).rounded())
    }

    /// Shows (or clears) the author's country flag directly after the display
    /// name, mirroring the TUI's name-line flag. Safe to call on a visible
    /// cell — the header is a fixed single line, so no height change and no
    /// snapshot churn.
    func setFlag(_ flag: String?) {
        flagLabel.attributedText = flag.map {
            TwemojiText.attributed($0, font: DesignSystem.Typography.name(), color: DesignSystem.Color.label)
        }
        flagLabel.isHidden = (flag ?? "").isEmpty
        if let flag { pendingEmoji.formUnion(TwemojiText.uncachedEmoji(in: [flag])) }
    }

    /// Emoji the row shows as system glyphs because their Twemoji art was not
    /// in memory when it was built.
    private var pendingEmoji: Set<String> = []

    /// Whether Twemoji art that arrived since the row was built would change
    /// it, so a feed re-renders only those rows (a re-render elsewhere would
    /// rebuild photos for nothing).
    var awaitsLoadedEmoji: Bool { TwemojiText.anyCached(pendingEmoji) }

    /// Indents the card by reply depth so a reply-to-a-reply sits further right
    /// than a reply-to-the-root; level 0 (feed / root / focal) is flush. A thin
    /// gutter spine ties consecutive nested replies together. Threads pass a
    /// depth; the postcard renders flat and never calls this.
    func setIndent(_ level: Int) {
        let clamped = min(max(0, level), Self.maxIndent)
        guard threadRail.level != clamped || columnLeading.constant != CGFloat(clamped) * ThreadRailView.step else {
            return
        }
        columnLeading.constant = CGFloat(clamped) * ThreadRailView.step
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
            quotedWrap.isHidden = true
            quotedMedia.prepareForReuse()
            quotedMedia.isHidden = true
            return
        }
        quotedWrap.isHidden = false
        quotedAuthorLabel.attributedText = Self.quotedHeader(quoted)
        let quotedBody = TweetText.attributed(for: quoted, seen: false, font: DesignSystem.Typography.metric())
        quotedBodyLabel.attributedText = quotedBody
        quotedBodyLabel.isHidden = quotedBody.length == 0
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
        TwemojiText.substituteCachedEmoji(in: result, font: DesignSystem.Typography.handle())
        return result
    }

    private func configureActions(_ tweet: Tweet) {
        PerfProbe.time("act.reply") { replyButton.set(title: label(tweet.replyCount)) }
        PerfProbe.time("act.views") {
            viewsLabel.attributedText = Self.viewsText(tweet.viewCount, active: statsShown)
        }
        PerfProbe.time("act.like") { applyLike(favorited: tweet.favorited, count: tweet.likeCount) }
        PerfProbe.time("act.rt") { applyRetweet(retweeted: tweet.retweeted, count: tweet.retweetCount) }
        PerfProbe.time("act.bm") { applyBookmark(bookmarked: tweet.bookmarked, count: tweet.bookmarkCount) }
    }

    private nonisolated(unsafe) static var glyphs: [String: UIImage] = [:]

    /// The action bar's 15 pt glyph for `name`, built once: a symbol image is
    /// rebuilt from its configuration every time otherwise, for every button of
    /// every row that scrolls into view.
    private static func glyph(_ name: String) -> UIImage? {
        if let cached = glyphs[name] { return cached }
        let made = DesignSystem.icon(name, pointSize: 15)
        glyphs[name] = made
        return made
    }

    /// The passive views metric — a glyph + count rendered as plain text, so it
    /// doesn't masquerade as a tappable button in the action row.
    private static func viewsText(_ count: Int?, active: Bool) -> NSAttributedString? {
        guard let count, count > 0 else { return nil }
        let result = NSMutableAttributedString()
        let tint = active ? DesignSystem.Color.accent : DesignSystem.Color.secondaryLabel
        if let glyph = DesignSystem.icon("chart.bar", pointSize: 12)?
            .withTintColor(tint, renderingMode: .alwaysOriginal) {
            let attachment = NSTextAttachment(image: glyph)
            attachment.bounds = CGRect(x: 0, y: -1.5, width: glyph.size.width, height: glyph.size.height)
            result.append(NSAttributedString(attachment: attachment))
            result.append(NSAttributedString(string: " "))
        }
        result.append(NSAttributedString(string: Format.count(count), attributes: [
            .font: DesignSystem.Typography.actionMetric(),
            .foregroundColor: tint,
        ]))
        return result
    }

    /// Whether `kind` is on for the post as the row shows it now, and its count.
    func engagement(_ kind: Engagement.Kind) -> (on: Bool, count: Int) {
        switch kind {
        case .like: return (isLiked, shownLikeCount)
        case .repost: return (isRetweeted, shownRetweetCount)
        case .bookmark: return (isBookmarked, shownBookmarkCount)
        }
    }

    func applyEngagement(_ kind: Engagement.Kind, on: Bool, count: Int) {
        switch kind {
        case .like: applyLike(favorited: on, count: count)
        case .repost: applyRetweet(retweeted: on, count: count)
        case .bookmark: applyBookmark(bookmarked: on, count: count)
        }
    }

    /// Reflects an optimistic like toggle without re-running the full config —
    /// the feed calls this the instant the user taps so the heart fills before
    /// the network confirms.
    func applyLike(favorited: Bool, count: Int) {
        isLiked = favorited
        shownLikeCount = count
        likeButton.set(title: label(count), image: Self.glyph(favorited ? "heart.fill" : "heart"),
                       tint: favorited ? DesignSystem.Color.like : DesignSystem.Color.secondaryLabel)
    }

    /// Reflects an optimistic repost toggle: green tint while reposted (X's
    /// repost affordance), and keeps the deferred menu's Repost / Undo repost
    /// title in step. Called by `configure` and the instant the user picks the
    /// menu item, before the network confirms.
    func applyRetweet(retweeted: Bool, count: Int) {
        isRetweeted = retweeted
        shownRetweetCount = count
        retweetButton.set(title: label(count),
                          tint: retweeted ? DesignSystem.Color.retweet : DesignSystem.Color.secondaryLabel)
    }

    /// Reflects an optimistic bookmark toggle — filled accent glyph while
    /// bookmarked, matching the like/repost treatment.
    func applyBookmark(bookmarked: Bool, count: Int) {
        isBookmarked = bookmarked
        shownBookmarkCount = count
        bookmarkButton.set(title: label(count), image: Self.glyph(bookmarked ? "bookmark.fill" : "bookmark"),
                           tint: bookmarked ? DesignSystem.Color.accent : DesignSystem.Color.secondaryLabel)
    }

    /// ", replying to @a and @b" for a reply, whether or not the row shows the
    /// caption: VoiceOver has no thread layout to read it from.
    private func spokenReply(for tweet: Tweet) -> String {
        guard let caption = ReplyContext.caption(for: tweet, implied: nil) else { return "" }
        guard !caption.handles.isEmpty else { return ", replying" }
        let sentence = ReplyContext.sentence(for: caption)
        return ", " + sentence.prefix(1).lowercased() + sentence.dropFirst()
    }

    private func label(_ count: Int) -> String { count > 0 ? Format.count(count) : "" }

    nonisolated(unsafe) private static let spokenTime: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    private var boundSeen = false

    /// The row as one VoiceOver element — author, text, media, quote, counts and
    /// time read as a single utterance — built when an assistive technology
    /// asks, from what the row shows at that moment, so binding a row with
    /// VoiceOver off does none of this work.
    override var accessibilityLabel: String? {
        get { boundTweet.map(spokenSummary) }
        set {}
    }

    /// Every action a sighted user has on the row, offered as a custom action
    /// instead of ten separate stops with the author's name read three times.
    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get { boundTweet.map(customActions) }
        set {}
    }

    private func spokenSummary(of tweet: Tweet) -> String {
        let verified = tweet.author.verified ? ", verified" : ""
        let replying = spokenReply(for: tweet)
        let when = Self.spokenTime.localizedString(for: tweet.createdAt, relativeTo: Date())
        var parts = repostText.map { [$0] } ?? []
        parts.append("\(tweet.author.name)\(verified), @\(tweet.author.handle)\(replying), \(when)")
        let body = ReplyContext.body(of: tweet)
        if !body.isEmpty { parts.append(body) }
        if let media = Self.mediaSummary(tweet.media) { parts.append(media) }
        if let quoted = tweet.quotedTweet {
            parts.append("Quoting \(quoted.author.name): \(ReplyContext.body(of: quoted))")
        }
        var counts = ["\(tweet.replyCount) replies", "\(shownRetweetCount) reposts", "\(shownLikeCount) likes"]
        if let views = tweet.viewCount, views > 0 { counts.append("\(Format.count(views)) views") }
        parts.append(counts.joined(separator: ", "))
        var state: [String] = []
        if isLiked { state.append("liked") }
        if isRetweeted { state.append("reposted") }
        if isBookmarked { state.append("bookmarked") }
        if boundSeen { state.append("already seen") }
        if !state.isEmpty { parts.append(state.joined(separator: ", ")) }
        return parts.joined(separator: ". ")
    }

    private static func mediaSummary(_ media: [Media]) -> String? {
        let photos = media.filter { if case .photo = $0.kind { return true } else { return false } }
        if !photos.isEmpty {
            let described = photos.enumerated().compactMap { index, photo in
                photo.altText.flatMap { $0.isEmpty ? nil : "Photo \(index + 1): \($0)" }
            }
            let head = photos.count == 1 ? "1 photo" : "\(photos.count) photos"
            return ([head] + described).joined(separator: ". ")
        }
        guard let first = media.first else { return nil }
        switch first.kind {
        case .video: return "Video"
        case .animatedGif: return "GIF"
        case .poll(let options, _, _): return "Poll with \(options.count) options"
        case .linkCard(let title, _, let domain, _): return "Link from \(domain): \(title)"
        case .article(_, let title, _): return "Article: \(title)"
        case .broadcast(_, let title, _, _): return "Broadcast: \(title)"
        case .youTube: return "YouTube video"
        case .photo: return nil
        }
    }

    private func customActions(for tweet: Tweet) -> [UIAccessibilityCustomAction] {
        func action(_ name: String, _ run: @escaping () -> Void) -> UIAccessibilityCustomAction {
            UIAccessibilityCustomAction(name: name) { _ in run(); return true }
        }
        var actions = [
            action("Reply") { [weak self] in self?.onReply?() },
            action(isLiked ? "Unlike" : "Like") { [weak self] in self?.onLike?() },
            action(isRetweeted ? "Undo repost" : "Repost") { [weak self] in self?.onToggleRetweet?() },
            action("Quote") { [weak self] in self?.onQuote?() },
            action(isBookmarked ? "Remove bookmark" : "Bookmark") { [weak self] in self?.onToggleBookmark?() },
            action("Share") { [weak self] in self?.onShare?() },
            action("Open \(tweet.author.name)'s profile") { [weak self] in self?.onTapAuthor?() },
        ]
        if let reposter = tweet.retweetedBy {
            actions.append(action("Open \(reposter.name)'s profile") { [weak self] in self?.onTapReposter?() })
        }
        let photoCount = tweet.media.filter { if case .photo = $0.kind { return true } else { return false } }.count
        for index in 0..<min(photoCount, 4) {
            actions.append(action(photoCount == 1 ? "View photo" : "View photo \(index + 1)") { [weak self] in
                self?.onTapPhoto?(index)
            })
        }
        if tweet.media.contains(where: { $0.isVideo }) {
            actions.append(action("Play video") { [weak self] in self?.onTapPhoto?(0) })
        }
        if onViewQuotes != nil, tweet.quoteCount > 0 {
            actions.append(action("View quotes") { [weak self] in self?.onViewQuotes?() })
        }
        if tweet.quotedTweet != nil {
            actions.append(action("Open quoted post") { [weak self] in self?.onTapQuoted?() })
        }
        if !showMoreButton.isHidden {
            actions.append(action("Show more") { [weak self] in self?.onShowMore?() })
        }
        if viewsTap.isEnabled {
            actions.append(action(statsShown ? "Hide stats" : "Show stats") { [weak self] in self?.onToggleStats?() })
        }
        if onDelete != nil {
            actions.append(action("Delete") { [weak self] in self?.onDelete?() })
        }
        return actions
    }

    // MARK: - Hierarchy

    /// The "reposted" line: muted, one line, tappable on its words only.
    private func buildRepostRow() {
        repostLabel.numberOfLines = 1
        repostLabel.lineBreakMode = .byTruncatingTail
        repostLabel.isUserInteractionEnabled = true
        repostLabel.isAccessibilityElement = false
        repostLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(reposterTapped)))
        repostRow.addArrangedSubview(repostLabel)
        repostRow.addArrangedSubview(UIView())
        repostRow.axis = .horizontal
        repostRow.isLayoutMarginsRelativeArrangement = true
        repostRow.directionalLayoutMargins = Self.sideInsets
        repostRow.isHidden = true
    }

    private func buildHierarchy() {
        buildRepostRow()
        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.setRounded(Self.avatarSize / 2)
        avatar.isUserInteractionEnabled = true
        avatar.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(authorTapped)))

        nameLabel.font = DesignSystem.Typography.name()
        nameLabel.textColor = DesignSystem.Color.label
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        flagLabel.font = DesignSystem.Typography.name()
        flagLabel.setContentHuggingPriority(.required, for: .horizontal)
        flagLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        flagLabel.isHidden = true
        flagLabel.isAccessibilityElement = false

        verifiedBadge.image = DesignSystem.icon("checkmark.seal.fill", pointSize: 13)
        verifiedBadge.tintColor = DesignSystem.Color.verified
        verifiedBadge.setContentHuggingPriority(.required, for: .horizontal)
        verifiedBadge.setContentCompressionResistancePriority(.required, for: .horizontal)
        verifiedBadge.isAccessibilityElement = false

        replyCaption.isHidden = true
        replyCaption.textInsets = UIEdgeInsets(top: 0, left: Self.sideMargin, bottom: 0, right: Self.sideMargin)
        replyCaption.onTapPlain = { [weak self] in self?.onTapReplyCaption?() }
        replyCaption.onTapMention = { [weak self] in self?.onTapMention?($0) }

        handleTimeLabel.font = DesignSystem.Typography.handle()
        handleTimeLabel.textColor = DesignSystem.Color.secondaryLabel
        handleTimeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let nameRow = UIStackView(arrangedSubviews: [nameLabel, flagLabel, verifiedBadge, UIView()])
        nameRow.axis = .horizontal
        nameRow.spacing = 4
        nameRow.alignment = .center

        let identity = UIStackView(arrangedSubviews: [nameRow, handleTimeLabel])
        identity.axis = .vertical
        identity.spacing = 1

        let header = UIStackView(arrangedSubviews: [avatar, identity])
        header.axis = .horizontal
        header.spacing = DesignSystem.Spacing.m
        header.alignment = .center
        header.isLayoutMarginsRelativeArrangement = true
        header.directionalLayoutMargins = Self.sideInsets
        header.isAccessibilityElement = false

        mediaContent.translatesAutoresizingMaskIntoConstraints = false

        buildQuoted()

        viewsLabel.font = DesignSystem.Typography.actionMetric()
        viewsLabel.textColor = DesignSystem.Color.secondaryLabel
        viewsLabel.lineBreakMode = .byTruncatingTail
        viewsLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        actionBar.axis = .horizontal
        actionBar.distribution = .equalSpacing
        actionBar.isLayoutMarginsRelativeArrangement = true
        actionBar.directionalLayoutMargins = Self.sideInsets
        actionBar.addArrangedSubview(replyButton)
        actionBar.addArrangedSubview(retweetButton)
        actionBar.addArrangedSubview(likeButton)
        actionBar.addArrangedSubview(bookmarkButton)
        actionBar.addArrangedSubview(shareButton)
        actionBar.addArrangedSubview(viewsLabel)
        likeButton.addTarget(self, action: #selector(likeTapped), for: .touchUpInside)
        likeLongPress.addTarget(self, action: #selector(likeLongPressed))
        likeLongPress.isEnabled = false
        likeButton.addGestureRecognizer(likeLongPress)
        replyButton.addTarget(self, action: #selector(replyTapped), for: .touchUpInside)
        replyButton.accessibilityHint = "Reply to this post"
        bookmarkButton.addTarget(self, action: #selector(bookmarkTapped), for: .touchUpInside)
        shareButton.addTarget(self, action: #selector(shareTapped), for: .touchUpInside)
        configureRetweetMenu()

        showMoreButton.isHidden = true
        showMoreButton.addTarget(self, action: #selector(showMoreTapped), for: .touchUpInside)

        bodyView.textInsets = UIEdgeInsets(top: 0, left: Self.sideMargin, bottom: 0, right: Self.sideMargin)
        showMoreButton.configuration?.contentInsets = NSDirectionalEdgeInsets(
            top: 2, leading: Self.sideMargin, bottom: 2, trailing: Self.sideMargin)
        quotedWrap.addManaged(quotedContainer)
        quotedContainer.pinEdges(to: quotedWrap, insets: UIEdgeInsets(
            top: 0, left: Self.sideMargin, bottom: 0, right: Self.sideMargin))
        quotedWrap.isHidden = true

        viewsLabel.isUserInteractionEnabled = true
        viewsTap.addTarget(self, action: #selector(viewsTapped))
        viewsLabel.addGestureRecognizer(viewsTap)
        statsView.isHidden = true
        statsView.onTapQuotes = { [weak self] in self?.onViewQuotes?() }

        let column = UIStackView(arrangedSubviews: [repostRow, header, replyCaption, bodyView, showMoreButton, mediaContent, quotedWrap, actionBar, statsView])
        column.axis = .vertical
        column.spacing = DesignSystem.Spacing.s
        column.setCustomSpacing(DesignSystem.Spacing.xs, after: repostRow)
        column.setCustomSpacing(DesignSystem.Spacing.xs, after: replyCaption)
        column.setCustomSpacing(DesignSystem.Spacing.xs, after: bodyView)
        column.setCustomSpacing(DesignSystem.Spacing.xs, after: actionBar)

        contentView.addManaged(column)
        threadRail.isHidden = true
        contentView.addManaged(threadRail)
        contentView.addManaged(separator)

        let columnLeading = column.leadingAnchor.constraint(equalTo: contentView.leadingAnchor)
        self.columnLeading = columnLeading
        let railWidth = threadRail.widthAnchor.constraint(equalToConstant: 0)
        self.railWidth = railWidth

        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: Self.avatarSize),
            avatar.heightAnchor.constraint(equalToConstant: Self.avatarSize),

            threadRail.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: DesignSystem.Spacing.s),
            railWidth,
            threadRail.topAnchor.constraint(equalTo: contentView.topAnchor),
            threadRail.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            column.topAnchor.constraint(equalTo: contentView.topAnchor, constant: DesignSystem.Spacing.m),
            columnLeading,
            column.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            column.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -DesignSystem.Spacing.s),

            separator.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    private func buildQuoted() {
        quotedContainer.layer.cornerRadius = DesignSystem.Radius.control
        quotedContainer.layer.cornerCurve = .continuous
        quotedContainer.layer.borderWidth = 1
        quotedContainer.layer.borderColor = DesignSystem.Color.separator.cgColor
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (cell: TweetCell, _) in
            cell.quotedContainer.layer.borderColor = DesignSystem.Color.separator.cgColor
        }
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

    private static func makeShowMoreButton() -> UIButton {
        var config = UIButton.Configuration.plain()
        config.title = "Show more"
        config.baseForegroundColor = DesignSystem.Color.accent
        config.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var out = incoming
            out.font = DesignSystem.Typography.metric()
            return out
        }
        let button = UIButton(configuration: config)
        button.contentHorizontalAlignment = .leading
        button.accessibilityHint = "Shows the full post text"
        return button
    }

    /// The repost affordance: a tap opens Repost / Undo repost / Quote (X's
    /// repost sheet), never fires a blind toggle. Deferred + uncached so the
    /// first item's title always reflects the current repost state, including
    /// an optimistic flip made moments earlier.
    private func configureRetweetMenu() {
        retweetButton.accessibilityHint = "Shows repost and quote options"
        retweetButton.menuProvider = { [weak self] in
            guard let self else { return UIMenu() }
            let toggle = UIAction(
                title: self.isRetweeted ? "Undo repost" : "Repost",
                image: DesignSystem.icon("arrow.2.squarepath"),
                attributes: self.isRetweeted ? [.destructive] : []
            ) { [weak self] _ in
                Haptics.tap()
                self?.onToggleRetweet?()
            }
            let quote = UIAction(title: "Quote", image: DesignSystem.icon("quote.bubble")) { [weak self] _ in
                Haptics.tap()
                self?.onQuote?()
            }
            var items = [toggle, quote]
            if self.onViewQuotes != nil, let quotes = self.boundTweet?.quoteCount, quotes > 0 {
                items.append(UIAction(title: "View quotes", image: DesignSystem.icon("text.quote")) { [weak self] _ in
                    Haptics.tap()
                    self?.onViewQuotes?()
                })
            }
            return UIMenu(children: items)
        }
    }

    /// Expands the action buttons' effective touch target to the HIG's
    /// 44pt minimum without growing the visible row: a near-miss around the
    /// action bar routes to the button instead of falling through to the row
    /// (which would push the thread).
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let targets: [UIView] = [replyButton, retweetButton, likeButton, bookmarkButton, shareButton, viewsLabel,
                                 showMoreButton]
        for button in targets where !button.isHidden && button.window != nil && button.isUserInteractionEnabled {
            let local = button.convert(point, from: self)
            if button.point(inside: local, with: event) { break }
            let dx = max(0, (44 - button.bounds.width) / 2)
            let dy = max(0, (44 - button.bounds.height) / 2)
            if button.bounds.insetBy(dx: -dx, dy: -dy).contains(local) { return button }
        }
        return super.hitTest(point, with: event)
    }

    @objc private func viewsTapped() {
        Haptics.selection()
        onToggleStats?()
    }

    @objc private func authorTapped() { onTapAuthor?() }
    @objc private func reposterTapped() {
        guard let open = onTapReposter else { return }
        Haptics.selection()
        open()
    }
    @objc private func quotedTapped() { onTapQuoted?() }
    @objc private func showMoreTapped() {
        Haptics.tap()
        onShowMore?()
    }
    @objc private func replyTapped() {
        Haptics.tap()
        onReply?()
    }
    @objc private func likeTapped() {
        Haptics.tap()
        onLike?()
    }
    @objc private func bookmarkTapped() {
        Haptics.tap()
        onToggleBookmark?()
    }
    @objc private func shareTapped() {
        Haptics.tap()
        onShare?()
    }
    @objc private func likeLongPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        Haptics.tap()
        onShowLikers?()
    }

    /// Turns on the press-and-hold-for-likers gesture and installs its handler.
    /// Left off otherwise, so the like button's tap-to-like is untouched on
    /// tweets whose likers can't be shown.
    func enableLikers(_ handler: @escaping () -> Void) {
        onShowLikers = handler
        likeLongPress.isEnabled = true
    }

}
