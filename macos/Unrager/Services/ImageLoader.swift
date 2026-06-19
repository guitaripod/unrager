import AppKit
import UnragerKit

/// Thin AppKit wrapper over `ImagePipeline`: turns a downsampled `DecodedImage`
/// into an `NSImage` for display, mirroring the iOS `ImageLoader`.
enum ImageLoader {
    static func image(for url: URL, pointSize: CGSize, scale: CGFloat) async -> NSImage? {
        let maxPixel = max(pointSize.width, pointSize.height) * scale
        guard let decoded = await ImagePipeline.shared.image(for: url, maxPixel: maxPixel) else { return nil }
        return nsImage(from: decoded)
    }

    static func cachedImage(for url: URL) async -> NSImage? {
        guard let decoded = await ImagePipeline.shared.cached(url) else { return nil }
        return nsImage(from: decoded)
    }

    static func prefetch(_ url: URL, pointSize: CGSize, scale: CGFloat) {
        let maxPixel = max(pointSize.width, pointSize.height) * scale
        Task { _ = await ImagePipeline.shared.prefetch(url, maxPixel: maxPixel) }
    }

    static func cancel(_ url: URL) {
        Task { await ImagePipeline.shared.cancel(url) }
    }

    private static func nsImage(from decoded: DecodedImage) -> NSImage {
        let size = NSSize(width: decoded.pixelWidth, height: decoded.pixelHeight)
        return NSImage(cgImage: decoded.cgImage, size: size)
    }
}
