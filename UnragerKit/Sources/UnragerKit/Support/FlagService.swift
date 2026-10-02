import Foundation

/// The per-author decoration derived from an about-account lookup: the flag
/// emoji for feed/thread rows, plus the country name and full about-profile
/// for the profile header. `absent` is the cached "X has no about data for
/// this user" value.
public struct AuthorFlag: Sendable, Equatable {
    public let flag: String?
    public let country: String?
    public let profile: AboutProfile?

    public init(flag: String?, country: String?, profile: AboutProfile?) {
        self.flag = flag
        self.country = country
        self.profile = profile
    }

    public static let absent = AuthorFlag(flag: nil, country: nil, profile: nil)
}

/// Session-scoped resolver for author country flags over
/// `GET /api/about/{rest_id}`.
///
/// - In-memory cache keyed by `rest_id`; `resolved` and `none` results cache
///   for the app session.
/// - Concurrent requests for the same id coalesce onto one in-flight fetch.
/// - Upstream fetches dispatch strictly one at a time (the server
///   single-flights the X query anyway, so parallel requests would only queue
///   there), newest request first: the rows just configured are the ones on
///   screen, so a burst of lookups from a fast scroll serves the visible rows
///   before the ones already scrolled past.
/// - A `deferred` response (or transport failure) is never cached; the id
///   backs off for `retryInterval` (default 60s) before another attempt.
public actor FlagService {
    public typealias Fetch = @Sendable (_ restID: String, _ screenName: String) async throws -> AboutView

    private let fetch: Fetch
    private let retryInterval: TimeInterval
    private let now: @Sendable () -> Date

    private var cache: [String: AuthorFlag] = [:]
    private var deferredUntil: [String: Date] = [:]
    /// Ids waiting for their turn, oldest first; the worker takes from the end.
    private var queue: [String] = []
    private var screenNames: [String: String] = [:]
    private var fetching: String?
    private var waiters: [String: [CheckedContinuation<AuthorFlag?, Never>]] = [:]
    private var workerRunning = false

    public init(fetch: @escaping Fetch,
                retryInterval: TimeInterval = 60,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.fetch = fetch
        self.retryInterval = retryInterval
        self.now = now
    }

    public init(api: APIClient, retryInterval: TimeInterval = 60) {
        self.init(fetch: { try await api.about(restID: $0, screenName: $1) },
                  retryInterval: retryInterval)
    }

    /// How long a deferred id waits before another attempt is worth making.
    public var retryDelay: TimeInterval { retryInterval }

    /// The cached result if this author already resolved (or resolved to
    /// "none") this session, else nil.
    public func cached(restID: String) -> AuthorFlag? {
        cache[restID]
    }

    /// Resolves the author's flag. Returns the cached value on a hit, joins
    /// the queued or in-flight fetch for the same id, and returns nil while the
    /// id is deferred (rate-limited upstream) — callers may retry later; the
    /// backoff makes premature retries free.
    public func resolve(restID: String, screenName: String) async -> AuthorFlag? {
        if let hit = cache[restID] { return hit }
        if let until = deferredUntil[restID], now() < until { return nil }
        deferredUntil[restID] = nil
        return await withCheckedContinuation { continuation in
            waiters[restID, default: []].append(continuation)
            if fetching != restID {
                queue.removeAll { $0 == restID }
                queue.append(restID)
                screenNames[restID] = screenName
            }
            startWorkerIfNeeded()
        }
    }

    private func startWorkerIfNeeded() {
        guard !workerRunning else { return }
        workerRunning = true
        Task { await drain() }
    }

    /// Works through the queue one id at a time, newest first, until it is
    /// empty. Requests that arrive while a fetch is suspended join the queue
    /// (or the fetch's own waiters) and are picked up here.
    private func drain() async {
        while let restID = queue.popLast() {
            guard let screenName = screenNames.removeValue(forKey: restID) else { continue }
            fetching = restID
            let view = try? await fetch(restID, screenName)
            let result = settle(restID: restID, view: view)
            fetching = nil
            for waiter in waiters.removeValue(forKey: restID) ?? [] { waiter.resume(returning: result) }
        }
        workerRunning = false
    }

    /// Records the outcome of a finished fetch: caches final statuses, arms
    /// the retry backoff for deferred/failed ones, and clears the in-flight
    /// slot.
    private func settle(restID: String, view: AboutView?) -> AuthorFlag? {
        guard let view else {
            deferredUntil[restID] = now().addingTimeInterval(retryInterval)
            return nil
        }
        switch view.status {
        case .resolved:
            let result = AuthorFlag(flag: view.flag,
                                    country: view.profile?.accountBasedIn,
                                    profile: view.profile)
            cache[restID] = result
            return result
        case .none:
            cache[restID] = .absent
            return .absent
        case .deferred:
            deferredUntil[restID] = now().addingTimeInterval(retryInterval)
            return nil
        }
    }
}

/// Main-actor facade over `FlagService` for row decoration: synchronous cache
/// hits during cell configuration, plus a callback when a lazy resolve lands
/// so visible rows can be updated in place (no snapshot churn). Callbacks for
/// the same author coalesce onto one service resolve and all fire when it
/// settles. A deferred resolve (X rate-limited the lookup) is tried again after
/// the service's backoff, a few times, so a profile header's "based in" line
/// still appears once X lets the lookup through.
@MainActor
public final class AuthorFlags {
    private let service: FlagService
    private var known: [String: AuthorFlag] = [:]
    private var waiters: [String: [@MainActor (AuthorFlag) -> Void]] = [:]

    public init(service: FlagService) {
        self.service = service
    }

    public convenience init(api: APIClient) {
        self.init(service: FlagService(api: api))
    }

    /// The author's result if already resolved this session, else nil.
    public func cached(restID: String) -> AuthorFlag? {
        known[restID]
    }

    /// Resolves the author's flag, invoking `onResolve` on the main actor —
    /// synchronously on a cache hit, or once the lazy fetch lands.
    public func resolve(restID: String, screenName: String,
                        onResolve: @escaping @MainActor (AuthorFlag) -> Void) {
        if let hit = known[restID] {
            onResolve(hit)
            return
        }
        let firstWaiter = waiters[restID] == nil
        waiters[restID, default: []].append(onResolve)
        guard firstWaiter else { return }
        attempt(restID: restID, screenName: screenName, number: 0)
    }

    private static let maxDeferredRetries = 3

    private func attempt(restID: String, screenName: String, number: Int) {
        Task { [service] in
            let result = await service.resolve(restID: restID, screenName: screenName)
            if result == nil, number < Self.maxDeferredRetries {
                let backoff = await service.retryDelay
                try? await Task.sleep(for: .seconds(backoff + 1))
                self.attempt(restID: restID, screenName: screenName, number: number + 1)
                return
            }
            self.finish(restID: restID, result: result)
        }
    }

    private func finish(restID: String, result: AuthorFlag?) {
        let callbacks = waiters.removeValue(forKey: restID) ?? []
        guard let result else { return }
        known[restID] = result
        for callback in callbacks { callback(result) }
    }
}
