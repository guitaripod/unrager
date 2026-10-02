import UIKit
import UnragerKit

/// The scrolling profile header, shared (as independent copies) by the Posts
/// and Replies tabs. Every line that an account may not have (bio, location
/// line, "based in", the Muted/Blocked capsules) is hidden rather than left
/// empty, so it takes no space.
final class ProfileHeaderView: UIView {
    /// How much of the header image shows below the navigation bar at rest.
    static let bannerHeight: CGFloat = 96
    private static let avatarSize: CGFloat = 76
    private static let avatarRing: CGFloat = 4

    private let avatar = AsyncImageView(frame: .zero)
    private let panel = UIView()
    private let column = UIStackView()
    private let topRow = UIStackView()
    private let actions = UIStackView()
    private let nameLabel = UILabel()
    private let handleLabel = UILabel()
    private let basedInLabel = UILabel()
    private let badges = UIStackView()
    private let mutedBadge = ProfileBadge(text: "Muted", symbol: "speaker.slash.fill")
    private let blockedBadge = ProfileBadge(text: "Blocked", symbol: "hand.raised.fill")
    private let bioLabel = LinkLabel(frame: .zero)
    private let metaLabel = LinkLabel(frame: .zero)
    private let statusLabel = UILabel()
    private let lockedNotice = ProfileLockedNotice()
    private let followingButton = UIButton(configuration: .plain())
    private let followersButton = UIButton(configuration: .plain())
    private let followButton = UIButton(configuration: .filled())
    private let briefButton = UIButton(configuration: .tinted())
    private let segment = UISegmentedControl(items: ["Posts", "Replies", "Media"])
    private let separator = HairlineView()
    private let counts = UIStackView()
    private let retryButton = UIButton(configuration: .tinted())
    private let retryRow = UIStackView()
    private let insightsView = ProfileInsightsView()
    private let nameSkeleton = BarsSkeletonView(bars: [(0.5, 24)])
    private let detailSkeleton = BarsSkeletonView(
        bars: [(0.92, 14), (0.7, 14), (0.52, 14)], spacing: 8)

    var onBrief: (() -> Void)?
    var onFollowToggle: (() -> Void)?
    var onTapFollowers: (() -> Void)?
    var onTapFollowing: (() -> Void)?
    var onSegmentChange: ((Int) -> Void)?
    var onRetry: (() -> Void)?
    var onTapMention: ((String) -> Void)?
    var onTapHashtag: ((String) -> Void)?
    var onTapURL: ((URL) -> Void)?
    var onTapTopPost: ((String) -> Void)?

    private var user: User?
    private var state = ProfileLoadState.loading
    private var basedIn: (flag: String?, country: String?)?

    /// Where the Follow and Brief buttons sit: beside the avatar while they
    /// fit there, otherwise in a row of their own under the counts, one above
    /// the other when even a full row is too narrow.
    private enum ActionsPlacement {
        case beside
        case belowInRow
        case belowStacked
    }

    private var actionsPlacement = ActionsPlacement.beside

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        panel.backgroundColor = DesignSystem.Color.background
        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.setRounded(Self.avatarSize / 2)
        avatar.layer.borderWidth = Self.avatarRing
        avatar.layer.borderColor = DesignSystem.Color.background.cgColor
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: ProfileHeaderView, _) in
            view.avatar.layer.borderColor = DesignSystem.Color.background.cgColor
        }

        nameLabel.textColor = DesignSystem.Color.label
        nameLabel.numberOfLines = 0
        handleLabel.textColor = DesignSystem.Color.secondaryLabel
        basedInLabel.textColor = DesignSystem.Color.secondaryLabel
        basedInLabel.numberOfLines = 0
        basedInLabel.isHidden = true

        configureBadges()
        configureTextLinks()

        statusLabel.textColor = DesignSystem.Color.label
        statusLabel.numberOfLines = 0
        statusLabel.isHidden = true
        lockedNotice.isHidden = true

        for button in [followingButton, followersButton] {
            button.configuration?.contentInsets = .zero
            button.configuration?.baseForegroundColor = DesignSystem.Color.secondaryLabel
        }
        followingButton.addAction(UIAction { [weak self] _ in self?.onTapFollowing?() }, for: .touchUpInside)
        followersButton.addAction(UIAction { [weak self] _ in self?.onTapFollowers?() }, for: .touchUpInside)
        followingButton.accessibilityHint = "Shows the accounts this user follows"
        followersButton.accessibilityHint = "Shows this user's followers"

        followButton.isHidden = true
        followButton.configuration?.cornerStyle = .capsule
        followButton.configuration?.titleLineBreakMode = .byTruncatingTail
        followButton.addAction(UIAction { [weak self] _ in self?.onFollowToggle?() }, for: .touchUpInside)

        var config = UIButton.Configuration.tinted()
        config.title = "Brief"
        config.image = DesignSystem.icon("sparkles", pointSize: 14)
        config.imagePadding = 6
        config.cornerStyle = .capsule
        config.titleLineBreakMode = .byTruncatingTail
        briefButton.configuration = config
        briefButton.addAction(UIAction { [weak self] _ in self?.onBrief?() }, for: .touchUpInside)

        segment.selectedSegmentIndex = 0
        segment.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onSegmentChange?(self.segment.selectedSegmentIndex)
        }, for: .valueChanged)
        segment.accessibilityLabel = "Timeline mode"

        let text = UIStackView(arrangedSubviews: [nameLabel, handleLabel, basedInLabel, badges])
        text.axis = .vertical
        text.spacing = 2
        text.setCustomSpacing(DesignSystem.Spacing.s, after: basedInLabel)
        text.setCustomSpacing(DesignSystem.Spacing.s, after: handleLabel)

        [followingButton, followersButton, UIView()].forEach(counts.addArrangedSubview)
        counts.spacing = DesignSystem.Spacing.l

        actions.axis = .horizontal
        actions.spacing = DesignSystem.Spacing.s
        actions.alignment = .center
        [followButton, briefButton].forEach(actions.addArrangedSubview)
        topRow.axis = .horizontal
        topRow.alignment = .center
        topRow.addArrangedSubview(UIView())
        topRow.addArrangedSubview(actions)

        var retryConfig = UIButton.Configuration.tinted()
        retryConfig.title = "Retry"
        retryConfig.image = DesignSystem.icon("arrow.clockwise", pointSize: 13)
        retryConfig.imagePadding = 6
        retryConfig.cornerStyle = .capsule
        retryButton.configuration = retryConfig
        retryButton.isHidden = true
        retryButton.addAction(UIAction { [weak self] _ in self?.onRetry?() }, for: .touchUpInside)
        [retryButton, UIView()].forEach(retryRow.addArrangedSubview)

        for button in [followingButton, followersButton, followButton, briefButton, retryButton] {
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        }
        topRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true

        [topRow, nameSkeleton, text, detailSkeleton, statusLabel, retryRow, bioLabel, metaLabel, counts, insightsView,
         segment, lockedNotice].forEach(column.addArrangedSubview)
        column.axis = .vertical
        column.spacing = DesignSystem.Spacing.m
        column.alignment = .fill
        column.setCustomSpacing(DesignSystem.Spacing.s, after: topRow)
        column.setCustomSpacing(DesignSystem.Spacing.s, after: bioLabel)
        retryRow.isHidden = true
        insightsView.isHidden = true
        insightsView.onTapTop = { [weak self] id in self?.onTapTopPost?(id) }

        addManaged(panel)
        panel.addManaged(column)
        panel.addManaged(separator)
        addManaged(avatar)
        NotificationCenter.default.addObserver(
            self, selector: #selector(emojiLoaded), name: TwemojiCache.imagesDidLoad, object: nil)
        applyFonts()
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: topAnchor, constant: Self.bannerHeight),
            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.topAnchor.constraint(equalTo: panel.topAnchor, constant: DesignSystem.Spacing.s),
            column.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            column.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),
            column.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -12),
            avatar.widthAnchor.constraint(equalToConstant: Self.avatarSize),
            avatar.heightAnchor.constraint(equalToConstant: Self.avatarSize),
            avatar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            avatar.centerYAnchor.constraint(equalTo: panel.topAnchor),
            separator.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func configureBadges() {
        badges.axis = .horizontal
        badges.spacing = DesignSystem.Spacing.xs
        badges.alignment = .center
        [mutedBadge, blockedBadge, UIView()].forEach(badges.addArrangedSubview)
        mutedBadge.isHidden = true
        blockedBadge.isHidden = true
        badges.isHidden = true
    }

    /// The bio and the website line hand their taps to the screen.
    private func configureTextLinks() {
        for label in [bioLabel, metaLabel] {
            label.numberOfLines = 0
            label.isHidden = true
            label.onTapMention = { [weak self] handle in self?.onTapMention?(handle) }
            label.onTapHashtag = { [weak self] query in self?.onTapHashtag?(query) }
            label.onTapURL = { [weak self] url in self?.onTapURL?(url) }
        }
    }

    /// Re-resolves every font from the current text size; the caller then
    /// redraws the user's details (`configure`, `setBasedIn`) and re-measures.
    func applyFonts() {
        nameLabel.font = DesignSystem.Typography.title()
        handleLabel.font = DesignSystem.Typography.handle()
        basedInLabel.font = DesignSystem.Typography.metric()
        statusLabel.font = DesignSystem.Typography.body()
        mutedBadge.applyFonts()
        blockedBadge.applyFonts()
        lockedNotice.applyFonts()
        let stacked = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        counts.axis = stacked ? .vertical : .horizontal
        counts.alignment = stacked ? .leading : .fill
        counts.spacing = stacked ? 0 : DesignSystem.Spacing.l
        if let basedIn { setBasedIn(flag: basedIn.flag, country: basedIn.country) }
        if let user { configure(with: user) }
    }

    /// Where the name ends, measured from the top of the header: the scroll
    /// distance at which it slides under the navigation bar.
    var nameBottom: CGFloat {
        layoutIfNeeded()
        return nameLabel.convert(nameLabel.bounds, to: self).maxY
    }

    /// Shrinks the avatar toward its bottom-left as the profile scrolls, so it
    /// settles into the header instead of sliding under the bar at full size.
    func setAvatar(scale: CGFloat, alpha: CGFloat) {
        let half = Self.avatarSize / 2
        avatar.transform = CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: -half * (1 - scale), y: half * (1 - scale)))
        avatar.alpha = alpha
    }

    /// Shows the handle straight away, before the profile request lands.
    func setHandle(_ handle: String) {
        handleLabel.text = "@\(handle)"
    }

    /// Shows the account, or in its place why it can't be shown: a final
    /// state hides everything that belongs to an account (counts, bio,
    /// buttons, the Posts/Replies control); a failure that may clear adds a
    /// Retry.
    func setState(_ state: ProfileLoadState) {
        self.state = state
        let loaded = state == .loaded
        if !loaded {
            user = nil
            nameLabel.attributedText = nil
            nameLabel.accessibilityLabel = nil
            avatar.load(url: nil, targetSize: CGSize(width: Self.avatarSize, height: Self.avatarSize))
        }
        nameLabel.isHidden = !loaded
        nameSkeleton.isHidden = state != .loading
        detailSkeleton.isHidden = state != .loading
        statusLabel.text = state.message
        statusLabel.isHidden = state.message == nil
        retryRow.isHidden = !state.offersRetry
        retryButton.isHidden = !state.offersRetry
        counts.isHidden = !loaded
        briefButton.isHidden = state.isFinal
        segment.isHidden = state.isFinal
        if !loaded {
            bioLabel.isHidden = true
            metaLabel.isHidden = true
        }
    }

    func configure(with user: User) {
        self.user = user
        nameLabel.attributedText = Self.nameText(for: user)
        nameLabel.accessibilityLabel = [user.name, user.verified ? "verified" : nil,
                                        user.isProtected ? "protected account" : nil]
            .compactMap { $0 }.joined(separator: ", ")
        handleLabel.text = "@\(user.handle)"
        setCount(followingButton, count: user.following, label: "following")
        setCount(followersButton, count: user.followers, label: "followers")
        let url = AppSettings.imagesEnabled ? user.avatarURL.flatMap(URL.init) : nil
        avatar.load(url: url, targetSize: CGSize(width: Self.avatarSize, height: Self.avatarSize))
        configureBio(user.bio)
        configureMeta(for: user)
    }

    /// The bio at the body text size, every line of it, with its mentions,
    /// tags and links tappable (and reachable as VoiceOver actions).
    private func configureBio(_ bio: String?) {
        let text = bio?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            bioLabel.isHidden = true
            bioLabel.attributedText = nil
            return
        }
        let attributed = ProfileText.bio(text, font: DesignSystem.Typography.body())
        bioLabel.attributedText = attributed
        bioLabel.accessibilityLabel = attributed.string
        bioLabel.accessibilityCustomActions = ProfileText.links(in: attributed).map { link in
            UIAccessibilityCustomAction(name: "Open \(link.name)") { [weak self] _ in
                self?.route(link.url)
                return true
            }
        }
        bioLabel.isHidden = false
    }

    private func configureMeta(for user: User) {
        guard let meta = ProfileText.meta(location: user.location, website: user.website,
                                          joinedAt: user.joinedAt, font: DesignSystem.Typography.metric()) else {
            metaLabel.isHidden = true
            metaLabel.attributedText = nil
            return
        }
        metaLabel.attributedText = meta
        metaLabel.accessibilityLabel = ProfileText.metaAccessibilityLabel(
            location: user.location, website: user.website, joinedAt: user.joinedAt)
        metaLabel.accessibilityCustomActions = user.website.flatMap(ProfileText.websiteURL).map { url in
            [UIAccessibilityCustomAction(name: "Open website") { [weak self] _ in
                self?.onTapURL?(url)
                return true
            }]
        } ?? []
        metaLabel.isHidden = false
    }

    /// Sends a tapped link's target to the matching handler, as a tap would.
    private func route(_ url: URL) {
        switch TweetText.Route.from(url) {
        case let .profile(handle): onTapMention?(handle)
        case let .hashtag(query): onTapHashtag?(query)
        case let .url(target): onTapURL?(target)
        case nil: break
        }
    }

    /// The name in Twemoji art, followed by the verified seal for a verified
    /// account and a lock for a protected one — inline attachments, so they
    /// wrap with the name.
    private static func nameText(for user: User) -> NSAttributedString {
        let font = DesignSystem.Typography.title()
        let text = NSMutableAttributedString(attributedString: TwemojiText.attributed(
            user.name, font: font, color: DesignSystem.Color.label))
        let symbol = UIImage.SymbolConfiguration(font: font, scale: .small)
        if user.verified,
           let seal = UIImage(systemName: "checkmark.seal.fill", withConfiguration: symbol)?
               .withTintColor(DesignSystem.Color.verified, renderingMode: .alwaysOriginal) {
            text.append(NSAttributedString(string: " "))
            text.append(NSAttributedString(attachment: NSTextAttachment(image: seal)))
        }
        if user.isProtected,
           let lock = UIImage(systemName: "lock.fill", withConfiguration: symbol)?
               .withTintColor(DesignSystem.Color.secondaryLabel, renderingMode: .alwaysOriginal) {
            text.append(NSAttributedString(string: " "))
            text.append(NSAttributedString(attachment: NSTextAttachment(image: lock)))
        }
        return text
    }

    /// A "1.2M followers" button: bold count, dim label — visibly one tap
    /// target, matching X's header grammar.
    private func setCount(_ button: UIButton, count: Int, label: String) {
        var text = AttributedString("\(Format.count(count)) ")
        text.font = DesignSystem.Typography.metric().withWeight(.bold)
        text.foregroundColor = DesignSystem.Color.label
        var suffix = AttributedString(label)
        suffix.font = DesignSystem.Typography.metric()
        suffix.foregroundColor = DesignSystem.Color.secondaryLabel
        text.append(suffix)
        button.configuration?.attributedTitle = text
        button.accessibilityLabel = "\(Format.count(count)) \(label)"
    }

    /// Shows the Follow/Following button once the relationship is known.
    /// Hidden on the viewer's own profile, on servers that don't report the
    /// relationship (never guess) and on an account that can't be shown.
    func setFollowState(following: Bool?, isOwnProfile: Bool) {
        guard !isOwnProfile, state == .loaded, let following else {
            followButton.isHidden = true
            return
        }
        followButton.isHidden = false
        var config = followButton.configuration ?? .filled()
        config.cornerStyle = .capsule
        config.titleLineBreakMode = .byTruncatingTail
        config.title = following ? "Following" : "Follow"
        config.baseBackgroundColor = following
            ? DesignSystem.Color.elevatedBackground
            : DesignSystem.Color.accent
        config.baseForegroundColor = following ? DesignSystem.Color.label : .white
        followButton.configuration = config
        followButton.accessibilityLabel = following ? "Following, tap to unfollow" : "Follow"
    }

    /// The small "Muted" / "Blocked" capsules under the handle, while true.
    func setModeration(muting: Bool, blocking: Bool) {
        let loaded = state == .loaded
        mutedBadge.isHidden = !(loaded && muting)
        blockedBadge.isHidden = !(loaded && blocking)
        badges.isHidden = mutedBadge.isHidden && blockedBadge.isHidden
    }

    /// The navigation menu's mute and block, offered on the name, where
    /// VoiceOver lands first.
    func setModerationActions(_ actions: [UIAccessibilityCustomAction]) {
        nameLabel.accessibilityCustomActions = actions
    }

    /// Says a protected account's posts are out of reach in place of the
    /// Posts/Replies control, which would only lead to nothing.
    func setPostsLocked(_ locked: Bool, handle: String) {
        let shown = locked && state == .loaded
        lockedNotice.isHidden = !shown
        if shown {
            lockedNotice.configure(handle: handle)
            segment.isHidden = true
        } else if !state.isFinal {
            segment.isHidden = false
        }
    }

    /// Puts the Follow and Brief buttons beside the avatar while they fit in
    /// the room it leaves at `width`, else under the counts, so a large text
    /// size never squeezes a title into hyphenated lines.
    func placeActions(width: CGFloat) {
        guard width > 0 else { return }
        let placement = Self.placement(neededWidth: actionsWidth(), headerWidth: width)
        guard placement != actionsPlacement else { return }
        actionsPlacement = placement
        actions.removeFromSuperview()
        switch placement {
        case .beside:
            actions.axis = .horizontal
            actions.alignment = .center
            topRow.addArrangedSubview(actions)
        case .belowInRow, .belowStacked:
            actions.axis = placement == .belowInRow ? .horizontal : .vertical
            actions.alignment = placement == .belowInRow ? .center : .leading
            let index = column.arrangedSubviews.firstIndex(of: counts).map { $0 + 1 } ?? column.arrangedSubviews.count
            column.insertArrangedSubview(actions, at: index)
        }
    }

    /// The width the visible buttons need side by side, on one line each.
    private func actionsWidth() -> CGFloat {
        let visible = [followButton, briefButton].filter { !$0.isHidden }
        guard !visible.isEmpty else { return 0 }
        let widths = visible.map { $0.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width }
        return widths.reduce(0, +) + actions.spacing * CGFloat(visible.count - 1)
    }

    private static func placement(neededWidth: CGFloat, headerWidth: CGFloat) -> ActionsPlacement {
        let row = headerWidth - 32
        let besideAvatar = row - avatarSize - DesignSystem.Spacing.m
        if neededWidth <= besideAvatar { return .beside }
        return neededWidth <= row ? .belowInRow : .belowStacked
    }

    /// The height of the Posts/Replies control and the margin under it: the
    /// part of the header that stays visible when switching tabs.
    var segmentHeight: CGFloat {
        segment.bounds.height + 12
    }

    /// Shows the Recent posts card, or takes it away when there is nothing
    /// to say or the account isn't the viewer's own.
    func setInsights(_ insights: ProfileInsights?) {
        guard let insights else {
            insightsView.isHidden = true
            return
        }
        insightsView.configure(with: insights)
        insightsView.isHidden = false
    }

    func setSegment(_ index: Int) {
        guard segment.selectedSegmentIndex != index else { return }
        segment.selectedSegmentIndex = index
    }

    /// Twemoji art for the flag landed after the line was first drawn.
    @objc private func emojiLoaded() {
        guard let basedIn else { return }
        setBasedIn(flag: basedIn.flag, country: basedIn.country)
    }

    /// Shows "based in <flag> <country>" (the TUI's profile line) once the
    /// about-account lookup resolves; hidden when X carries no country.
    func setBasedIn(flag: String?, country: String?) {
        basedIn = (flag, country)
        guard state == .loaded, let country, !country.isEmpty else {
            basedInLabel.isHidden = true
            return
        }
        let flagPrefix = flag.map { "\($0) " } ?? ""
        basedInLabel.attributedText = TwemojiText.attributed(
            "based in \(flagPrefix)\(country)", font: DesignSystem.Typography.metric(),
            color: DesignSystem.Color.secondaryLabel)
        basedInLabel.isHidden = false
    }
}

/// A small tinted capsule with a symbol and a word ("Muted", "Blocked").
private final class ProfileBadge: UIView {
    private let label = UILabel()
    private let symbol: String
    private let text: String

    init(text: String, symbol: String) {
        self.text = text
        self.symbol = symbol
        super.init(frame: .zero)
        backgroundColor = DesignSystem.Color.elevatedBackground
        layer.cornerCurve = .continuous
        label.textColor = DesignSystem.Color.secondaryLabel
        label.numberOfLines = 0
        addManaged(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DesignSystem.Spacing.s),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DesignSystem.Spacing.s),
        ])
        isAccessibilityElement = true
        accessibilityLabel = text
        applyFonts()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func applyFonts() {
        let font = DesignSystem.Typography.caption().withWeight(.semibold)
        let line = NSMutableAttributedString()
        if let image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(font: font, scale: .small))?
            .withTintColor(DesignSystem.Color.secondaryLabel, renderingMode: .alwaysOriginal) {
            line.append(NSAttributedString(attachment: NSTextAttachment(image: image)))
            line.append(NSAttributedString(string: " "))
        }
        line.append(NSAttributedString(string: text))
        line.addAttributes([.font: font, .foregroundColor: DesignSystem.Color.secondaryLabel],
                           range: NSRange(location: 0, length: line.length))
        label.attributedText = line
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = min(bounds.height / 2, 14)
    }
}

/// "These posts are protected": what a protected account's profile says to a
/// viewer it hasn't approved, in place of an empty timeline.
private final class ProfileLockedNotice: UIView {
    private let icon = UIImageView()
    private let title = UILabel()
    private let detail = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        icon.tintColor = DesignSystem.Color.tertiaryLabel
        icon.contentMode = .scaleAspectFit
        icon.setContentHuggingPriority(.required, for: .vertical)
        title.text = "These posts are protected"
        title.textColor = DesignSystem.Color.label
        title.textAlignment = .center
        title.numberOfLines = 0
        detail.textColor = DesignSystem.Color.secondaryLabel
        detail.textAlignment = .center
        detail.numberOfLines = 0
        let stack = UIStackView(arrangedSubviews: [icon, title, detail])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = DesignSystem.Spacing.s
        addManaged(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: DesignSystem.Spacing.xl),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -DesignSystem.Spacing.l),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        shouldGroupAccessibilityChildren = true
        applyFonts()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func applyFonts() {
        icon.image = DesignSystem.icon("lock.fill", pointSize: 30)
        title.font = DesignSystem.Typography.name()
        detail.font = DesignSystem.Typography.metric()
    }

    func configure(handle: String) {
        detail.text = "Only people @\(handle) approves can see their posts. Follow to ask for access."
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        UIFont.systemFont(ofSize: pointSize, weight: weight)
    }
}
