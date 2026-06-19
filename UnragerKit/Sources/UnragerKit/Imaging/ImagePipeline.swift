import Foundation
import ImageIO
import CoreGraphics

/// A decoded, downsampled image. `CGImage` is immutable and thread-safe, so the
/// wrapper is safe to hand across actors; the platform layer wraps it in a
/// `UIImage`/`NSImage` on the main actor.
public final class DecodedImage: @unchecked Sendable {
    public let cgImage: CGImage
    public let pixelWidth: Int
    public let pixelHeight: Int

    init(_ cgImage: CGImage) {
        self.cgImage = cgImage
        self.pixelWidth = cgImage.width
        self.pixelHeight = cgImage.height
    }

    var byteCost: Int { cgImage.bytesPerRow * cgImage.height }
}

/// Bounds the number of concurrent decodes to avoid thread explosion
/// (the project's `Semaphore(4)` media-download discipline, in Swift).
actor DecodeGate {
    private let limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = max(1, limit) }

    func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
        active += 1
    }

    func release() {
        active -= 1
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.resume()
        }
    }
}

/// Off-main image loading for the feed: download → ImageIO downsample at the
/// exact draw size (`kCGImageSourceShouldCacheImmediately` forces the decode
/// onto the calling background thread) → cache the decoded bitmap in an
/// `NSCache` with a byte cost limit. In-flight requests dedupe by URL and are
/// cancellable for cell reuse / prefetch cancellation. Cross-platform.
public actor ImagePipeline {
    public static let shared = ImagePipeline()

    private let cache = NSCache<NSURL, DecodedImage>()
    private var inFlight: [URL: Task<DecodedImage?, Never>] = [:]
    private let gate = DecodeGate(limit: 4)
    private let session: URLSession

    public init(memoryLimitBytes: Int = 96 * 1024 * 1024) {
        cache.totalCostLimit = memoryLimitBytes
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.urlCache = URLCache(memoryCapacity: 8 * 1024 * 1024,
                                          diskCapacity: 256 * 1024 * 1024)
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration)
    }

    public func cached(_ url: URL) -> DecodedImage? {
        cache.object(forKey: url as NSURL)
    }

    /// Returns a decoded image sized so its largest side is `maxPixel` pixels.
    public func image(for url: URL, maxPixel: CGFloat) async -> DecodedImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        if let task = inFlight[url] { return await task.value }

        let task = Task<DecodedImage?, Never> { [session, gate] in
            await gate.acquire()
            defer { Task { await gate.release() } }
            if Task.isCancelled { return nil }
            guard let data = try? await session.data(from: url).0, !Task.isCancelled else {
                return nil
            }
            return await Task.detached(priority: .utility) {
                Self.downsample(data: data, maxPixel: maxPixel)
            }.value
        }
        inFlight[url] = task
        let result = await task.value
        inFlight[url] = nil
        if let result {
            cache.setObject(result, forKey: url as NSURL, cost: result.byteCost)
        }
        return result
    }

    public func prefetch(_ url: URL, maxPixel: CGFloat) {
        guard cache.object(forKey: url as NSURL) == nil, inFlight[url] == nil else { return }
        Task { _ = await image(for: url, maxPixel: maxPixel) }
    }

    public func cancel(_ url: URL) {
        inFlight[url]?.cancel()
        inFlight[url] = nil
    }

    nonisolated static func downsample(data: Data, maxPixel: CGFloat) -> DecodedImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return DecodedImage(cgImage)
    }
}
