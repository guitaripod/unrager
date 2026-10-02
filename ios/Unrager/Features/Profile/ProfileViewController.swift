import UIKit
import UnragerKit

/// A user's profile: a scrolling header (avatar, name, handle, tappable
/// follower counts, follow button, "Brief" LLM summary, and a Posts/Replies
/// toggle) above the user's timeline. Subclasses `FeedViewController` so the
/// timeline reuses all the feed machinery; the header rides along as a
/// boundary supplementary item. The Replies tab embeds a second feed backed
/// by the server's tweets-and-replies source (the TUI's `R` toggle).
final class ProfileViewController: FeedViewController {
    private let handle: String
    private let profileHeader = ProfileHeaderView()
    private let social = SocialAPI(baseURL: { AppSettings.serverURL })

    private var user: User?
    private var isFollowing: Bool?
    private var isOwnProfile = false
    private var basedIn: (flag: String?, country: String?)?
    private var followRequestInFlight = false
    private var profileLoadInFlight = false

    /// The Replies tab: a sibling feed over `/api/sources/user/{handle}/replies`,
    /// created lazily on first switch. It carries its own copy of the profile
    /// header so the header stays visible (and scrolls naturally) on both tabs.
    private var repliesController: FeedViewController?
    private let repliesHeader = ProfileHeaderView()
    private var showingReplies = false

    private var headers: [ProfileHeaderView] { [profileHeader, repliesHeader] }

    override var refreshTextColor: UIColor { .white }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        statusBarOverBanner && banner.prefersLightContent ? .lightContent : .default
    }

    private var statusBarOverBanner = true
    private let banner = ProfileBannerView()
    private let titleLabel = UILabel()

    init(handle: String) {
        self.handle = handle
        super.init(viewModel: TimelineViewModel(source: .user(handle: handle)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        headerView = profileHeader
        super.viewDidLoad()
        title = "@\(handle)"
        for header in headers {
            wire(header)
            header.setHandle(handle)
        }
        installBanner()
        loadProfile()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateBanner(for: activeScrollView)
    }

    /// A pull-to-refresh reloads the header (counts, follow state) along with
    /// the timeline.
    override func pullToRefresh() {
        super.pullToRefresh()
        loadProfile()
    }

    private func wire(_ header: ProfileHeaderView) {
        header.onBrief = { [weak self] in
            guard let self else { return }
            let api = AppEnvironment.shared.api
            let handle = self.handle
            self.presentStream(title: "Brief · @\(handle)") { api.briefStream(handle: handle) }
        }
        header.onFollowToggle = { [weak self] in self?.toggleFollow() }
        header.onTapFollowers = { [weak self] in self?.pushUserList(mode: .followers) }
        header.onTapFollowing = { [weak self] in self?.pushUserList(mode: .following) }
        header.onSegmentChange = { [weak self] index in self?.setShowingReplies(index == 1) }
        header.onRetry = { [weak self] in self?.loadProfile() }
    }

    private func loadProfile() {
        guard !profileLoadInFlight else { return }
        profileLoadInFlight = true
        for header in headers { header.setLoadFailed(false) }
        Task {
            defer { profileLoadInFlight = false }
            do {
                async let me = AppEnvironment.shared.whoami()
                let profile = try await social.profile(handle: handle)
                user = profile.user
                banner.configure(url: profile.user.bannerURL.flatMap(URL.init), handle: handle,
                                 imagesEnabled: AppSettings.imagesEnabled)
                isOwnProfile = await me?.handle.caseInsensitiveCompare(handle) == .orderedSame
                isFollowing = profile.followedByMe
                title = profile.user.name
                titleLabel.text = profile.user.name
                titleLabel.sizeToFit()
                applyHeaderState()
                loadFlag(for: profile.user)
            } catch {
                AppLogger.shared.warn("profile load failed: \(error)", category: .profile)
                if user == nil {
                    for header in headers { header.setLoadFailed(true) }
                    collectionView.collectionViewLayout.invalidateLayout()
                }
            }
        }
    }

    /// Pushes the current user/follow/basedIn state into both header copies so
    /// the Posts and Replies tabs always show the same header.
    private func applyHeaderState() {
        for header in headers {
            if let user { header.configure(with: user) }
            header.setFollowState(following: isFollowing, isOwnProfile: isOwnProfile)
            if let basedIn { header.setBasedIn(flag: basedIn.flag, country: basedIn.country) }
            header.setSegment(showingReplies ? 1 : 0)
        }
        collectionView.collectionViewLayout.invalidateLayout()
        repliesController?.collectionView.collectionViewLayout.invalidateLayout()
    }

    /// Resolves the profiled user's country flag and shows the header's
    /// "based in <country>" line, mirroring the TUI's profile header. The
    /// header rides as a self-sizing boundary item, so its layout is
    /// invalidated for the extra line to be measured.
    private func loadFlag(for user: User) {
        AppEnvironment.shared.flags.resolve(restID: user.restID, screenName: user.handle) {
            [weak self] resolved in
            guard let self, resolved.country != nil else { return }
            self.basedIn = (resolved.flag, resolved.country)
            self.applyHeaderState()
        }
    }

    // MARK: - Banner

    private var activeScrollView: UIScrollView {
        showingReplies ? (repliesController?.collectionView ?? collectionView) : collectionView
    }

    /// Parks the header image behind the feed, shows a placeholder wash until
    /// the profile arrives, and makes the navigation title a label that stays
    /// hidden until the name has scrolled away.
    private func installBanner() {
        view.insertSubview(banner, at: 0)
        banner.configure(url: nil, handle: handle, imagesEnabled: false)
        titleLabel.font = DesignSystem.Typography.name()
        titleLabel.textColor = DesignSystem.Color.label
        titleLabel.text = "@\(handle)"
        titleLabel.sizeToFit()
        titleLabel.alpha = 0
        navigationItem.titleView = titleLabel
        banner.onBrightnessChange = { [weak self] in self?.setNeedsStatusBarAppearanceUpdate() }
        let follow: (UIScrollView) -> Void = { [weak self] scrollView in self?.updateBanner(for: scrollView) }
        onScroll = follow
        repliesController?.onScroll = follow
    }

    /// Plays the banner, the avatar and the navigation title to where
    /// `scrollView`'s position puts them. Only the tab on screen drives it.
    private func updateBanner(for scrollView: UIScrollView) {
        guard scrollView === activeScrollView, isViewLoaded else { return }
        let safeTop = scrollView.adjustedContentInset.top
        let scroll = scrollView.contentOffset.y + safeTop
        let motion = ProfileBannerMotion.at(scroll: scroll, safeTop: safeTop, visible: ProfileHeaderView.bannerHeight)
        banner.apply(motion)
        let overBanner = scroll < safeTop + ProfileHeaderView.bannerHeight - 60
        if overBanner != statusBarOverBanner {
            statusBarOverBanner = overBanner
            setNeedsStatusBarAppearanceUpdate()
        }
        for header in headers { header.setAvatar(scale: motion.avatarScale, alpha: motion.avatarAlpha) }
        let nameBottom = (showingReplies ? repliesHeader : profileHeader).nameBottom
        titleLabel.alpha = ProfileBannerMotion.titleAlpha(scroll: scroll, nameBottom: nameBottom)
    }

    // MARK: - Follow

    /// Optimistic follow/unfollow: the button flips immediately, the request
    /// confirms it, and a failure rolls back with an error haptic.
    private func toggleFollow() {
        guard let user, let current = isFollowing, !followRequestInFlight else { return }
        let target = !current
        followRequestInFlight = true
        isFollowing = target
        applyHeaderState()
        Haptics.tap()
        Task {
            defer { followRequestInFlight = false }
            do {
                let result = target
                    ? try await social.follow(userID: user.restID)
                    : try await social.unfollow(userID: user.restID)
                isFollowing = result.following
                applyHeaderState()
                AppLogger.shared.info("\(target ? "followed" : "unfollowed") @\(user.handle)", category: .profile)
            } catch {
                isFollowing = current
                applyHeaderState()
                Haptics.error()
                AppLogger.shared.warn("follow toggle failed: \(error)", category: .profile)
            }
        }
    }

    private func pushUserList(mode: UserListViewController.Mode) {
        guard let user else { return }
        navigationController?.pushViewController(
            UserListViewController(user: user, mode: mode), animated: true)
    }

    // MARK: - Posts / Replies toggle

    private func setShowingReplies(_ replies: Bool) {
        guard replies != showingReplies else { return }
        showingReplies = replies
        Haptics.selection()
        if replies { embedRepliesIfNeeded() }
        repliesController?.view.isHidden = !replies
        collectionView.isHidden = replies
        applyHeaderState()
        setContentScrollView(activeScrollView, for: .top)
        updateBanner(for: activeScrollView)
    }

    #if DEBUG
    /// Screenshot-QA hook: scrolls `points` past the resting position (negative
    /// pulls the profile down) once the profile has had time to load.
    func debugScroll(by points: CGFloat) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self else { return }
            let scrollView = self.activeScrollView
            scrollView.setContentOffset(
                CGPoint(x: 0, y: points - scrollView.adjustedContentInset.top), animated: false)
            self.updateBanner(for: scrollView)
        }
    }

    /// Screenshot-QA hook: jumps straight to the Replies tab.
    func debugShowReplies() {
        loadViewIfNeeded()
        setShowingReplies(true)
        applyHeaderState()
    }
    #endif

    /// Builds the replies feed on first use: the same feed machinery over the
    /// tweets-and-replies source, with its own header copy riding on top.
    private func embedRepliesIfNeeded() {
        guard repliesController == nil else { return }
        let controller = FeedViewController(
            viewModel: TimelineViewModel(source: .user(handle: "\(handle)/replies")))
        controller.headerView = repliesHeader
        addChild(controller)
        view.addManaged(controller.view)
        controller.view.pinEdges(to: view)
        controller.didMove(toParent: self)
        controller.view.backgroundColor = .clear
        controller.onScroll = { [weak self] scrollView in self?.updateBanner(for: scrollView) }
        repliesController = controller
    }
}

/// The scrolling profile header, shared (as independent copies) by the Posts
/// and Replies tabs.
private final class ProfileHeaderView: UIView {
    /// How much of the header image shows below the navigation bar at rest.
    static let bannerHeight: CGFloat = 96
    private static let avatarSize: CGFloat = 76
    private static let avatarRing: CGFloat = 4

    private let avatar = AsyncImageView(frame: .zero)
    private let panel = UIView()
    private let nameLabel = UILabel()
    private let handleLabel = UILabel()
    private let basedInLabel = UILabel()
    private let followingButton = UIButton(configuration: .plain())
    private let followersButton = UIButton(configuration: .plain())
    private let followButton = UIButton(configuration: .filled())
    private let briefButton = UIButton(configuration: .tinted())
    private let segment = UISegmentedControl(items: ["Posts", "Replies"])
    private let separator = HairlineView()

    var onBrief: (() -> Void)?
    var onFollowToggle: (() -> Void)?
    var onTapFollowers: (() -> Void)?
    var onTapFollowing: (() -> Void)?
    var onSegmentChange: ((Int) -> Void)?
    var onRetry: (() -> Void)?
    private var basedIn: (flag: String?, country: String?)?
    private let retryButton = UIButton(configuration: .tinted())

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

        nameLabel.font = DesignSystem.Typography.title()
        nameLabel.textColor = DesignSystem.Color.label
        nameLabel.numberOfLines = 1
        handleLabel.font = DesignSystem.Typography.handle()
        handleLabel.textColor = DesignSystem.Color.secondaryLabel
        basedInLabel.font = DesignSystem.Typography.metric()
        basedInLabel.textColor = DesignSystem.Color.secondaryLabel
        basedInLabel.isHidden = true

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
        followButton.addAction(UIAction { [weak self] _ in self?.onFollowToggle?() }, for: .touchUpInside)

        var config = UIButton.Configuration.tinted()
        config.title = "Brief"
        config.image = DesignSystem.icon("sparkles", pointSize: 14)
        config.imagePadding = 6
        config.cornerStyle = .capsule
        briefButton.configuration = config
        briefButton.addAction(UIAction { [weak self] _ in self?.onBrief?() }, for: .touchUpInside)

        segment.selectedSegmentIndex = 0
        segment.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onSegmentChange?(self.segment.selectedSegmentIndex)
        }, for: .valueChanged)
        segment.accessibilityLabel = "Timeline mode"

        let text = UIStackView(arrangedSubviews: [nameLabel, handleLabel, basedInLabel])
        text.axis = .vertical
        text.spacing = 2

        let counts = UIStackView(arrangedSubviews: [followingButton, followersButton, UIView()])
        counts.axis = .horizontal
        counts.spacing = DesignSystem.Spacing.l

        let actions = UIStackView(arrangedSubviews: [UIView(), followButton, briefButton])
        actions.axis = .horizontal
        actions.spacing = DesignSystem.Spacing.s
        actions.alignment = .center

        var retryConfig = UIButton.Configuration.tinted()
        retryConfig.title = "Couldn't load this profile — Retry"
        retryConfig.image = DesignSystem.icon("arrow.clockwise", pointSize: 13)
        retryConfig.imagePadding = 6
        retryConfig.cornerStyle = .capsule
        retryButton.configuration = retryConfig
        retryButton.isHidden = true
        retryButton.addAction(UIAction { [weak self] _ in self?.onRetry?() }, for: .touchUpInside)

        for button in [followingButton, followersButton, followButton, briefButton] {
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        }

        let column = UIStackView(arrangedSubviews: [actions, text, retryButton, counts, segment])
        column.axis = .vertical
        column.spacing = DesignSystem.Spacing.m
        column.alignment = .fill
        column.setCustomSpacing(DesignSystem.Spacing.s, after: actions)

        addManaged(panel)
        panel.addManaged(column)
        panel.addManaged(separator)
        addManaged(avatar)
        NotificationCenter.default.addObserver(
            self, selector: #selector(emojiLoaded), name: TwemojiCache.imagesDidLoad, object: nil)
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

    func setLoadFailed(_ failed: Bool) {
        retryButton.isHidden = !failed
    }

    func configure(with user: User) {
        nameLabel.attributedText = Self.nameText(for: user)
        nameLabel.accessibilityLabel = user.verified ? "\(user.name), verified" : user.name
        handleLabel.text = "@\(user.handle)"
        setCount(followingButton, count: user.following, label: "following")
        setCount(followersButton, count: user.followers, label: "followers")
        if AppSettings.imagesEnabled, let url = user.avatarURL.flatMap(URL.init) {
            avatar.load(url: url, targetSize: CGSize(width: Self.avatarSize, height: Self.avatarSize))
        }
    }

    /// The name in Twemoji art, followed by the verified seal for a verified
    /// account — an inline attachment, so it wraps with the name.
    private static func nameText(for user: User) -> NSAttributedString {
        let font = DesignSystem.Typography.title()
        let text = NSMutableAttributedString(attributedString: TwemojiText.attributed(
            user.name, font: font, color: DesignSystem.Color.label))
        guard user.verified,
              let seal = UIImage(systemName: "checkmark.seal.fill",
                                 withConfiguration: UIImage.SymbolConfiguration(font: font, scale: .small))?
                  .withTintColor(DesignSystem.Color.verified, renderingMode: .alwaysOriginal)
        else { return text }
        text.append(NSAttributedString(string: " "))
        text.append(NSAttributedString(attachment: NSTextAttachment(image: seal)))
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
    /// Hidden on the viewer's own profile and on servers that don't report
    /// the relationship (never guess).
    func setFollowState(following: Bool?, isOwnProfile: Bool) {
        guard !isOwnProfile, let following else {
            followButton.isHidden = true
            return
        }
        followButton.isHidden = false
        var config = followButton.configuration ?? .filled()
        config.cornerStyle = .capsule
        config.title = following ? "Following" : "Follow"
        config.baseBackgroundColor = following
            ? DesignSystem.Color.elevatedBackground
            : DesignSystem.Color.accent
        config.baseForegroundColor = following ? DesignSystem.Color.label : .white
        followButton.configuration = config
        followButton.accessibilityLabel = following ? "Following, tap to unfollow" : "Follow"
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
        guard let country, !country.isEmpty else {
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

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        UIFont.systemFont(ofSize: pointSize, weight: weight)
    }
}
