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
///   there).
/// - A `deferred` response (or transport failure) is never cached; the id
///   backs off for `retryInterval` (default 60s) before another attempt.
public actor FlagService {
    public typealias Fetch = @Sendable (_ restID: String, _ screenName: String) async throws -> AboutView

    private let fetch: Fetch
    private let retryInterval: TimeInterval
    private let now: @Sendable () -> Date

    private var cache: [String: AuthorFlag] = [:]
    private var inFlight: [String: Task<AuthorFlag?, Never>] = [:]
    private var deferredUntil: [String: Date] = [:]
    private var queueTail: Task<Void, Never>?

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

    /// The cached result if this author already resolved (or resolved to
    /// "none") this session, else nil.
    public func cached(restID: String) -> AuthorFlag? {
        cache[restID]
    }

    /// Resolves the author's flag. Returns the cached value on a hit, joins
    /// the in-flight fetch on coalescing, and returns nil while the id is
    /// deferred (rate-limited upstream) — callers may retry later; the
    /// backoff makes premature retries free.
    public func resolve(restID: String, screenName: String) async -> AuthorFlag? {
        if let hit = cache[restID] { return hit }
        if let pending = inFlight[restID] { return await pending.value }
        if let until = deferredUntil[restID], now() < until { return nil }
        deferredUntil[restID] = nil
        let task = makeFetchTask(restID: restID, screenName: screenName)
        inFlight[restID] = task
        queueTail = Task { _ = await task.value }
        return await task.value
    }

    /// Builds the fetch task for one id, chained behind the previous tail so
    /// upstream requests run strictly sequentially.
    private func makeFetchTask(restID: String, screenName: String) -> Task<AuthorFlag?, Never> {
        let previous = queueTail
        let fetch = fetch
        return Task {
            await previous?.value
            let view = try? await fetch(restID, screenName)
            return await self.settle(restID: restID, view: view)
        }
    }

    /// Records the outcome of a finished fetch: caches final statuses, arms
    /// the retry backoff for deferred/failed ones, and clears the in-flight
    /// slot.
    private func settle(restID: String, view: AboutView?) -> AuthorFlag? {
        inFlight[restID] = nil
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
/// settles; a deferred resolve drops its callbacks silently — the next cell
/// configure after the backoff retries.
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
        Task { [service] in
            let result = await service.resolve(restID: restID, screenName: screenName)
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
