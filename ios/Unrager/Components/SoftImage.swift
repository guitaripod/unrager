import CoreImage
import UIKit

/// A heavily blurred, much smaller copy of a picture: cheap to hold, and
/// stretched back to full size it reads as the same picture seen through
/// frosted glass. It fills the space around media that doesn't fit its frame,
/// and softens the profile banner as it scrolls away.
enum SoftImage {
    private static let width: CGFloat = 96
    private nonisolated(unsafe) static let cache = NSCache<NSString, UIImage>()
    /// One Core Image context for every blur: building one is costly, and it
    /// is safe to share across threads.
    private nonisolated(unsafe) static let context = CIContext(options: [.cacheIntermediates: false])
    /// Blur radius in pixels of the `width`-pixel copy.
    private static let sigma: Double = 2.5

    /// The blurred copy, remembered under `key` so a recycled cell reuses it.
    static func blurred(_ image: UIImage, key: String) async -> UIImage? {
        if let cached = cache.object(forKey: key as NSString) { return cached }
        let soft = await Task.detached { render(image).blurred }.value
        if let soft { cache.setObject(soft, forKey: key as NSString) }
        return soft
    }

    /// The blurred copy and how bright the top third of the picture is (0 to 1).
    static func analyzed(_ image: UIImage) async -> (blurred: UIImage?, topBrightness: CGFloat) {
        await Task.detached { render(image) }.value
    }

    private nonisolated static func render(_ image: UIImage) -> (blurred: UIImage?, topBrightness: CGFloat) {
        guard let source = image.cgImage else { return (nil, 1) }
        let height = max(1, (width * CGFloat(source.height) / CGFloat(source.width)).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let small = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        guard let input = small.cgImage.map(CIImage.init(cgImage:)) else { return (nil, 1) }
        let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: input.extent)
        let output = context.createCGImage(blurred, from: blurred.extent).map { UIImage(cgImage: $0) }
        return (output, topBrightness(of: input, context: context))
    }

    private nonisolated static func topBrightness(of image: CIImage, context: CIContext) -> CGFloat {
        let extent = image.extent
        let top = CGRect(x: extent.minX, y: extent.maxY - extent.height / 3, width: extent.width, height: extent.height / 3)
        let average = image.cropped(to: top).applyingFilter(
            "CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: top)])
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(average, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return (0.299 * CGFloat(pixel[0]) + 0.587 * CGFloat(pixel[1]) + 0.114 * CGFloat(pixel[2])) / 255
    }
}
