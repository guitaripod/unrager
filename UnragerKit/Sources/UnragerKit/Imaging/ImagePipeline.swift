import Foundation
import ImageIO
import CoreGraphics

/// `NSCache` behind a `Sendable` face. `NSCache` is thread-safe but, depending
/// on the SDK, not declared `Sendable`, which a `nonisolated` read of it from
/// the pipeline actor can't get past on older toolchains.
private final class MemoryImageCache: @unchecked Sendable {
    private let storage = NSCache<NSURL, DecodedImage>()

    var totalCostLimit: Int {
        get { storage.totalCostLimit }
        set { storage.totalCostLimit = newValue }
    }

    func object(forKey key: NSURL) -> DecodedImage? {
        storage.object(forKey: key)
    }

    func setObject(_ image: DecodedImage, forKey key: NSURL, cost: Int) {
        storage.setObject(image, forKey: key, cost: cost)
    }
}

/// A decoded, downsampled image. `CGImage` is immutable and thread-safe, so the
/// wrapper is safe to hand across actors; the platform layer wraps it in a
/// `UIImage`/`NSImage` on the main actor.
public final class DecodedImage: @unchecked Sendable {
    public let cgImage: CGImage
    public let pixelWidth: Int
    public let pixelHeight: Int
    let requestedMaxPixel: CGFloat

    init(_ cgImage: CGImage, requestedMaxPixel: CGFloat = .infinity) {
        self.cgImage = cgImage
        self.pixelWidth = cgImage.width
        self.pixelHeight = cgImage.height
        self.requestedMaxPixel = requestedMaxPixel
    }

    var byteCost: Int { cgImage.bytesPerRow * cgImage.height }

    /// Whether this decode can stand in for one whose largest side is
    /// `maxPixel`: it was decoded at least that large, or the source image is
    /// smaller than what was asked for, so no larger decode exists.
    func satisfies(_ maxPixel: CGFloat) -> Bool {
        requestedMaxPixel >= maxPixel
            || CGFloat(max(pixelWidth, pixelHeight)) < requestedMaxPixel - 1
    }
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
    }

    /// Hands the slot straight to the next waiter, so it is never free for a
    /// newcomer to take in the gap before that waiter runs; the count only
    /// drops when nobody is waiting.
    func release() {
        if waiters.isEmpty {
            active -= 1
        } else {
            waiters.removeFirst().resume()
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

    /// An in-flight decode is shared only between requests for the same URL at
    /// the same size, so a small thumbnail load is never handed to a caller that
    /// needs the full-size image.
    private struct LoadKey: Hashable {
        let url: URL
        let maxPixel: Int

        init(url: URL, maxPixel: CGFloat) {
            self.url = url
            self.maxPixel = Int(max(1, maxPixel).rounded(.up))
        }
    }

    /// The memory cache is thread-safe, so it can be read from any thread
    /// without hopping onto this actor (see `cachedImageImmediately`).
    private let cache = MemoryImageCache()
    private var inFlight: [LoadKey: InFlightLoad] = [:]
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

    /// The decoded image for `url` if memory already holds one big enough for
    /// `maxPixel`, answered on the calling thread. Lets a view that is being
    /// reconfigured show an image it has already seen at once, instead of
    /// blanking to a placeholder for an actor hop.
    public nonisolated func cachedImageImmediately(for url: URL, maxPixel: CGFloat) -> DecodedImage? {
        guard let hit = cache.object(forKey: url as NSURL), hit.satisfies(maxPixel) else { return nil }
        return hit
    }

    /// Returns a decoded image sized so its largest side is `maxPixel` pixels.
    /// Joins any in-flight load for the same URL as one more interested
    /// consumer. Cancelling the calling task withdraws exactly this call's
    /// interest; the shared download is aborted only once every consumer has
    /// cancelled.
    public func image(for url: URL, maxPixel: CGFloat) async -> DecodedImage? {
        if let hit = cache.object(forKey: url as NSURL), hit.satisfies(maxPixel) { return hit }
        let key = LoadKey(url: url, maxPixel: maxPixel)
        let task = registerInterest(key: key)
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { await self.withdrawInterest(key: key, task: task) }
        }
        settle(key: key, task: task, result: result)
        return result
    }

    /// Warms the cache for `url` under its own interest registration, tracked
    /// so `cancelPrefetch` withdraws only the prefetch's unit — a visible
    /// consumer's refcount on the same URL is untouchable from here. At most
    /// one prefetch per URL is held at a time.
    public func prefetch(_ url: URL, maxPixel: CGFloat) {
        if let hit = cache.object(forKey: url as NSURL), hit.satisfies(maxPixel) { return }
        guard prefetches[url] == nil else { return }
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
    private func registerInterest(key: LoadKey) -> Task<DecodedImage?, Never> {
        if let existing = inFlight[key] {
            inFlight[key] = InFlightLoad(task: existing.task, interest: existing.interest + 1)
            return existing.task
        }
        let url = key.url
        let maxPixel = CGFloat(key.maxPixel)
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
        inFlight[key] = InFlightLoad(task: task, interest: 1)
        return task
    }

    /// Gives back the one unit of interest a cancelled `image(for:)` call
    /// registered. The task-identity check makes a withdrawal that lands after
    /// the load finished a no-op instead of a theft from a newer load of the
    /// same URL.
    private func withdrawInterest(key: LoadKey, task: Task<DecodedImage?, Never>) {
        guard var entry = inFlight[key], entry.task == task else { return }
        entry.interest -= 1
        if entry.interest <= 0 {
            entry.task.cancel()
            inFlight[key] = nil
        } else {
            inFlight[key] = entry
        }
    }

    /// Clears the in-flight entry once the shared task has produced its result
    /// and publishes a successful decode to the cache. Every awaiting consumer
    /// calls this; only the first still finds the entry.
    private func settle(key: LoadKey, task: Task<DecodedImage?, Never>, result: DecodedImage?) {
        if inFlight[key]?.task == task { inFlight[key] = nil }
        guard let result else { return }
        let url = key.url as NSURL
        if let existing = cache.object(forKey: url), existing.satisfies(CGFloat(key.maxPixel)) { return }
        cache.setObject(result, forKey: url, cost: result.byteCost)
    }

    /// Drops the prefetch bookkeeping once its load settled, unless a newer
    /// prefetch for the same URL has already replaced it.
    private func clearPrefetch(url: URL, task: Task<Void, Never>) {
        if prefetches[url] == task { prefetches[url] = nil }
    }

    /// The current number of interested consumers for an in-flight load
    /// (0 when nothing is in flight). Test hook for the refcount semantics.
    func interestCount(for url: URL) -> Int {
        inFlight.filter { $0.key.url == url }.values.reduce(0) { $0 + $1.interest }
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
        return DecodedImage(cgImage, requestedMaxPixel: maxPixel)
    }
}
