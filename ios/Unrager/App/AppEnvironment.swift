import UIKit
import UnragerKit

/// Process-wide singletons. The `APIClient` reads the server URL from
/// `AppSettings` on every request, so changing the address in Settings takes
/// effect immediately with no rebuild of the client.
@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let api: APIClient
    let log = AppLogger.shared

    private init() {
        api = APIClient(baseURL: { AppSettings.serverURL })
    }
}
