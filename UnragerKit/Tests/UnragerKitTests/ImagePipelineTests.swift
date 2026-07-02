import Foundation
import Testing
@testable import UnragerKit

/// Holds every request open until `completeAll`/`failAll` releases it, so tests
/// can observe the pipeline's in-flight bookkeeping deterministically.
private final class StallingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pending: [StallingURLProtocol] = []
    nonisolated(unsafe) static var responseBody = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.pending.append(self)
        Self.lock.unlock()
    }

    override func stopLoading() {}

    static var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count
    }

    static func completeAll() {
        lock.lock()
        let held = pending
        pending.removeAll()
        lock.unlock()
        for item in held {
            guard let url = item.request.url,
                  let response = HTTPURLResponse(url: url, statusCode: 200,
                                                 httpVersion: nil, headerFields: nil) else { continue }
            item.client?.urlProtocol(item, didReceive: response, cacheStoragePolicy: .notAllowed)
            item.client?.urlProtocol(item, didLoad: responseBody)
            item.client?.urlProtocolDidFinishLoading(item)
        }
    }

    static func reset() {
        lock.lock()
        pending.removeAll()
        lock.unlock()
    }
}

@Suite("ImagePipeline shared-load cancellation", .serialized)
struct ImagePipelineTests {
    /// A 1×1 red PNG.
    private static let pngData = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

    private func makePipeline() -> ImagePipeline {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StallingURLProtocol.self]
        return ImagePipeline(memoryLimitBytes: 8 * 1024 * 1024, sessionConfiguration: configuration)
    }

    private func waitForInterest(_ pipeline: ImagePipeline, url: URL, toBe count: Int) async -> Bool {
        for _ in 0..<4_000 {
            if await pipeline.interestCount(for: url) == count { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return false
    }

    @Test("Cancelling one consumer's task does not kill a shared load another consumer awaits")
    func cancelIsRefcounted() async throws {
        StallingURLProtocol.reset()
        StallingURLProtocol.responseBody = Self.pngData
        let pipeline = makePipeline()
        let url = URL(string: "https://stall.test/avatar-shared.png")!

        let first = Task { await pipeline.image(for: url, maxPixel: 64) }
        #expect(await waitForInterest(pipeline, url: url, toBe: 1))
        let second = Task { await pipeline.image(for: url, maxPixel: 64) }
        #expect(await waitForInterest(pipeline, url: url, toBe: 2))

        first.cancel()
        #expect(await waitForInterest(pipeline, url: url, toBe: 1))

        StallingURLProtocol.completeAll()
        let survivor = await second.value
        #expect(survivor != nil)
        #expect(survivor?.pixelWidth == 1)
        _ = await first.value
        #expect(await pipeline.cached(url) != nil)
    }

    @Test("The load is cancelled once the last consumer's task cancels")
    func lastCancelStopsTheLoad() async throws {
        StallingURLProtocol.reset()
        StallingURLProtocol.responseBody = Self.pngData
        let pipeline = makePipeline()
        let url = URL(string: "https://stall.test/avatar-abandoned.png")!

        let first = Task { await pipeline.image(for: url, maxPixel: 64) }
        #expect(await waitForInterest(pipeline, url: url, toBe: 1))
        let second = Task { await pipeline.image(for: url, maxPixel: 64) }
        #expect(await waitForInterest(pipeline, url: url, toBe: 2))

        first.cancel()
        second.cancel()
        #expect(await waitForInterest(pipeline, url: url, toBe: 0))
        #expect(await first.value == nil)
        #expect(await second.value == nil)
        StallingURLProtocol.reset()
    }

    @Test("Cancelling a prefetch withdraws only the prefetch's own interest")
    func prefetchCancelIsScoped() async throws {
        StallingURLProtocol.reset()
        StallingURLProtocol.responseBody = Self.pngData
        let pipeline = makePipeline()
        let url = URL(string: "https://stall.test/avatar-prefetched.png")!

        let visible = Task { await pipeline.image(for: url, maxPixel: 64) }
        #expect(await waitForInterest(pipeline, url: url, toBe: 1))
        await pipeline.prefetch(url, maxPixel: 64)
        #expect(await waitForInterest(pipeline, url: url, toBe: 2))

        await pipeline.cancelPrefetch(url)
        #expect(await waitForInterest(pipeline, url: url, toBe: 1))

        StallingURLProtocol.completeAll()
        #expect(await visible.value != nil)
    }

    @Test("Cancelling a prefetch that was never registered is a no-op")
    func cancelWithoutPrefetchIsNoOp() async throws {
        StallingURLProtocol.reset()
        StallingURLProtocol.responseBody = Self.pngData
        let pipeline = makePipeline()
        let url = URL(string: "https://stall.test/avatar-visible-only.png")!

        let visible = Task { await pipeline.image(for: url, maxPixel: 64) }
        #expect(await waitForInterest(pipeline, url: url, toBe: 1))

        await pipeline.cancelPrefetch(url)
        #expect(await pipeline.interestCount(for: url) == 1)

        StallingURLProtocol.completeAll()
        #expect(await visible.value != nil)
    }

    @Test("Repeated prefetches of the same URL hold a single unit of interest")
    func prefetchIsDedupedPerURL() async throws {
        StallingURLProtocol.reset()
        StallingURLProtocol.responseBody = Self.pngData
        let pipeline = makePipeline()
        let url = URL(string: "https://stall.test/avatar-reprefetched.png")!

        await pipeline.prefetch(url, maxPixel: 64)
        #expect(await waitForInterest(pipeline, url: url, toBe: 1))
        await pipeline.prefetch(url, maxPixel: 64)
        await pipeline.prefetch(url, maxPixel: 64)
        #expect(await pipeline.interestCount(for: url) == 1)

        await pipeline.cancelPrefetch(url)
        #expect(await waitForInterest(pipeline, url: url, toBe: 0))
        StallingURLProtocol.reset()
    }

    @Test("A completed load leaves no in-flight interest behind")
    func completionClearsInterest() async throws {
        StallingURLProtocol.reset()
        StallingURLProtocol.responseBody = Self.pngData
        let pipeline = makePipeline()
        let url = URL(string: "https://stall.test/avatar-completed.png")!

        let first = Task { await pipeline.image(for: url, maxPixel: 64) }
        #expect(await waitForInterest(pipeline, url: url, toBe: 1))
        let second = Task { await pipeline.image(for: url, maxPixel: 64) }
        #expect(await waitForInterest(pipeline, url: url, toBe: 2))

        StallingURLProtocol.completeAll()
        #expect(await first.value != nil)
        #expect(await second.value != nil)
        #expect(await pipeline.interestCount(for: url) == 0)
        #expect(await pipeline.cached(url) != nil)
    }
}
