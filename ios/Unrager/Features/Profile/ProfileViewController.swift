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

    /// The Replies tab: a sibling feed over `/api/sources/user/{handle}/replies`,
    /// created lazily on first switch. It carries its own copy of the profile
    /// header so the header stays visible (and scrolls naturally) on both tabs.
    private var repliesController: FeedViewController?
    private let repliesHeader = ProfileHeaderView()
    private var showingReplies = false

    private var headers: [ProfileHeaderView] { [profileHeader, repliesHeader] }

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
        }
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
    }

    private func loadProfile() {
        Task {
            do {
                async let me = AppEnvironment.shared.whoami()
                let profile = try await social.profile(handle: handle)
                user = profile.user
                isOwnProfile = await me?.handle.caseInsensitiveCompare(handle) == .orderedSame
                isFollowing = profile.followedByMe
                title = profile.user.name
                applyHeaderState()
                loadFlag(for: profile.user)
            } catch {
                AppLogger.shared.warn("profile load failed: \(error)", category: .profile)
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
    }

    #if DEBUG
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
        repliesController = controller
    }
}

/// The scrolling profile header, shared (as independent copies) by the Posts
/// and Replies tabs.
private final class ProfileHeaderView: UIView {
    private let avatar = AsyncImageView(frame: .zero)
    private let nameLabel = UILabel()
    private let handleLabel = UILabel()
    private let basedInLabel = UILabel()
    private let followingButton = UIButton(configuration: .plain())
    private let followersButton = UIButton(configuration: .plain())
    private let followButton = UIButton(configuration: .filled())
    private let briefButton = UIButton(configuration: .tinted())
    private let segment = UISegmentedControl(items: ["Posts", "Replies"])
    private let separator = UIView()

    var onBrief: (() -> Void)?
    var onFollowToggle: (() -> Void)?
    var onTapFollowers: (() -> Void)?
    var onTapFollowing: (() -> Void)?
    var onSegmentChange: ((Int) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = DesignSystem.Color.background
        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.setRounded(32)

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

        let topRow = UIStackView(arrangedSubviews: [avatar, text])
        topRow.axis = .horizontal
        topRow.spacing = DesignSystem.Spacing.m
        topRow.alignment = .center

        let counts = UIStackView(arrangedSubviews: [followingButton, followersButton, UIView()])
        counts.axis = .horizontal
        counts.spacing = DesignSystem.Spacing.l

        let actions = UIStackView(arrangedSubviews: [followButton, briefButton, UIView()])
        actions.axis = .horizontal
        actions.spacing = DesignSystem.Spacing.s

        let column = UIStackView(arrangedSubviews: [topRow, counts, actions, segment])
        column.axis = .vertical
        column.spacing = DesignSystem.Spacing.m
        column.alignment = .fill

        addManaged(column)
        separator.backgroundColor = DesignSystem.Color.separator
        addManaged(separator)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            avatar.widthAnchor.constraint(equalToConstant: 64),
            avatar.heightAnchor.constraint(equalToConstant: 64),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1.0 / max(1, UITraitCollection.current.displayScale)),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(with user: User) {
        nameLabel.text = user.name
        handleLabel.text = "@\(user.handle)"
        setCount(followingButton, count: user.following, label: "following")
        setCount(followersButton, count: user.followers, label: "followers")
        if AppSettings.imagesEnabled, let url = user.avatarURL.flatMap(URL.init) {
            avatar.load(url: url, targetSize: CGSize(width: 64, height: 64))
        }
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

    /// Shows "based in <flag> <country>" (the TUI's profile line) once the
    /// about-account lookup resolves; hidden when X carries no country.
    func setBasedIn(flag: String?, country: String?) {
        guard let country, !country.isEmpty else {
            basedInLabel.isHidden = true
            return
        }
        let flagPrefix = flag.map { "\($0) " } ?? ""
        basedInLabel.text = "based in \(flagPrefix)\(country)"
        basedInLabel.isHidden = false
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        UIFont.systemFont(ofSize: pointSize, weight: weight)
    }
}
