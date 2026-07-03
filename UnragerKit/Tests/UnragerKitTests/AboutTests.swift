import Foundation
import Testing
@testable import UnragerKit

@Suite("About view decoding matches the wire contract")
struct AboutDecodingTests {
    private func decode(_ json: String) throws -> AboutView {
        try UnragerJSON.decode(AboutView.self, from: Data(json.utf8))
    }

    @Test("Resolved with a full profile carries alpha2 and flag")
    func resolvedFull() throws {
        let json = """
        {
          "status": "resolved",
          "profile": {
            "rest_id": "44196397",
            "handle": "elonmusk",
            "name": "Elon Musk",
            "account_based_in": "United States",
            "location_accurate": true,
            "source": "Signup country",
            "username_changes": 2,
            "affiliate_username": "xai",
            "created_at": "2009-06-02T20:12:29Z",
            "is_blue_verified": true,
            "verified": false,
            "verified_since": "2023-04-01T00:00:00Z"
          },
          "alpha2": "US",
          "flag": "🇺🇸"
        }
        """
        let view = try decode(json)
        #expect(view.status == .resolved)
        #expect(view.alpha2 == "US")
        #expect(view.flag == "🇺🇸")
        let profile = try #require(view.profile)
        #expect(profile.restID == "44196397")
        #expect(profile.handle == "elonmusk")
        #expect(profile.accountBasedIn == "United States")
        #expect(profile.locationAccurate == true)
        #expect(profile.source == "Signup country")
        #expect(profile.usernameChanges == 2)
        #expect(profile.affiliateUsername == "xai")
        #expect(profile.isBlueVerified)
        #expect(!profile.verified)
        #expect(profile.createdAt != nil)
        #expect(profile.verifiedSince != nil)
    }

    @Test("Resolved with no based-in country leaves alpha2 and flag nil")
    func resolvedWithoutCountry() throws {
        let json = """
        {
          "status": "resolved",
          "profile": {"rest_id": "1", "handle": "a", "name": "A",
                      "account_based_in": null},
          "alpha2": null,
          "flag": null
        }
        """
        let view = try decode(json)
        #expect(view.status == .resolved)
        #expect(view.profile?.accountBasedIn == nil)
        #expect(view.alpha2 == nil)
        #expect(view.flag == nil)
    }

    @Test("Sparse profile decodes with defaults for optional fields")
    func sparseProfile() throws {
        let json = """
        {"status":"resolved","profile":{"rest_id":"9","handle":"b","name":"B"},
         "alpha2":null,"flag":null}
        """
        let profile = try #require(try decode(json).profile)
        #expect(profile.accountBasedIn == nil)
        #expect(profile.locationAccurate == nil)
        #expect(profile.source == nil)
        #expect(profile.usernameChanges == nil)
        #expect(profile.affiliateUsername == nil)
        #expect(profile.createdAt == nil)
        #expect(!profile.isBlueVerified)
        #expect(!profile.verified)
        #expect(profile.verifiedSince == nil)
    }

    @Test("None with explicit nulls")
    func noneWithNulls() throws {
        let view = try decode(#"{"status":"none","profile":null,"alpha2":null,"flag":null}"#)
        #expect(view.status == AboutStatus.none)
        #expect(view.profile == nil)
        #expect(view.alpha2 == nil)
        #expect(view.flag == nil)
    }

    @Test("None with omitted fields")
    func noneOmitted() throws {
        let view = try decode(#"{"status":"none"}"#)
        #expect(view.status == AboutStatus.none)
        #expect(view.profile == nil)
        #expect(view.flag == nil)
    }

    @Test("Deferred, both omitted and null-bearing")
    func deferred() throws {
        #expect(try decode(#"{"status":"deferred"}"#).status == .deferred)
        let nulled = try decode(#"{"status":"deferred","profile":null,"alpha2":null,"flag":null}"#)
        #expect(nulled.status == .deferred)
        #expect(nulled.profile == nil)
    }
}

@Suite("APIClient about endpoint")
struct AboutEndpointTests {
    private actor RecordingTransport: HTTPTransport {
        private(set) var urls: [URL] = []

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            urls.append(request.url)
            return HTTPResponse(status: 200, headers: [:],
                                body: Data(#"{"status":"none","profile":null,"alpha2":null,"flag":null}"#.utf8))
        }

        func stream(_ request: HTTPRequest) async throws -> (Int, AsyncThrowingStream<String, Error>) {
            (200, AsyncThrowingStream { $0.finish() })
        }

        func lastURL() -> URL? { urls.last }
    }

    @Test("Builds /api/about/{rest_id}?screen_name=… and decodes the view")
    func aboutURL() async throws {
        let transport = RecordingTransport()
        let client = APIClient(transport: transport, baseURL: { URL(string: "http://server:7777")! })
        let view = try await client.about(restID: "44196397", screenName: "elonmusk")
        #expect(view.status == AboutStatus.none)
        let url = try #require(await transport.lastURL())
        #expect(url.path == "/api/about/44196397")
        #expect(url.query == "screen_name=elonmusk")
    }
}

@Suite("FlagService caching, coalescing and backoff")
struct FlagServiceTests {
    private actor FetchLog {
        private(set) var calls: [String] = []
        private(set) var live = 0
        private(set) var maxLive = 0

        func begin(_ id: String) {
            calls.append(id)
            live += 1
            maxLive = max(maxLive, live)
        }

        func end() { live -= 1 }
    }

    private static func resolvedView(country: String? = "Japan", flag: String? = "🇯🇵") -> AboutView {
        AboutView(status: .resolved,
                  profile: AboutProfile(restID: "1", handle: "a", name: "A", accountBasedIn: country),
                  alpha2: flag == nil ? nil : "JP", flag: flag)
    }

    @Test("Resolved caches for the session — one fetch, then cache hits")
    func resolvedCaches() async {
        let log = FetchLog()
        let service = FlagService(fetch: { id, _ in
            await log.begin(id)
            await log.end()
            return Self.resolvedView()
        })
        let first = await service.resolve(restID: "1", screenName: "a")
        #expect(first?.flag == "🇯🇵")
        #expect(first?.country == "Japan")
        #expect(first?.profile?.handle == "a")
        let second = await service.resolve(restID: "1", screenName: "a")
        #expect(second == first)
        #expect(await service.cached(restID: "1") == first)
        #expect(await log.calls == ["1"])
    }

    @Test("None caches too — no re-fetch for flagless users")
    func noneCaches() async {
        let log = FetchLog()
        let service = FlagService(fetch: { id, _ in
            await log.begin(id)
            await log.end()
            return AboutView(status: .none)
        })
        let first = await service.resolve(restID: "2", screenName: "b")
        #expect(first == .absent)
        let second = await service.resolve(restID: "2", screenName: "b")
        #expect(second == .absent)
        #expect(await log.calls == ["2"])
    }

    @Test("Concurrent resolves for one id coalesce onto a single fetch")
    func coalesces() async {
        let log = FetchLog()
        let service = FlagService(fetch: { id, _ in
            await log.begin(id)
            try? await Task.sleep(nanoseconds: 20_000_000)
            await log.end()
            return Self.resolvedView()
        })
        async let a = service.resolve(restID: "3", screenName: "c")
        async let b = service.resolve(restID: "3", screenName: "c")
        async let c = service.resolve(restID: "3", screenName: "c")
        let results = await [a, b, c]
        #expect(results.allSatisfy { $0?.flag == "🇯🇵" })
        #expect(await log.calls == ["3"])
    }

    @Test("Fetches for different ids dispatch sequentially, never in parallel")
    func sequentialDispatch() async {
        let log = FetchLog()
        let service = FlagService(fetch: { id, _ in
            await log.begin(id)
            try? await Task.sleep(nanoseconds: 10_000_000)
            await log.end()
            return Self.resolvedView()
        })
        await withTaskGroup(of: Void.self) { group in
            for id in ["a1", "a2", "a3", "a4"] {
                group.addTask { _ = await service.resolve(restID: id, screenName: id) }
            }
        }
        #expect(await log.maxLive == 1)
        #expect(await log.calls.count == 4)
    }

    @Test("Deferred backs off: no re-fetch inside the window, retry after it")
    func deferredBackoff() async {
        let clock = MutableClock(now: Date(timeIntervalSince1970: 1_000_000))
        let log = FetchLog()
        let service = FlagService(
            fetch: { id, _ in
                await log.begin(id)
                await log.end()
                return AboutView(status: .deferred)
            },
            retryInterval: 60,
            now: { clock.now })

        #expect(await service.resolve(restID: "5", screenName: "e") == nil)
        #expect(await service.resolve(restID: "5", screenName: "e") == nil)
        #expect(await log.calls == ["5"])
        #expect(await service.cached(restID: "5") == nil)

        clock.advance(by: 61)
        #expect(await service.resolve(restID: "5", screenName: "e") == nil)
        #expect(await log.calls == ["5", "5"])
    }

    @Test("Transport failure behaves like deferred — uncached, backed off")
    func failureBacksOff() async {
        let clock = MutableClock(now: Date(timeIntervalSince1970: 2_000_000))
        let log = FetchLog()
        let service = FlagService(
            fetch: { id, _ in
                await log.begin(id)
                await log.end()
                throw APIError.network("connection refused")
            },
            retryInterval: 60,
            now: { clock.now })

        #expect(await service.resolve(restID: "6", screenName: "f") == nil)
        #expect(await service.resolve(restID: "6", screenName: "f") == nil)
        #expect(await log.calls == ["6"])
        clock.advance(by: 120)
        _ = await service.resolve(restID: "6", screenName: "f")
        #expect(await log.calls == ["6", "6"])
    }

    @Test("Resolved without a country still exposes the profile, no flag")
    func resolvedWithoutCountry() async {
        let service = FlagService(fetch: { _, _ in
            Self.resolvedView(country: nil, flag: nil)
        })
        let result = await service.resolve(restID: "7", screenName: "g")
        #expect(result?.flag == nil)
        #expect(result?.country == nil)
        #expect(result?.profile != nil)
    }
}

/// A test clock whose "now" can be advanced manually; lock-guarded so the
/// `@Sendable` now-closure can read it from any executor.
private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(now: Date) { value = now }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        value = value.addingTimeInterval(seconds)
    }
}

@Suite("AuthorFlags main-actor facade")
@MainActor
struct AuthorFlagsTests {
    @Test("Resolve calls back and future lookups hit the synchronous cache")
    func resolveThenCached() async throws {
        let service = FlagService(fetch: { _, _ in
            AboutView(status: .resolved,
                      profile: AboutProfile(restID: "1", handle: "a", name: "A",
                                            accountBasedIn: "Finland"),
                      alpha2: "FI", flag: "🇫🇮")
        })
        let flags = AuthorFlags(service: service)
        #expect(flags.cached(restID: "1") == nil)

        let resolved = await withCheckedContinuation { continuation in
            flags.resolve(restID: "1", screenName: "a") { continuation.resume(returning: $0) }
        }
        #expect(resolved.flag == "🇫🇮")
        #expect(resolved.country == "Finland")
        #expect(flags.cached(restID: "1")?.flag == "🇫🇮")

        var synchronous: AuthorFlag?
        flags.resolve(restID: "1", screenName: "a") { synchronous = $0 }
        #expect(synchronous?.flag == "🇫🇮")
    }

    @Test("Waiters coalesce: every caller is called back off one fetch")
    func waitersCoalesce() async {
        let log = Counter()
        let service = FlagService(fetch: { _, _ in
            await log.increment()
            try? await Task.sleep(nanoseconds: 20_000_000)
            return AboutView(status: .none)
        })
        let flags = AuthorFlags(service: service)
        var results: [AuthorFlag] = []
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let callback: @MainActor (AuthorFlag) -> Void = { flag in
                results.append(flag)
                if results.count == 2 { done.resume() }
            }
            flags.resolve(restID: "9", screenName: "z", onResolve: callback)
            flags.resolve(restID: "9", screenName: "z", onResolve: callback)
        }
        #expect(results == [.absent, .absent])
        #expect(await log.count == 1)
    }

    private actor Counter {
        private(set) var count = 0
        func increment() { count += 1 }
    }
}
