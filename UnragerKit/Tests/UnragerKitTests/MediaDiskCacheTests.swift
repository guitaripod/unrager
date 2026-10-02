import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import UnragerKit

private func makeImage(width: Int, height: Int, alpha: Bool = false) -> CGImage {
    let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)!
    context.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.2, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
    return context.makeImage()!
}

private func encodedJPEG(width: Int, height: Int) -> Data {
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, makeImage(width: width, height: height), nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

private func makeCache(maxBytes: Int = 50_000_000, maxAge: TimeInterval = 3_600, in directory: URL? = nil)
    -> (cache: MediaDiskCache, directory: URL) {
    let directory = directory ?? FileManager.default.temporaryDirectory
        .appendingPathComponent("media-cache-\(UUID().uuidString)", isDirectory: true)
    return (MediaDiskCache(directory: directory, maxBytes: maxBytes, maxAge: maxAge), directory)
}

private final class CountingURLProtocol: URLProtocol {
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) private static var served = 0
    private static let lock = NSLock()

    static var count: Int { lock.lock(); defer { lock.unlock() }; return served }
    static func reset() { lock.lock(); served = 0; lock.unlock() }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.served += 1
        Self.lock.unlock()
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("MediaDiskCache", .serialized)
struct MediaDiskCacheTests {
    @Test("Sizes round up to the next step, within the limits")
    func buckets() {
        #expect(MediaDiskCache.bucket(for: 1) == 64)
        #expect(MediaDiskCache.bucket(for: 64) == 64)
        #expect(MediaDiskCache.bucket(for: 65) == 128)
        #expect(MediaDiskCache.bucket(for: 132) == 192)
        #expect(MediaDiskCache.bucket(for: 100_000) == 4096)
    }

    @Test("An entry answers requests up to its size and no larger, until it holds the whole picture")
    func satisfiesBySize() async {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = URL(string: "https://cdn.test/a.jpg")!
        cache.store(makeImage(width: 128, height: 96), for: url, bucket: 128, complete: false)
        #expect(await cache.data(for: url, atLeast: 100) != nil)
        #expect(await cache.data(for: url, atLeast: 128) != nil)
        #expect(await cache.data(for: url, atLeast: 129) == nil)

        cache.store(makeImage(width: 80, height: 60), for: url, bucket: 256, complete: true)
        #expect(await cache.data(for: url, atLeast: 4_000) != nil)
    }

    @Test("A smaller store never replaces a bigger entry, and a bigger one replaces a smaller")
    func replacement() async {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = URL(string: "https://cdn.test/b.jpg")!
        cache.store(makeImage(width: 256, height: 256), for: url, bucket: 256, complete: false)
        cache.store(makeImage(width: 64, height: 64), for: url, bucket: 64, complete: false)
        #expect(await cache.data(for: url, atLeast: 256) != nil)
        #expect(await cache.wants(url, bucket: 128) == false)
        #expect(await cache.wants(url, bucket: 512) == true)

        cache.store(makeImage(width: 512, height: 512), for: url, bucket: 512, complete: false)
        #expect(await cache.data(for: url, atLeast: 512) != nil)
        let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files?.count == 1)
    }

    @Test("Stored pictures survive a restart and are indexed from their file names")
    func persistence() async {
        let (first, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = URL(string: "https://cdn.test/c.jpg")!
        first.store(makeImage(width: 128, height: 128), for: url, bucket: 128, complete: false)
        await first.flush()

        let (second, _) = makeCache(in: directory)
        #expect(await second.data(for: url, atLeast: 128) != nil)
        #expect(await second.diskUsage() > 0)
    }

    @Test("A picture with transparency is kept as PNG and one without as JPEG")
    func formats() async {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        cache.store(makeImage(width: 64, height: 64, alpha: true), for: URL(string: "https://cdn.test/d.png")!,
                    bucket: 64, complete: true)
        cache.store(makeImage(width: 64, height: 64), for: URL(string: "https://cdn.test/e.jpg")!,
                    bucket: 64, complete: true)
        await cache.flush()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        #expect(names.contains { $0.hasSuffix(".png") })
        #expect(names.contains { $0.hasSuffix(".jpg") })
    }

    @Test("Over the cap, the least recently used go first")
    func evictsLeastRecentlyUsed() async {
        let (probe, probeDirectory) = makeCache()
        defer { try? FileManager.default.removeItem(at: probeDirectory) }
        probe.store(makeImage(width: 256, height: 256), for: URL(string: "https://cdn.test/probe.jpg")!,
                    bucket: 256, complete: false)
        await probe.flush()
        let one = await probe.diskUsage()
        let (cache, directory) = makeCache(maxBytes: one * 9 / 2)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = (0..<6).map { URL(string: "https://cdn.test/\($0).jpg")! }
        for url in urls.prefix(3) {
            cache.store(makeImage(width: 256, height: 256), for: url, bucket: 256, complete: false)
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(await cache.data(for: urls[0], atLeast: 256) != nil)
        for url in urls.suffix(3) {
            cache.store(makeImage(width: 256, height: 256), for: url, bucket: 256, complete: false)
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        await cache.flush()
        #expect(await cache.diskUsage() <= one * 9 / 2)
        #expect(await cache.data(for: urls[5], atLeast: 256) != nil)
        #expect(await cache.data(for: urls[1], atLeast: 256) == nil)
    }

    @Test("Clearing forgets everything")
    func clears() async {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = URL(string: "https://cdn.test/f.jpg")!
        cache.store(makeImage(width: 64, height: 64), for: url, bucket: 64, complete: true)
        cache.clear()
        #expect(await cache.data(for: url, atLeast: 64) == nil)
        #expect(await cache.diskUsage() == 0)
    }

    @Test("A fresh download is kept on disk, and a later run reads it back without the network")
    func pipelineUsesDisk() async throws {
        CountingURLProtocol.reset()
        CountingURLProtocol.body = encodedJPEG(width: 800, height: 600)
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CountingURLProtocol.self]
        let url = URL(string: "https://cdn.test/photo.jpg")!

        let first = ImagePipeline(memoryLimitBytes: 8 * 1024 * 1024, sessionConfiguration: configuration, disk: cache)
        let loaded = await first.image(for: url, maxPixel: 200)
        #expect(loaded != nil)
        #expect(CountingURLProtocol.count == 1)
        for _ in 0..<400 where await cache.diskUsage() == 0 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(await cache.diskUsage() > 0)

        let second = ImagePipeline(memoryLimitBytes: 8 * 1024 * 1024, sessionConfiguration: configuration, disk: cache)
        let again = await second.image(for: url, maxPixel: 180)
        #expect(again != nil)
        #expect(max(again?.pixelWidth ?? 0, again?.pixelHeight ?? 0) <= 180)
        #expect(CountingURLProtocol.count == 1)

        let bigger = await second.image(for: url, maxPixel: 700)
        #expect(bigger != nil)
        #expect(CountingURLProtocol.count == 2)
    }
}
