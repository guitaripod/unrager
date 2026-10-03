import UIKit
import UnragerKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        AppSettings.migrateAppearanceIfNeeded()
        let window = UIWindow(windowScene: windowScene)
        window.overrideUserInterfaceStyle = UIUserInterfaceStyle(rawValue: AppSettings.appearance.rawValue) ?? .unspecified
        window.tintColor = DesignSystem.Color.accent
        let root = RootViewController()
        window.rootViewController = root
        self.window = window
        window.makeKeyAndVisible()
        AppLogger.shared.info("scene connected", category: .app)
        AppEnvironment.shared.prefetchWhoami()
        NotificationCenterService.shared.attach(to: root)
        SessionSync.restore()
        #if DEBUG
        handleDebugLaunch(root)
        #endif
    }

    #if DEBUG
    /// The posts the `hidden` route lists: each `<id>=<reason>` argument (an
    /// underscore stands for a space in the reason) fetches that post and
    /// labels it, and without arguments the first four Home posts get
    /// invented reasons.
    private static func debugHiddenPosts(api: APIClient, routeArguments: [String]) async -> [HiddenPost] {
        if routeArguments.isEmpty {
            guard let page = try? await api.home(following: false, originals: false, cursor: nil) else { return [] }
            let reasons: [String?] = ["war", "outrage bait", nil, "american electoral politics"]
            return page.tweets.prefix(4).enumerated().map { HiddenPost(tweet: $1, reason: reasons[$0]) }
        }
        var posts: [HiddenPost] = []
        for argument in routeArguments {
            let pair = argument.split(separator: "=", maxSplits: 1).map(String.init)
            guard let id = pair.first, let tweet = try? await api.tweet(id: id) else { continue }
            posts.append(HiddenPost(tweet: tweet, reason: pair.count > 1 ? pair[1].replacingOccurrences(of: "_", with: " ") : nil))
        }
        return posts
    }

    /// Deterministic deep-navigation for screenshot QA, driven by the
    /// `UNRAGER_SCREEN` env var. Both `:` and `/` separate the route from its
    /// arguments (`thread:123` ≡ `thread/123`), matching how QA harnesses
    /// naturally write path-shaped routes; unmatched routes are logged so a
    /// silent miss can't masquerade as a green run.
    private func handleDebugLaunch(_ root: RootViewController) {
        guard let screen = ProcessInfo.processInfo.environment["UNRAGER_SCREEN"], !screen.isEmpty else { return }
        let parts = screen.split(whereSeparator: { $0 == ":" || $0 == "/" }).map(String.init)
        let api = AppEnvironment.shared.api
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            func homeNav() -> UINavigationController? { root.viewControllers?.first as? UINavigationController }
            switch parts.first {
            case "following":
                root.selectedIndex = 0
                let home = homeNav()?.viewControllers.first as? HomeViewController
                home?.debugSwitchToFollowing()
                if parts.count > 1, let points = Double(parts[1]) { home?.debugScroll(by: CGFloat(points)) }
            case "search": root.selectedIndex = 1
            case "toast":
                let json = """
                {"id":"demo","type":"reply","actors":[{"handle":"jack","name":"jack","rest_id":"1","verified":true}],
                 "target_tweet_snippet":"this is the post they replied to — nice work on the materialized feed","timestamp":"2026-06-27T12:00:00Z"}
                """
                if let n = try? UnragerJSON.decode(XNotification.self, from: Data(json.utf8)) {
                    root.showNotificationToast([n])
                }
            case "notifications":
                root.selectedIndex = 2
                let list = (root.viewControllers?[2] as? UINavigationController)?
                    .viewControllers.first as? NotificationsViewController
                if parts.count > 1 { list?.debugSelect(parts[1]) }
                if parts.count > 2, parts[2] == "end" { list?.debugScrollToEnd(times: 6, then: parts.count > 3 ? parts[3] : nil) }
                if parts.count > 2, let points = Double(parts[2]) { list?.debugScroll(by: CGFloat(points)) }
            case "notifsettings":
                root.selectedIndex = 3
                let notificationSettings = NotificationSettingsViewController()
                (root.viewControllers?[3] as? UINavigationController)?
                    .pushViewController(notificationSettings, animated: false)
                if parts.count > 1, let points = Double(parts[1]) {
                    notificationSettings.debugScroll(by: CGFloat(points))
                }
            case "settings":
                root.selectedIndex = 3
                if parts.count > 1, let points = Double(parts[1]),
                   let settings = (root.viewControllers?[3] as? UINavigationController)?.topViewController
                    as? SettingsViewController {
                    settings.debugScroll(by: CGFloat(points))
                }
            case "filter":
                root.selectedIndex = 3
                (root.viewControllers?[3] as? UINavigationController)?
                    .pushViewController(FilterSettingsViewController(), animated: false)
            case "edittabs":
                root.selectedIndex = 3
                (root.viewControllers?[3] as? UINavigationController)?
                    .pushViewController(EditTabsViewController(), animated: false)
            case "changelog":
                root.selectedIndex = 3
                let changelog = ChangelogViewController()
                (root.viewControllers?[3] as? UINavigationController)?
                    .pushViewController(changelog, animated: false)
                if parts.count > 1, parts[1] == "end" { changelog.debugScrollToEnd() }
            case "userlist" where parts.count > 2:
                let mode: UserListViewController.Mode = parts[2] == "following" ? .following : .followers
                homeNav()?.pushViewController(UserListViewController(userID: parts[1], mode: mode), animated: false)
            case "askctx" where parts.count > 1:
                let id = parts[1]
                Task {
                    guard let tweet = try? await api.tweet(id: id) else { return }
                    let sheet = AskConversationViewController(
                        context: .init(tweet: tweet), initialPrompt: "Explain this post.")
                    root.present(UINavigationController(rootViewController: sheet), animated: false)
                }
            case "myprofile":
                homeNav()?.pushViewController(MyProfileViewController(), animated: false)
            case "mentions":
                homeNav()?.pushViewController(MentionsViewController(), animated: false)
            case "profile" where parts.count > 1:
                let profile = ProfileViewController(handle: parts[1])
                homeNav()?.pushViewController(profile, animated: false)
                if parts.count > 2, parts[2] == "replies" {
                    profile.debugShowReplies()
                    if parts.count > 3, let points = Double(parts[3]) { profile.debugScroll(by: CGFloat(points)) }
                }
                if parts.count > 2, parts[2] == "media" {
                    profile.debugShowMedia()
                    if parts.count > 3, let points = Double(parts[3]) { profile.debugScroll(by: CGFloat(points)) }
                }
                if parts.count > 3, parts[2] == "scroll", let points = Double(parts[3]) {
                    profile.debugScroll(by: CGFloat(points))
                }
                if parts.count > 2, parts[2] == "block" { profile.debugRequestBlock() }
            case "thread" where parts.count > 1:
                homeNav()?.pushViewController(ThreadViewController(tweetID: parts[1]), animated: false)
            case "delete" where parts.count > 1:
                let id = parts[1]
                Task {
                    guard let tweet = try? await api.tweet(id: id) else { return }
                    let thread = ThreadViewController(tweet: tweet)
                    homeNav()?.pushViewController(thread, animated: false)
                    try? await Task.sleep(for: .seconds(1))
                    thread.confirmDelete(tweet)
                }
            case "quotes" where parts.count > 1:
                homeNav()?.pushViewController(QuotesViewController(tweetID: parts[1]), animated: false)
            case "likers" where parts.count > 1:
                let id = parts[1]
                Task {
                    let tweet = try? await api.tweet(id: id)
                    homeNav()?.pushViewController(LikersViewController(tweetID: id, tweet: tweet), animated: false)
                }
            case "me":
                Task {
                    if let me = try? await api.whoami() {
                        homeNav()?.pushViewController(ProfileViewController(handle: me.handle), animated: false)
                    }
                }
            case "viewer" where parts.count > 1:
                let id = parts[1]
                Task {
                    guard let tweet = try? await api.tweet(id: id) else { return }
                    let photoIndices = tweet.media.enumerated().compactMap { index, media -> Int? in
                        if case .photo = media.kind { return index } else { return nil }
                    }
                    guard !photoIndices.isEmpty else { return }
                    let sample = parts.count > 2 ? "A made-up description for screenshot QA: a wide valley at dusk, "
                        + "the ridge line in violet, a single lit window far below and thin cloud over the peaks." : nil
                    let viewer = MediaViewerViewController(
                        tweetID: tweet.restID, photoMediaIndices: photoIndices,
                        altTexts: photoIndices.map { tweet.media[$0].altText ?? sample }, startIndex: 0)
                    root.present(viewer, animated: false) {
                        if parts.count > 2, parts[2] == "caption" { viewer.debugExpandCaption() }
                    }
                }
            case "postcard" where parts.count > 1:
                let id = parts[1]
                let wantsThread = parts.count > 2 && parts[2] == "thread"
                Task {
                    guard let tweet = try? await api.tweet(id: id) else { return }
                    let postcard = PostcardViewController(tweet: tweet)
                    root.present(UINavigationController(rootViewController: postcard), animated: false)
                    if wantsThread { postcard.debugEnableThread() }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { postcard.debugSaveExport() }
                }
            case "hidden":
                Task {
                    let model = TimelineViewModel(source: .home(following: false, originals: false))
                    model.hiddenPosts.send(await Self.debugHiddenPosts(api: api, routeArguments: Array(parts.dropFirst())))
                    homeNav()?.pushViewController(HiddenPostsViewController(viewModel: model), animated: false)
                }
            case "bookmarks":
                homeNav()?.pushViewController(BookmarksViewController(), animated: false)
            case "compose":
                root.present(UINavigationController(rootViewController: ComposeViewController(mode: .new)), animated: false)
            case "quote" where parts.count > 1:
                let id = parts[1]
                Task {
                    guard let tweet = try? await api.tweet(id: id) else { return }
                    root.present(UINavigationController(
                        rootViewController: ComposeViewController(mode: .quote(of: tweet))), animated: false)
                }
            case "reply" where parts.count > 1:
                let id = parts[1]
                Task {
                    guard let tweet = try? await api.tweet(id: id) else { return }
                    root.present(UINavigationController(
                        rootViewController: ComposeViewController(mode: .reply(to: tweet))), animated: false)
                }
            case "brief" where parts.count > 1:
                let handle = parts[1]
                root.presentStream(title: "Brief · @\(handle)") { api.briefStream(handle: handle) }
            case "ask" where parts.count > 2:
                let id = parts[1]
                let preset = AskPreset(rawValue: parts[2]) ?? .explain
                root.presentStream(title: preset.title) { api.askStream(tweetID: id, preset: preset) }
            case "translate" where parts.count > 1:
                let id = parts[1]
                root.presentStream(title: "Translation") { api.translateStream(tweetID: id) }
            default:
                AppLogger.shared.warn("UNRAGER_SCREEN unmatched route: \(screen)", category: .app)
            }
        }
    }
    #endif
}
