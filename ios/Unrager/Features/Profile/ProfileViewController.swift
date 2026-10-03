import Combine
import UIKit
import SafariServices
import UnragerKit

/// A user's profile: a scrolling header (avatar, name, handle, bio, location,
/// website and join date, tappable follower counts, follow button, "Brief"
/// LLM summary, and a Posts/Replies toggle) above the user's timeline.
/// Subclasses `FeedViewController` so the timeline reuses all the feed
/// machinery; the header rides along as a boundary supplementary item. The
/// Replies tab embeds a second feed backed by the server's tweets-and-replies
/// source (the TUI's `R` toggle).
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
    private var loadState = ProfileLoadState.loading
    private let moderation = ProfileModeration()
    private var measuredWidth: CGFloat = 0
    private var insights: ProfileInsights?
    private var profileCancellables = Set<AnyCancellable>()

    /// The Replies tab: a sibling feed over `/api/sources/user/{handle}/replies`,
    /// created lazily on first switch. It carries its own copy of the profile
    /// header so the header stays visible (and scrolls naturally) on both tabs.
    private var repliesController: ProfileRepliesFeedViewController?
    private let repliesHeader = ProfileHeaderView()

    /// The Media tab: every picture and clip from the account's own posts,
    /// built on first use like Replies and under its own copy of the header.
    private var mediaController: ProfileMediaViewController?
    private let mediaHeader = ProfileHeaderView()

    /// The three views under the header, in the order of its segment control.
    private enum Section: Int {
        case posts, replies, media
    }

    private var section = Section.posts

    private var headers: [ProfileHeaderView] { [profileHeader, repliesHeader, mediaHeader] }

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
        installMenu()
        moderation.onChange = { [weak self] in self?.applyHeaderState() }
        seedFromCache()
        loadProfile()
        viewModel.tweets
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tweets in self?.updateInsights(from: tweets) }
            .store(in: &profileCancellables)
        NotificationCenter.default.addObserver(
            self, selector: #selector(textSizeChanged), name: AppSettings.fontScaleDidChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(displayChanged), name: AppSettings.displayDidChange, object: nil)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            self.textSizeChanged()
        }
    }

    /// A new text size (the app's or the system's) redraws the header and the
    /// navigation title at it and re-measures both tabs' headers.
    @objc private func textSizeChanged() {
        for header in headers { header.applyFonts() }
        titleLabel.font = DesignSystem.Typography.name()
        titleLabel.sizeToFit()
        applyHeaderState()
        updateBanner(for: activeScrollView)
    }

    /// Images switched on or off in Settings: the banner and avatar follow.
    @objc private func displayChanged() {
        banner.configure(url: AppSettings.imagesEnabled ? user?.bannerURL.flatMap(URL.init) : nil,
                         handle: handle, imagesEnabled: AppSettings.imagesEnabled)
        applyHeaderState()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if view.bounds.width != measuredWidth {
            measuredWidth = view.bounds.width
            applyHeaderState()
        }
        updateBanner(for: activeScrollView)
    }

    /// A pull-to-refresh reloads the header (counts, follow state) along with
    /// the timeline, and asks again about an account that wasn't available.
    override func pullToRefresh() {
        super.pullToRefresh()
        loadProfile()
    }

    /// Draws the last account details saved for this handle at once, so the
    /// profile opens with its name, bio, counts and banner while the real
    /// request is on its way. A load that lands first wins, and the fresh
    /// account always replaces the seed.
    private func seedFromCache() {
        Task {
            guard let cached = await ProfileCache.shared.load(handle: handle),
                  user == nil, loadState == .loading else { return }
            user = cached.user
            loadState = .loaded
            isFollowing = cached.followedByMe
            isOwnProfile = AppEnvironment.shared.currentHandle?.caseInsensitiveCompare(handle) == .orderedSame
            title = cached.user.name
            titleLabel.text = cached.user.name
            titleLabel.sizeToFit()
            banner.configure(url: cached.user.bannerURL.flatMap(URL.init), handle: handle,
                             imagesEnabled: AppSettings.imagesEnabled)
            applyHeaderState()
            AppLogger.shared.debug("seeded @\(handle) header from cache", category: .profile)
        }
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
        header.onSegmentChange = { [weak self] index in self?.setSection(Section(rawValue: index) ?? .posts) }
        header.onRetry = { [weak self] in self?.loadProfile() }
        header.onTapMention = { [weak self] handle in self?.openMention(handle) }
        header.onTapHashtag = { [weak self] query in self?.openHashtagSearch(query) }
        header.onTapURL = { [weak self] url in self?.openInBrowser(url) }
        header.onTapTopPost = { [weak self] id in
            self?.navigationController?.pushViewController(ThreadViewController(tweetID: id), animated: true)
        }
    }

    /// Loads the account alone (the feed fetches the posts itself). A failure
    /// X won't change its mind about (suspended, missing, hidden) replaces the
    /// header; any other one leaves a loaded header as it was, or offers a
    /// Retry when there is none.
    private func loadProfile() {
        guard !profileLoadInFlight else { return }
        profileLoadInFlight = true
        if case .failed = loadState {
            loadState = .loading
            applyHeaderState()
        }
        Task {
            defer { profileLoadInFlight = false }
            do {
                async let me = AppEnvironment.shared.whoami()
                let profile = try await social.profile(handle: handle, includeTweets: false)
                user = profile.user
                loadState = .loaded
                ProfileCache.shared.save(user: profile.user, followedByMe: profile.followedByMe, handle: handle)
                banner.configure(url: profile.user.bannerURL.flatMap(URL.init), handle: handle,
                                 imagesEnabled: AppSettings.imagesEnabled)
                isOwnProfile = await me?.handle.caseInsensitiveCompare(handle) == .orderedSame
                isFollowing = profile.followedByMe
                title = profile.user.name
                titleLabel.text = profile.user.name
                titleLabel.sizeToFit()
                moderation.update(muting: profile.user.isMuting, blocking: profile.user.isBlocking)
                applyHeaderState()
                loadFlag(for: profile.user)
            } catch where error.isCancellation {
                AppLogger.shared.info("profile load for @\(handle) cancelled", category: .profile)
            } catch {
                AppLogger.shared.warn("profile load failed: \(error)", category: .profile)
                let failure = ProfileLoadState.failure(error)
                guard failure.isFinal || user == nil else { return }
                if failure.isFinal { clearAccount() }
                loadState = failure
                applyHeaderState()
            }
        }
    }

    /// Works out the Recent posts card from the posts loaded so far, and
    /// redraws the header only when it changed.
    private func updateInsights(from tweets: [Tweet]) {
        let updated = ProfileInsights.make(from: tweets)
        guard updated != insights else { return }
        insights = updated
        applyHeaderState()
    }

    /// Forgets an account that has gone away, so nothing of it stays on screen
    /// under the header's explanation.
    private func clearAccount() {
        user = nil
        isFollowing = nil
        basedIn = nil
        title = "@\(handle)"
        titleLabel.text = "@\(handle)"
        titleLabel.sizeToFit()
        banner.configure(url: nil, handle: handle, imagesEnabled: false)
    }

    /// Whether the viewer is shut out of a protected account's posts.
    private var postsLocked: Bool {
        guard let user, user.isProtected, !isOwnProfile else { return false }
        return isFollowing != true
    }

    /// Pushes the current user/follow/basedIn state into both header copies so
    /// the Posts and Replies tabs always show the same header.
    private func applyHeaderState() {
        guard isViewLoaded else { return }
        let width = view.bounds.width
        for header in headers {
            header.setState(loadState)
            if let user, loadState == .loaded { header.configure(with: user) }
            header.setFollowState(following: isFollowing, isOwnProfile: isOwnProfile)
            header.setBasedIn(flag: basedIn?.flag, country: basedIn?.country)
            header.setModeration(muting: moderation.muting, blocking: moderation.blocking)
            header.setPostsLocked(postsLocked, handle: handle)
            header.setInsights(isOwnProfile && loadState == .loaded ? insights : nil)
            header.setModerationActions(accessibilityActions())
            header.setSegment(section.rawValue)
            header.placeActions(width: width)
        }
        let blank = loadState.isFinal || postsLocked
        hidesEmptyState = blank
        repliesController?.hidesEmptyState = blank
        mediaController?.hidesEmptyState = blank
        collectionView.collectionViewLayout.invalidateLayout()
        repliesController?.collectionView.collectionViewLayout.invalidateLayout()
        mediaController?.collectionView.collectionViewLayout.invalidateLayout()
    }

    /// Resolves the profiled user's country flag and shows the header's
    /// "based in <country>" line, mirroring the TUI's profile header. The
    /// header rides as a self-sizing boundary item, so its layout is
    /// invalidated for the extra line to be measured.
    private func loadFlag(for user: User) {
        AppEnvironment.shared.flags.resolve(restID: user.restID, screenName: user.handle) {
            [weak self] resolved in
            guard let self, resolved.country != nil, self.user?.restID == user.restID else { return }
            self.basedIn = (resolved.flag, resolved.country)
            self.applyHeaderState()
        }
    }

    // MARK: - Links

    private func openMention(_ mentioned: String) {
        guard mentioned.caseInsensitiveCompare(handle) != .orderedSame else { return }
        Haptics.selection()
        navigationController?.pushViewController(ProfileViewController(handle: mentioned), animated: true)
    }

    private func openHashtagSearch(_ query: String) {
        Haptics.selection()
        navigationController?.pushViewController(SearchResultsViewController(query: query, product: .top), animated: true)
    }

    /// Opens a web address from the bio or the website line in an in-app
    /// browser; anything else goes to the system.
    private func openInBrowser(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            UIApplication.shared.open(url)
            return
        }
        present(SFSafariViewController(url: url), animated: true)
    }

    // MARK: - Menu

    private var profileURL: URL? { URL(string: "https://x.com/\(handle)") }

    /// The navigation bar's menu: open in X and copy the link for any
    /// profile, then mute and block for someone else's once it has loaded.
    /// Built when opened, so its titles follow the current state.
    private func installMenu() {
        let menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self?.menuElements() ?? [])
        }])
        let item = UIBarButtonItem(image: DesignSystem.icon("ellipsis.circle"), menu: menu)
        item.accessibilityLabel = "More"
        navigationHost.navigationItem.rightBarButtonItem = item
    }

    private func menuElements() -> [UIMenuElement] {
        let open = UIAction(title: "Open in X", image: DesignSystem.icon("safari")) { [weak self] _ in
            if let url = self?.profileURL { UIApplication.shared.open(url) }
        }
        let copy = UIAction(title: "Copy link", image: DesignSystem.icon("link")) { [weak self] _ in
            self?.copyLink()
        }
        var elements: [UIMenuElement] = [open, copy]
        let moderationActions = moderationKinds.map { kind in
            let isOn = moderation.isOn(kind)
            let action = UIAction(title: ProfileModeration.title(for: kind, isOn: isOn, handle: handle),
                                  image: DesignSystem.icon(Self.symbol(for: kind, isOn: isOn))) { [weak self] _ in
                self?.requestModeration(kind)
            }
            if kind == .block, !isOn { action.attributes.insert(.destructive) }
            if moderation.isPending(kind) { action.attributes.insert(.disabled) }
            return action
        }
        if !moderationActions.isEmpty {
            elements.append(UIMenu(options: .displayInline, children: moderationActions))
        }
        return elements
    }

    /// Mute and block apply to someone else's account, once it has loaded.
    private var moderationKinds: [ProfileModeration.Kind] {
        guard loadState == .loaded, user != nil, !isOwnProfile else { return [] }
        return [.mute, .block]
    }

    private static func symbol(for kind: ProfileModeration.Kind, isOn: Bool) -> String {
        switch kind {
        case .mute: return isOn ? "speaker.wave.2" : "speaker.slash"
        case .block: return isOn ? "hand.raised.slash" : "hand.raised"
        }
    }

    /// The menu's mute and block, offered to VoiceOver on the header too.
    private func accessibilityActions() -> [UIAccessibilityCustomAction] {
        moderationKinds.map { kind in
            UIAccessibilityCustomAction(
                name: ProfileModeration.title(for: kind, isOn: moderation.isOn(kind), handle: handle)
            ) { [weak self] _ in
                self?.requestModeration(kind)
                return true
            }
        }
    }

    private func copyLink() {
        guard let url = profileURL else { return }
        UIPasteboard.general.url = url
        Haptics.success()
        showToast("Link copied")
    }

    /// Mutes or unmutes at once; blocking asks first, since it also ends any
    /// follow between the two accounts.
    private func requestModeration(_ kind: ProfileModeration.Kind) {
        guard kind == .block, !moderation.blocking else {
            applyModeration(kind)
            return
        }
        let sheet = UIAlertController(
            title: "Block @\(handle)?",
            message: "They won't be able to follow you or see your posts, and you won't see theirs.",
            preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Block @\(handle)", style: .destructive) { [weak self] _ in
            self?.applyModeration(.block)
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.barButtonItem = navigationHost.navigationItem.rightBarButtonItem
        present(sheet, animated: true)
    }

    /// Flips mute or block optimistically: the header's capsule and the menu
    /// change now, and a refusal puts them back and says why.
    private func applyModeration(_ kind: ProfileModeration.Kind) {
        guard let user else { return }
        let social = social
        let userID = user.restID
        let handle = handle
        Task {
            let outcome = await moderation.toggle(kind) { on in
                switch kind {
                case .mute: return try await social.setMuted(userID: userID, muted: on).muting
                case .block: return try await social.setBlocked(userID: userID, blocked: on).blocking
                }
            }
            switch outcome {
            case let .success(on)?:
                Haptics.success()
                if kind == .block, on, isFollowing == true { isFollowing = false }
                applyHeaderState()
                UIAccessibility.post(notification: .announcement,
                                     argument: ProfileModeration.confirmation(for: kind, isOn: on, handle: handle))
                AppLogger.shared.info("\(kind == .mute ? "mute" : "block") @\(handle) → \(on)", category: .profile)
            case let .failure(error)?:
                AppLogger.shared.warn("\(kind == .mute ? "mute" : "block") toggle failed: \(error)", category: .profile)
                guard !error.isCancellation else { return }
                Haptics.error()
                showToast(error.localizedDescription)
            case nil:
                break
            }
        }
    }

    // MARK: - Banner

    private var activeScrollView: UIScrollView {
        switch section {
        case .posts: return collectionView
        case .replies: return repliesController?.collectionView ?? collectionView
        case .media: return mediaController?.collectionView ?? collectionView
        }
    }

    private var activeHeader: ProfileHeaderView {
        switch section {
        case .posts: return profileHeader
        case .replies: return repliesHeader
        case .media: return mediaHeader
        }
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
        if navigationHost !== self {
            navigationHost.navigationItem.titleView = titleLabel
            navigationHost.setContentScrollView(collectionView, for: .top)
        }
        banner.onBrightnessChange = { [weak self] in self?.setNeedsStatusBarAppearanceUpdate() }
        let follow: (UIScrollView) -> Void = { [weak self] scrollView in self?.updateBanner(for: scrollView) }
        onScroll = follow
        repliesController?.onScroll = follow
        mediaController?.onScroll = follow
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
        let nameBottom = activeHeader.nameBottom
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

    private func setSection(_ newSection: Section) {
        guard newSection != section else { return }
        let outgoing = activeScrollView
        section = newSection
        Haptics.selection()
        if newSection == .replies { embedRepliesIfNeeded() }
        if newSection == .media { embedMediaIfNeeded() }
        alignIncomingTab(with: outgoing)
        collectionView.isHidden = newSection != .posts
        repliesController?.view.isHidden = newSection != .replies
        mediaController?.view.isHidden = newSection != .media
        settleVideoPlayback()
        repliesController?.settleVideoPlayback()
        applyHeaderState()
        navigationHost.setContentScrollView(activeScrollView, for: .top)
        updateBanner(for: activeScrollView)
    }

    /// Starts the tab being switched to where the segment control stays put:
    /// at the same scroll while the header is still partly in view, and no
    /// further than the header's end once it has scrolled away, so the
    /// control doesn't jump and the new tab opens at its top.
    private func alignIncomingTab(with outgoing: UIScrollView) {
        let incoming = activeScrollView
        guard incoming !== outgoing else { return }
        incoming.layoutIfNeeded()
        let header = headers.max { $0.bounds.height < $1.bounds.height } ?? profileHeader
        let headerHeight = header.bounds.height
        let inset = incoming.adjustedContentInset.top
        let headerEnd = headerHeight - inset - header.segmentHeight
        let target = min(outgoing.contentOffset.y, max(-inset, headerEnd))
        incoming.setContentOffset(CGPoint(x: 0, y: target), animated: false)
    }

    /// The controller the navigation stack actually shows: this one, or the
    /// container (the Profile tab) that embeds it. Its navigation item and
    /// scroll edge are the ones on screen.
    private var navigationHost: UIViewController {
        guard let parent, !(parent is UINavigationController) else { return self }
        return parent
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
        setSection(.replies)
        applyHeaderState()
    }

    /// Screenshot-QA hook: jumps straight to the Media tab.
    func debugShowMedia() {
        loadViewIfNeeded()
        setSection(.media)
        applyHeaderState()
    }

    /// Screenshot-QA hook: asks to block the account once it has loaded, as
    /// the menu's Block would.
    func debugRequestBlock() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.requestModeration(.block)
        }
    }
    #endif

    /// Builds the replies feed on first use: the same feed machinery over the
    /// tweets-and-replies source, with its own header copy riding on top.
    private func embedRepliesIfNeeded() {
        guard repliesController == nil else { return }
        let controller = ProfileRepliesFeedViewController(
            viewModel: TimelineViewModel(source: .user(handle: "\(handle)/replies")))
        controller.onPullToRefresh = { [weak self] in self?.loadProfile() }
        controller.headerView = repliesHeader
        addChild(controller)
        view.addManaged(controller.view)
        controller.view.pinEdges(to: view)
        controller.didMove(toParent: self)
        controller.view.backgroundColor = .clear
        controller.onScroll = { [weak self] scrollView in self?.updateBanner(for: scrollView) }
        controller.hidesEmptyState = hidesEmptyState
        repliesController = controller
    }

    /// Builds the Media tab on first use: its own grid under its own copy of
    /// the header.
    private func embedMediaIfNeeded() {
        guard mediaController == nil else { return }
        let controller = ProfileMediaViewController(handle: handle)
        controller.onPullToRefresh = { [weak self] in self?.loadProfile() }
        controller.headerView = mediaHeader
        addChild(controller)
        view.addManaged(controller.view)
        controller.view.pinEdges(to: view)
        controller.didMove(toParent: self)
        controller.view.backgroundColor = .clear
        controller.onScroll = { [weak self] scrollView in self?.updateBanner(for: scrollView) }
        controller.hidesEmptyState = hidesEmptyState
        mediaController = controller
    }
}

/// The Replies tab's feed: pulling it down refreshes the profile header too,
/// with a spinner that reads on the banner, like the Posts tab.
private final class ProfileRepliesFeedViewController: FeedViewController {
    var onPullToRefresh: (() -> Void)?

    override var refreshTextColor: UIColor { .white }

    override func pullToRefresh() {
        super.pullToRefresh()
        onPullToRefresh?()
    }
}
