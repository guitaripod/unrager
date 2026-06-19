import UIKit
import UnragerKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.overrideUserInterfaceStyle = UIUserInterfaceStyle(rawValue: AppSettings.appearance.rawValue) ?? .unspecified
        window.tintColor = DesignSystem.Color.accent
        let root = RootViewController()
        window.rootViewController = root
        self.window = window
        window.makeKeyAndVisible()
        AppLogger.shared.info("scene connected", category: .app)
        SessionSync.restore { [weak self] mode in self?.applyAppearance(mode) }
        #if DEBUG
        handleDebugLaunch(root)
        #endif
    }

    #if DEBUG
    /// Deterministic deep-navigation for screenshot QA, driven by the
    /// `UNRAGER_SCREEN` env var (e.g. `thread:123`, `profile:jack`, `settings`).
    private func handleDebugLaunch(_ root: RootViewController) {
        guard let screen = ProcessInfo.processInfo.environment["UNRAGER_SCREEN"], !screen.isEmpty else { return }
        let parts = screen.split(separator: ":").map(String.init)
        let api = AppEnvironment.shared.api
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            func homeNav() -> UINavigationController? { root.viewControllers?.first as? UINavigationController }
            switch parts.first {
            case "following":
                root.selectedIndex = 0
                (homeNav()?.viewControllers.first as? HomeViewController)?.debugSwitchToFollowing()
            case "search": root.selectedIndex = 1
            case "notifications": root.selectedIndex = 2
            case "settings": root.selectedIndex = 3
            case "filter":
                root.selectedIndex = 3
                (root.viewControllers?[3] as? UINavigationController)?
                    .pushViewController(FilterSettingsViewController(), animated: false)
            case "edittabs":
                root.selectedIndex = 3
                (root.viewControllers?[3] as? UINavigationController)?
                    .pushViewController(EditTabsViewController(), animated: false)
            case "myprofile":
                homeNav()?.pushViewController(MyProfileViewController(), animated: false)
            case "mentions":
                homeNav()?.pushViewController(MentionsViewController(), animated: false)
            case "profile" where parts.count > 1:
                homeNav()?.pushViewController(ProfileViewController(handle: parts[1]), animated: false)
            case "thread" where parts.count > 1:
                homeNav()?.pushViewController(ThreadViewController(tweetID: parts[1]), animated: false)
            case "likers" where parts.count > 1:
                homeNav()?.pushViewController(LikersViewController(tweetID: parts[1]), animated: false)
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
                    root.present(MediaViewerViewController(tweetID: tweet.restID, photoMediaIndices: photoIndices, startIndex: 0), animated: false)
                }
            case "compose":
                root.present(UINavigationController(rootViewController: ComposeViewController(mode: .new)), animated: false)
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
            default: break
            }
        }
    }
    #endif

    func applyAppearance(_ mode: AppearanceMode) {
        window?.overrideUserInterfaceStyle = UIUserInterfaceStyle(rawValue: mode.rawValue) ?? .unspecified
    }
}
