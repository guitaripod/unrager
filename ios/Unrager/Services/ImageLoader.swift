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
