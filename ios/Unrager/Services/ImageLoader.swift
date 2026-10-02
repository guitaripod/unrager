import UIKit
import UnragerKit

/// `UIImage` veneer over the kit's cross-platform `ImagePipeline`. The pipeline
/// downsamples + decodes off the main thread; this just wraps the resulting
/// `CGImage` so cells stay jank-free.
enum ImageLoader {
    static func image(for url: URL, pointSize: CGSize, scale: CGFloat) async -> UIImage? {
        let maxPixel = max(pointSize.width, pointSize.height) * scale
        guard let decoded = await ImagePipeline.shared.image(for: url, maxPixel: maxPixel) else {
            return nil
        }
        return UIImage(cgImage: decoded.cgImage, scale: scale, orientation: .up)
    }

    /// The image if memory already holds one big enough for this size, returned
    /// at once on the calling thread; nil means it still has to be loaded.
    static func cachedImageImmediately(for url: URL, pointSize: CGSize, scale: CGFloat) -> UIImage? {
        let maxPixel = max(pointSize.width, pointSize.height) * scale
        guard let decoded = ImagePipeline.shared.cachedImageImmediately(for: url, maxPixel: maxPixel) else { return nil }
        return UIImage(cgImage: decoded.cgImage, scale: scale, orientation: .up)
    }

    /// An image decoded so its long side is at most `maxPixel` pixels, for
    /// views sized in pixels rather than points (the full-screen photo viewer).
    static func image(for url: URL, maxPixel: CGFloat) async -> UIImage? {
        guard let decoded = await ImagePipeline.shared.image(for: url, maxPixel: maxPixel) else { return nil }
        return UIImage(cgImage: decoded.cgImage, scale: 1, orientation: .up)
    }

    static func prefetch(_ url: URL, maxPixel: CGFloat) {
        Task { await ImagePipeline.shared.prefetch(url, maxPixel: maxPixel) }
    }

    static func cachedImage(for url: URL, scale: CGFloat) async -> UIImage? {
        guard let decoded = await ImagePipeline.shared.cached(url) else { return nil }
        return UIImage(cgImage: decoded.cgImage, scale: scale, orientation: .up)
    }

    static func prefetch(_ url: URL, pointSize: CGSize, scale: CGFloat) {
        let maxPixel = max(pointSize.width, pointSize.height) * scale
        Task { await ImagePipeline.shared.prefetch(url, maxPixel: maxPixel) }
    }

    static func cancelPrefetch(_ url: URL) {
        Task { await ImagePipeline.shared.cancelPrefetch(url) }
    }
}
