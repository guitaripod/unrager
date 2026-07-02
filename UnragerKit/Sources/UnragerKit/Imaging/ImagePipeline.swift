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
/// `NSCache` with a byte cost limit. In-flight requests dedupe by URL with a
/// refcount of interested consumers. Interest is withdrawn through structured
/// cancellation only: each `image(for:)` call registers exactly one unit of
/// interest and gives back exactly that unit when its awaiting task is
/// cancelled — so a cancel can never steal another consumer's interest, and a
/// caller that never registered can't decrement anything. The shared download
/// is aborted only once the last interested consumer has cancelled, so
/// recycling one cell never blanks an identical load another visible view is
/// awaiting. Cross-platform.
public actor ImagePipeline {
    public static let shared = ImagePipeline()

    private struct InFlightLoad {
        let task: Task<DecodedImage?, Never>
        var interest: Int
    }

    private let cache = NSCache<NSURL, DecodedImage>()
    private var inFlight: [URL: InFlightLoad] = [:]
    private var prefetches: [URL: Task<Void, Never>] = [:]
    private let gate = DecodeGate(limit: 4)
    private let session: URLSession

    public init(memoryLimitBytes: Int = 96 * 1024 * 1024) {
        cache.totalCostLimit = memoryLimitBytes
        session = URLSession(configuration: Self.defaultConfiguration())
    }

    init(memoryLimitBytes: Int, sessionConfiguration: URLSessionConfiguration) {
        cache.totalCostLimit = memoryLimitBytes
        session = URLSession(configuration: sessionConfiguration)
    }

    private static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.urlCache = URLCache(memoryCapacity: 8 * 1024 * 1024,
                                          diskCapacity: 256 * 1024 * 1024)
        configuration.timeoutIntervalForRequest = 30
        return configuration
    }

    public func cached(_ url: URL) -> DecodedImage? {
        cache.object(forKey: url as NSURL)
    }

    /// Returns a decoded image sized so its largest side is `maxPixel` pixels.
    /// Joins any in-flight load for the same URL as one more interested
    /// consumer. Cancelling the calling task withdraws exactly this call's
    /// interest; the shared download is aborted only once every consumer has
    /// cancelled.
    public func image(for url: URL, maxPixel: CGFloat) async -> DecodedImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        let task = registerInterest(url: url, maxPixel: maxPixel)
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { await self.withdrawInterest(url: url, task: task) }
        }
        settle(url: url, task: task, result: result)
        return result
    }

    /// Warms the cache for `url` under its own interest registration, tracked
    /// so `cancelPrefetch` withdraws only the prefetch's unit — a visible
    /// consumer's refcount on the same URL is untouchable from here. At most
    /// one prefetch per URL is held at a time.
    public func prefetch(_ url: URL, maxPixel: CGFloat) {
        guard cache.object(forKey: url as NSURL) == nil, prefetches[url] == nil else { return }
        let task = Task { _ = await self.image(for: url, maxPixel: maxPixel) }
        prefetches[url] = task
        Task {
            _ = await task.value
            clearPrefetch(url: url, task: task)
        }
    }

    /// Cancels the tracked prefetch for `url`, if one is still in flight. The
    /// prefetch task's own cancellation handler gives back its interest, so
    /// this can never blank a load a visible view is awaiting.
    public func cancelPrefetch(_ url: URL) {
        guard let task = prefetches.removeValue(forKey: url) else { return }
        task.cancel()
    }

    /// Joins the in-flight load for `url` as one more interested consumer, or
    /// starts the shared download with an interest of one.
    private func registerInterest(url: URL, maxPixel: CGFloat) -> Task<DecodedImage?, Never> {
        if let existing = inFlight[url] {
            inFlight[url] = InFlightLoad(task: existing.task, interest: existing.interest + 1)
            return existing.task
        }
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
        inFlight[url] = InFlightLoad(task: task, interest: 1)
        return task
    }

    /// Gives back the one unit of interest a cancelled `image(for:)` call
    /// registered. The task-identity check makes a withdrawal that lands after
    /// the load finished a no-op instead of a theft from a newer load of the
    /// same URL.
    private func withdrawInterest(url: URL, task: Task<DecodedImage?, Never>) {
        guard var entry = inFlight[url], entry.task == task else { return }
        entry.interest -= 1
        if entry.interest <= 0 {
            entry.task.cancel()
            inFlight[url] = nil
        } else {
            inFlight[url] = entry
        }
    }

    /// Clears the in-flight entry once the shared task has produced its result
    /// and publishes a successful decode to the cache. Every awaiting consumer
    /// calls this; only the first still finds the entry.
    private func settle(url: URL, task: Task<DecodedImage?, Never>, result: DecodedImage?) {
        if inFlight[url]?.task == task { inFlight[url] = nil }
        if let result {
            cache.setObject(result, forKey: url as NSURL, cost: result.byteCost)
        }
    }

    /// Drops the prefetch bookkeeping once its load settled, unless a newer
    /// prefetch for the same URL has already replaced it.
    private func clearPrefetch(url: URL, task: Task<Void, Never>) {
        if prefetches[url] == task { prefetches[url] = nil }
    }

    /// The current number of interested consumers for an in-flight load
    /// (0 when nothing is in flight). Test hook for the refcount semantics.
    func interestCount(for url: URL) -> Int {
        inFlight[url]?.interest ?? 0
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
