import Foundation
import UnragerKit

/// Process-wide handles to the standalone engagement and publish clients.
/// Like `AppEnvironment.api`, both read the server URL from `AppSettings` on
/// every request, so a Settings change takes effect immediately.
enum EngageService {
    static let engage = EngageAPI(baseURL: { AppSettings.serverURL })
    static let publish = MediaUploadAPI(baseURL: { AppSettings.serverURL })
}
