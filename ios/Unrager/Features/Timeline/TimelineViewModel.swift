import Foundation
import Combine
import UnragerKit

/// Drives any tweet feed: fetches a page, paginates on demand, dedupes by id,
/// and publishes the accumulated tweets. Presentation-agnostic so the same
/// model backs Home, Search, profile timelines, bookmarks and mentions.
@MainActor
final class TimelineViewModel {
    enum Source: Equatable {
        case home(following: Bool, originals: Bool)
        case user(handle: String)
        case search(query: String, product: SourceProduct)
        case mentions
        case bookmarks(query: String)

        /// A stable key for the display-only timeline cache, or `nil` for
        /// ephemeral feeds that shouldn't be seeded (e.g. an empty query).
        var cacheKey: String? {
            switch self {
            case let .home(following, _):
                return following ? "home-following" : "home-foryou"
            case let .user(handle):
                let h = handle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return h.isEmpty ? nil : "user-\(h)"
            case let .search(query, product):
                let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return q.isEmpty ? nil : "search-\(product.rawValue)-\(q)"
            case .mentions:
                return "mentions"
            case let .bookmarks(query):
                let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return q.isEmpty ? nil : "bookmarks-\(q)"
            }
        }
    }

    let tweets = CurrentValueSubject<[Tweet], Never>([])
    let isLoading = CurrentValueSubject<Bool, Never>(false)
    let isRefreshing = CurrentValueSubject<Bool, Never>(false)
    let errorMessage = PassthroughSubject<String, Never>()
    /// "updated Nm ago" freshness of the materialized Home buffer, or nil on
    /// non-Home sources / a cold buffer / a status error. Drives the subtle
    /// freshness caption.
    let freshness = CurrentValueSubject<String?, Never>(nil)
    /// Survivor count while collect-then-show filtering is gathering a batch, or
    /// nil when not collecting. Drives the "collecting tweets… N/25" affordance.
    let collectingProgress = CurrentValueSubject<Int?, Never>(nil)
    /// Emits ids whose seen-state flipped after a server check, so the feed can
    /// reconfigure exactly those rows (dim them) without a full reload.
    let seenChanged = PassthroughSubject<[String], Never>()

    private(set) var source: Source
    var awaitingQuery: Bool { isAwaitingQuery }
    /// True once the cursor is exhausted — the feed shows an "all caught up"
    /// footer rather than a "scroll to retry" one.
    var isExhausted: Bool { exhausted }
    private let api = AppEnvironment.shared.api
    private var cursor: String?
    private var exhausted = false
    private var seenIDs = Set<String>()
    private var loadTask: Task<Void, Never>?

    /// Collect-then-show targets: gather this many keep-verdict tweets before
    /// publishing a batch (matching the TUI), bounded by a page cap so a feed
    /// that's mostly hidden still surfaces something rather than fetching forever.
    static let targetSurvivors = 25
    private static let pageCap = 8
    /// True once a load for the current source has settled (success or error).
    /// Lets the feed show a spinner — not the "Nothing here" illustration —
    /// while a feed (or a feed switch) is still in flight.
    private(set) var hasLoadedOnce = false

    /// Server-confirmed already-read ids for the unread affordance + dimming.
    private var readIDs = Set<String>()
    /// Ids pending a `markSeen` round-trip, flushed in batches.
    private var pendingSeen = Set<String>()
    private var markTask: Task<Void, Never>?

    /// For-You hides seen tweets server-side, so dimming there is moot — the
    /// unread affordance only makes sense on Following and Mentions.
    var supportsSeenTracking: Bool {
        switch source {
        case .home(let following, _): return following
        case .mentions: return true
        default: return false
        }
    }

    init(source: Source) {
        self.source = source
    }

    func updateSource(_ newSource: Source) {
        guard newSource != source else { return }
        source = newSource
        persistSource()
        reset()
        seedFromCache()
        refresh()
    }

    /// Mirrors the active source (and search product / feed mode) to the server
    /// session so it survives relaunch and is shared with the TUI. Only the
    /// source kinds the server tracks are sent.
    private func persistSource() {
        switch source {
        case let .home(following, originals):
            SessionSync.patchSource(.home(following: following))
            SessionSync.patchFeedMode(originals: originals)
        case let .user(handle):
            SessionSync.patchSource(.user(handle: handle))
        case let .search(query, product):
            guard !query.isEmpty else { return }
            SessionSync.patchSource(.search(query: query, product: product))
        case .mentions:
            SessionSync.patchSource(.mentions(target: nil))
        case let .bookmarks(query):
            guard !query.isEmpty else { return }
            SessionSync.patchSource(.bookmarks(query: query))
        }
    }

    func refresh() {
        loadTask?.cancel()
        isRefreshing.send(true)
        loadTask = Task { await load(reset: true) }
    }

    func loadMoreIfNeeded(currentIndex: Int) {
        guard !exhausted, !isLoading.value, currentIndex >= tweets.value.count - 5 else { return }
        loadTask = Task { await load(reset: false) }
    }

    func first() {
        guard tweets.value.isEmpty else { return }
        seedFromCache()
        refresh()
    }

    /// Paints the cached snapshot for the current source so the feed isn't empty
    /// while the real fetch is in flight. Seeds display only: it never touches
    /// `seenIDs`, `cursor`, `hasLoadedOnce`, or `exhausted`, so the pending fetch
    /// still runs and fully replaces these tweets — fresh content can't be
    /// suppressed by the seed. No-op once any tweets are loaded.
    private func seedFromCache() {
        guard tweets.value.isEmpty, let key = source.cacheKey else { return }
        guard let cached = TimelineCache.shared.load(key: key), !cached.tweets.isEmpty else { return }
        tweets.send(cached.tweets)
        AppLogger.shared.debug("seeded \(cached.tweets.count) cached tweets for \(key)", category: .timeline)
    }

    /// Overwrites the on-disk seed with the freshly-fetched tweets after a
    /// reset. Only primary feeds (those with a `cacheKey`) persist.
    private func persistCache(_ tweets: [Tweet]) {
        guard let key = source.cacheKey else { return }
        TimelineCache.shared.save(tweets, key: key)
    }

    private func reset() {
        cursor = nil
        exhausted = false
        hasLoadedOnce = false
        seenIDs.removeAll()
        readIDs.removeAll()
        freshness.send(nil)
        tweets.send([])
    }

    // MARK: - Read tracking

    func isSeen(_ id: String) -> Bool { readIDs.contains(id) }

    /// The number of loaded tweets the server hasn't confirmed as read, for the
    /// `N↑` unread affordance. Zero on feeds without seen-tracking.
    var unreadCount: Int {
        guard supportsSeenTracking else { return 0 }
        return tweets.value.reduce(0) { $0 + (readIDs.contains($1.restID) ? 0 : 1) }
    }

    /// The data-source index of the first not-yet-seen tweet at or after
    /// `after`, for the "jump to next unread" affordance. Wraps to the start.
    func nextUnreadIndex(after current: Int) -> Int? {
        let all = tweets.value
        guard !all.isEmpty else { return nil }
        let ordered = Array((current + 1)..<all.count) + Array(0...max(0, current))
        return ordered.first { idx in idx < all.count && !readIDs.contains(all[idx].restID) }
    }

    /// Queues ids the user has scrolled past for a batched `markSeen`, and
    /// optimistically marks them read locally.
    func enqueueSeen(_ ids: [String]) {
        guard ClientSettings.markSeenEnabled, supportsSeenTracking else { return }
        let fresh = ids.filter { !readIDs.contains($0) && !pendingSeen.contains($0) }
        guard !fresh.isEmpty else { return }
        pendingSeen.formUnion(fresh)
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard markTask == nil else { return }
        markTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            await self?.flushSeen()
        }
    }

    private func flushSeen() async {
        markTask = nil
        let batch = Array(pendingSeen)
        guard !batch.isEmpty else { return }
        pendingSeen.removeAll()
        do {
            _ = try await api.markSeen(ids: batch)
            readIDs.formUnion(batch)
            seenChanged.send(batch)
            AppLogger.shared.debug("marked \(batch.count) tweets seen", category: .timeline)
        } catch {
            AppLogger.shared.warn("markSeen failed: \(error)", category: .timeline)
        }
    }

    /// On load, asks the server which freshly-fetched ids are already read so
    /// they render dimmed from the first frame. Checks run concurrently since
    /// the API offers no batch read-check (only `markSeen` batches).
    private func reconcileSeen(_ ids: [String]) {
        guard ClientSettings.markSeenEnabled, supportsSeenTracking, !ids.isEmpty else { return }
        let api = self.api
        Task { [weak self] in
            let confirmed = await withTaskGroup(of: String?.self) { group -> [String] in
                for id in ids {
                    group.addTask { ((try? await api.checkSeen(id: id)) == true) ? id : nil }
                }
                var hits: [String] = []
                for await result in group { if let result { hits.append(result) } }
                return hits
            }
            guard let self, !confirmed.isEmpty else { return }
            self.readIDs.formUnion(confirmed)
            self.seenChanged.send(confirmed)
        }
    }

    // MARK: - Freshness

    /// The `/api/feed/status` variant key for the current Home source, or nil on
    /// non-Home sources (search/profile/mentions/bookmarks have no buffer).
    private var homeVariant: String? {
        switch source {
        case let .home(following, _): return following ? "home_following" : "home_foryou"
        default: return nil
        }
    }

    /// Fetches the materialized-buffer status and publishes "updated Nm ago" for
    /// the current Home variant. Publishes nil for non-Home sources, a cold
    /// buffer (`ageSecs < 0`), or any error — so the caption simply hides.
    private func updateFreshness() async {
        guard let variant = homeVariant else {
            freshness.send(nil)
            return
        }
        do {
            let status = try await api.feedStatus()
            let label = status.feeds.first { $0.variant == variant }
                .flatMap { Self.freshnessLabel(ageSecs: $0.ageSecs) }
            freshness.send(label)
        } catch {
            AppLogger.shared.debug("feed status failed: \(error)", category: .timeline)
            freshness.send(nil)
        }
    }

    /// "updated Nm ago" for a buffer age in seconds, or nil when the buffer has
    /// never been ingested (`ageSecs < 0`).
    private static func freshnessLabel(ageSecs: Int) -> String? {
        guard ageSecs >= 0 else { return nil }
        let unit: String
        if ageSecs < 60 {
            unit = "\(ageSecs)s"
        } else if ageSecs < 3_600 {
            unit = "\(ageSecs / 60)m"
        } else if ageSecs < 86_400 {
            unit = "\(ageSecs / 3_600)h"
        } else {
            unit = "\(ageSecs / 86_400)d"
        }
        return "updated \(unit) ago"
    }

    /// Sources that need a query show nothing (not an error) until one is set.
    private var isAwaitingQuery: Bool {
        switch source {
        case let .search(query, _): return query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case let .bookmarks(query): return query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default: return false
        }
    }

    private func load(reset: Bool) async {
        if isAwaitingQuery {
            tweets.send([])
            isRefreshing.send(false)
            return
        }
        if reset {
            cursor = nil
            exhausted = false
        }
        isLoading.send(true)
        defer {
            isLoading.send(false)
            isRefreshing.send(false)
            collectingProgress.send(nil)
        }
        if AppSettings.filterEnabled {
            await collectBatch(reset: reset)
        } else {
            await fetchPage(reset: reset)
        }
    }

    /// Filter-off path: fetch one page and publish it immediately.
    private func fetchPage(reset: Bool) async {
        do {
            let page = try await fetch(cursor: reset ? nil : cursor)
            if Task.isCancelled { return }
            if reset {
                seenIDs.removeAll()
                tweets.send([])
            }
            var current = tweets.value
            var newIDs: [String] = []
            for tweet in page.tweets where !seenIDs.contains(tweet.restID) {
                seenIDs.insert(tweet.restID)
                current.append(tweet)
                newIDs.append(tweet.restID)
            }
            tweets.send(current)
            persistCache(current)
            reconcileSeen(newIDs)
            cursor = page.cursor
            if page.cursor == nil || (newIDs.isEmpty && !reset) {
                exhausted = true
            }
            AppLogger.shared.info("feed loaded +\(newIDs.count) (\(current.count) total)", category: .timeline)
            hasLoadedOnce = true
            await updateFreshness()
        } catch is CancellationError {
            return
        } catch let error as APIError {
            if case .cancelled = error { return }
            reportLoadError(error)
        } catch {
            errorMessage.send(error.localizedDescription)
            hasLoadedOnce = true
        }
    }

    /// Filter-on path (collect-then-show, matching the TUI): fetch pages and
    /// classify them in the background, accumulating only keep-verdict tweets,
    /// and publish nothing until the batch fills (`targetSurvivors`), the cursor
    /// exhausts, or the page cap is hit. The feed therefore never visibly
    /// inserts-then-removes a hidden tweet. If Ollama is down `filterStream`
    /// yields no hides, so every tweet survives and the batch fills from ~1 page.
    private func collectBatch(reset: Bool) async {
        if reset {
            seenIDs.removeAll()
        }
        collectingProgress.send(0)
        var survivors: [Tweet] = []
        var pages = 0
        do {
            while survivors.count < Self.targetSurvivors, pages < Self.pageCap {
                let page = try await fetch(cursor: reset && pages == 0 ? nil : cursor)
                if Task.isCancelled { return }
                pages += 1
                cursor = page.cursor

                let fresh = page.tweets.filter { seenIDs.insert($0.restID).inserted }
                let hidden = await streamHidden(fresh.map(\.restID), baseCount: survivors.count)
                if Task.isCancelled { return }
                for tweet in fresh where !hidden.contains(tweet.restID) {
                    survivors.append(tweet)
                }
                collectingProgress.send(survivors.count)
                if page.cursor == nil { exhausted = true; break }
            }
            var current = reset ? [] : tweets.value
            current.append(contentsOf: survivors)
            tweets.send(current)
            persistCache(current)
            reconcileSeen(survivors.map(\.restID))
            if survivors.isEmpty, cursor == nil { exhausted = true }
            AppLogger.shared.info(
                "filter batch +\(survivors.count) survivors over \(pages) page(s) (\(current.count) total)",
                category: .timeline)
            hasLoadedOnce = true
            await updateFreshness()
        } catch is CancellationError {
            return
        } catch let error as APIError {
            if case .cancelled = error { return }
            reportLoadError(error)
        } catch {
            errorMessage.send(error.localizedDescription)
            hasLoadedOnce = true
        }
    }

    /// Streams the rage-filter rubric over the given ids and returns the set the
    /// model flagged `hide`. Bumps `collectingProgress` as each *keep* verdict
    /// arrives (relative to `baseCount` already-collected survivors) so the
    /// "collecting tweets… N/25" counter climbs live instead of jumping at the
    /// end. A stream error (e.g. Ollama down) yields an empty set, so anything
    /// without a verdict is treated as a keep — matching the prior behavior.
    private func streamHidden(_ ids: [String], baseCount: Int) async -> Set<String> {
        guard !ids.isEmpty else { return [] }
        var hidden = Set<String>()
        var keeps = 0
        do {
            for try await verdict in api.filterStream(ids: ids) {
                if Task.isCancelled { return hidden }
                if verdict.verdict == .hide {
                    hidden.insert(verdict.id)
                } else {
                    keeps += 1
                    collectingProgress.send(baseCount + keeps)
                }
            }
        } catch {
            AppLogger.shared.debug("filter stream ended: \(error)", category: .timeline)
        }
        return hidden
    }

    private func reportLoadError(_ error: APIError) {
        errorMessage.send(error.localizedDescription)
        hasLoadedOnce = true
        AppLogger.shared.warn("feed load failed: \(error)", category: .timeline)
    }

    private func fetch(cursor: String?) async throws -> TimelinePage {
        switch source {
        case let .home(following, originals):
            return try await api.home(following: following, originals: originals, cursor: cursor)
        case let .user(handle):
            return try await api.userTimeline(handle: handle, cursor: cursor)
        case let .search(query, product):
            return try await api.search(query: query, product: product, cursor: cursor)
        case .mentions:
            return try await api.mentions(cursor: cursor)
        case let .bookmarks(query):
            return try await api.bookmarks(query: query, cursor: cursor)
        }
    }
}
