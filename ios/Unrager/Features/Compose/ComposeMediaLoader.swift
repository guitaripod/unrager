import ImageIO
import PhotosUI
import UIKit
import UnragerKit
import UniformTypeIdentifiers

/// Turns a picked photo into what the composer uploads: the original bytes for
/// a GIF (a re-encode would flatten it to one frame), a PNG for a picture with
/// see-through parts (a JPEG has no transparency and would fill them black),
/// otherwise a JPEG, both capped at `maxPixel` on the long side and decoded
/// straight to that size rather than at full resolution, plus a small thumbnail
/// for the attachment bar.
enum ComposeMediaLoader {
    struct Loaded: Sendable {
        let media: ComposeMedia
        let thumbnail: UIImage
    }

    enum Failure: Error {
        case unreadable
    }

    static let maxPixel: CGFloat = 2560
    /// X's limit for one image; a transparent picture whose PNG runs past it
    /// goes as a JPEG on white instead.
    private static let maxImageBytes = 5 * 1024 * 1024
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
        guard let full = downsample(source, maxPixel: maxPixel) else { throw Failure.unreadable }
        let transparent = hasAlpha(source) && showsThrough(small)
        if transparent, let png = UIImage(cgImage: full).pngData(), png.count <= maxImageBytes {
            return Loaded(media: ComposeMedia(data: png, filename: "\(name).png", mimeType: "image/png"),
                          thumbnail: thumbnail)
        }
        let opaque = transparent ? onWhite(full) : UIImage(cgImage: full)
        guard let jpeg = opaque.jpegData(compressionQuality: 0.85) else { throw Failure.unreadable }
        return Loaded(media: ComposeMedia(data: jpeg, filename: "\(name).jpg", mimeType: "image/jpeg"),
                      thumbnail: thumbnail)
    }

    private static func hasAlpha(_ source: CGImageSource) -> Bool {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        return properties?[kCGImagePropertyHasAlpha] as? Bool == true
    }

    /// Whether any of `image` is see-through. Asked of the small thumbnail,
    /// whose pixels average the full picture's, so a screenshot saved with an
    /// alpha channel it never uses still goes as a compact JPEG.
    private static func showsThrough(_ image: CGImage) -> Bool {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return false }
        return stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] < 255 }
    }

    /// The picture over white, as an image a JPEG can hold as it looks.
    private static func onWhite(_ image: CGImage) -> UIImage {
        let size = CGSize(width: image.width, height: image.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: size))
        }
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
