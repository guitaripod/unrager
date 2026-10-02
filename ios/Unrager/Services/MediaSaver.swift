import Photos
import UIKit

/// Downloads a media attachment from the server proxy straight to a temporary
/// file (never holding a whole video in memory) and writes it to the user's
/// photo library, requesting add-only authorization first. Throws a descriptive
/// error if permission is denied or the write fails.
enum MediaSaver {
    enum Failure: LocalizedError {
        case permissionDenied
        /// Photos access is blocked by Screen Time or a device profile, which
        /// the Settings switch can't change.
        case restricted
        case download

        var errorDescription: String? {
            switch self {
            case .permissionDenied: return "Photos access is required to save. Enable it in Settings."
            case .restricted: return "Saving to Photos is restricted on this device by Screen Time or a profile."
            case .download: return "Couldn't download the media."
            }
        }
    }

    /// How long a download may sit without receiving data before it fails.
    private static let idleTimeout: TimeInterval = 60

    /// Attachments being saved right now, so a second tap on Save while the
    /// first is still downloading doesn't put the same file in Photos twice.
    @MainActor static var inFlight = Set<URL>()

    static func save(from url: URL, isVideo: Bool) async throws {
        try await ensureAuthorized()
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: idleTimeout)
        let (downloaded, response) = try await URLSession.shared.download(for: request)
        defer { try? FileManager.default.removeItem(at: downloaded) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Failure.download
        }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension(response, isVideo: isVideo))
        try FileManager.default.moveItem(at: downloaded, to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else {
            throw Failure.download
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: isVideo ? .video : .photo, fileURL: file, options: nil)
        }
    }

    /// Writes a rendered image (a postcard) to the photo library.
    ///
    /// The change block must not inherit the caller's main-actor isolation:
    /// Photos invokes it on its own background queue, and an isolated closure
    /// trips the runtime's dispatch queue assertion (SIGTRAP). It stays
    /// nonisolated with an explicitly `@Sendable` block.
    static func save(image: UIImage) async throws {
        try await ensureAuthorized()
        let changes: @Sendable () -> Void = {
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        }
        try await PHPhotoLibrary.shared().performChanges(changes)
    }

    /// The alert for a failed save. A denied Photos permission gets a way to
    /// the Settings page that fixes it; anything else, a restriction included,
    /// is the plain error.
    @MainActor
    static func alert(for error: Error) -> UIAlertController {
        guard case Failure.permissionDenied = error else { return AlertFactory.error(error, title: "Couldn't save") }
        let alert = UIAlertController(title: "Photos access needed", message: error.localizedDescription,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Open Settings", style: .default) { _ in
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        })
        return alert
    }

    private static func ensureAuthorized() async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .authorized, .limited:
            return
        case .notDetermined:
            let granted = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard granted == .authorized || granted == .limited else { throw Failure.permissionDenied }
        case .restricted:
            throw Failure.restricted
        default:
            throw Failure.permissionDenied
        }
    }

    private static func fileExtension(_ response: URLResponse, isVideo: Bool) -> String {
        switch response.mimeType {
        case "video/mp4": return "mp4"
        case "video/quicktime": return "mov"
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/heic": return "heic"
        case "image/jpeg": return "jpg"
        default: return isVideo ? "mp4" : "jpg"
        }
    }
}
