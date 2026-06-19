import Photos
import UIKit

/// Downloads a media attachment from the server proxy and writes it to the
/// user's photo library, requesting add-only authorization first. Throws a
/// descriptive error if permission is denied or the write fails.
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
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else {
            throw Failure.download
        }
        if isVideo {
            try await saveVideo(data, suggestedExtension: Self.fileExtension(response) ?? "mp4")
        } else {
            try await savePhoto(data)
        }
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

    private static func savePhoto(_ data: Data) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
        }
    }

    private static func saveVideo(_ data: Data, suggestedExtension: String) async throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(suggestedExtension)
        try data.write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: temp, options: nil)
        }
    }

    private static func fileExtension(_ response: URLResponse) -> String? {
        switch response.mimeType {
        case "video/mp4": return "mp4"
        case "video/quicktime": return "mov"
        default: return nil
        }
    }
}
