import ImageIO
import PhotosUI
import UIKit
import UnragerKit
import UniformTypeIdentifiers

/// Turns a picked photo into what the composer uploads: the original bytes for
/// a GIF (a re-encode would flatten it to one frame), otherwise a JPEG capped at
/// `maxPixel` on its long side, decoded straight to that size rather than at full
/// resolution, plus a small thumbnail for the attachment bar.
enum ComposeMediaLoader {
    struct Loaded: Sendable {
        let media: ComposeMedia
        let thumbnail: UIImage
    }

    enum Failure: Error {
        case unreadable
    }

    static let maxPixel: CGFloat = 2560
    private static let thumbnailPixel: CGFloat = 192

    /// An item provider handed across a task boundary. The picker gives each
    /// result's provider to exactly one loader, so nothing else touches it.
    struct Handoff: @unchecked Sendable {
        let provider: NSItemProvider
    }

    static func load(_ handoff: Handoff) async throws -> Loaded {
        let isGIF = handoff.provider.hasItemConformingToTypeIdentifier(UTType.gif.identifier)
        let data = try await loadData(handoff, type: isGIF ? UTType.gif : UTType.image)
        return try await Task.detached(priority: .userInitiated) {
            try process(data, isGIF: isGIF)
        }.value
    }

    private static func loadData(_ handoff: Handoff, type: UTType) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            handoff.provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error ?? Failure.unreadable)
                }
            }
        }
    }

    private static func process(_ data: Data, isGIF: Bool) throws -> Loaded {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let small = downsample(source, maxPixel: thumbnailPixel) else { throw Failure.unreadable }
        let thumbnail = UIImage(cgImage: small)
        let name = UUID().uuidString
        if isGIF {
            return Loaded(media: ComposeMedia(data: data, filename: "\(name).gif", mimeType: "image/gif"),
                          thumbnail: thumbnail)
        }
        guard let full = downsample(source, maxPixel: maxPixel),
              let jpeg = UIImage(cgImage: full).jpegData(compressionQuality: 0.85) else { throw Failure.unreadable }
        return Loaded(media: ComposeMedia(data: jpeg, filename: "\(name).jpg", mimeType: "image/jpeg"),
                      thumbnail: thumbnail)
    }

    private static func downsample(_ source: CGImageSource, maxPixel: CGFloat) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary)
    }
}
