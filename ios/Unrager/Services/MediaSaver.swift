import Photos
import UIKit

/// Downloads a media attachment from the server proxy straight to a temporary
/// file (never holding a whole video in memory) and writes it to the user's
/// photo library, requesting add-only authorization first. Throws a descriptive
/// error if permission is denied or the write fails.
enum MediaSaver {
    enum Failure: LocalizedError {
        case permissionDenied
        case download

        var errorDescription: String? {
            switch self {
            case .permissionDenied: return "Photos access is required to save. Enable it in Settings."
            case .download: return "Couldn't download the media."
            }
        }
    }

    static func save(from url: URL, isVideo: Bool) async throws {
        try await ensureAuthorized()
        let (downloaded, response) = try await URLSession.shared.download(from: url)
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

    /// The alert for a failed save. A denied Photos permission gets a way to
    /// the Settings page that fixes it; anything else is the plain error.
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
