import UIKit
import UnragerKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        #if DEBUG
        if let server = ProcessInfo.processInfo.environment["UNRAGER_SERVER"], !server.isEmpty {
            AppSettings.serverURLString = server
        }
        #endif
        Task { _ = await ImagePipeline.shared.diskUsage() }
        MediaAudioSession.configureMixable()
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            ImagePipeline.shared.purgeMemory()
        }
        NotificationCenterService.shared.registerLaunchHandlers()
        AppLogger.shared.info("app launched · server=\(AppSettings.serverURLString)", category: .app)
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}
