import Foundation
import Combine
import UnragerKit

/// Decides when a feed has genuinely run out of content. Live Home feeds mint
/// a fresh bottom cursor on every page, so cursor comparison alone never fires
/// there — a nil cursor or an echoed-back cursor latches immediately, and a
/// run of `emptyAppendLimit` consecutive non-reset pages yielding zero new
/// tweets latches too (mirroring the TUI's `EMPTY_APPEND_LIMIT` design). Any
/// page that adds tweets, and any reset, clears the run.
struct FeedExhaustion {
    static let emptyAppendLimit = 3

    private(set) var isExhausted = false
    private var emptyAppends = 0

    mutating func reset() {
        isExhausted = false
        emptyAppends = 0
    }

    mutating func registerPage(added: Int, pageCursor: String?, requestCursor: String?, isReset: Bool) {
        if isReset || added > 0 {
            emptyAppends = 0
        } else {
            emptyAppends += 1
        }
        if pageCursor == nil
            || (!isReset && added == 0 && pageCursor == requestCursor)
            || emptyAppends >= Self.emptyAppendLimit {
            isExhausted = true
        }
    }
}

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
                return q.isEmpty ? "bookmarks-all" : "bookmarks-\(q)"
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
    /// True once the feed is exhausted — the feed shows an "all caught up"
    /// footer rather than a "scroll to retry" one.
    var isExhausted: Bool { exhaustion.isExhausted }
    private let api = AppEnvironment.shared.api
    private var cursor: String?
    private var exhaustion = FeedExhaustion()
    private var seenIDs = Set<String>()
    private var loadTask: Task<Void, Never>?
    /// Monotonic id of the newest load; a superseded load must not clear the
    /// loading flags that the current load now owns.
    private var loadGeneration = 0

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

    /// The rage filter exists to de-rage the algorithmic Home feeds. Deliberate
    /// visits — profiles (including the user's own), search, bookmarks,
    /// mentions — load unfiltered and render instantly instead of stalling
    /// behind a collect-then-show classification batch.
    var usesFilterCollect: Bool {
        if case .home = source { return true }
        return false
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
        loadTask = startLoad(reset: true)
    }

    /// Triggers pagination near the end of the list. `isLoading` flips
    /// synchronously in `startLoad`, so two cells hitting the trigger zone in
    /// the same layout pass can't both spawn a load — a duplicate fetch of the
    /// same cursor would yield zero new ids and falsely mark the feed exhausted.
    func loadMoreIfNeeded(currentIndex: Int) {
        guard !exhaustion.isExhausted, !isLoading.value, currentIndex >= tweets.value.count - 5 else { return }
        loadTask = startLoad(reset: false)
    }

    /// Marks the loading state before the task ever runs (the guard in
    /// `loadMoreIfNeeded` reads it synchronously) and stamps the load with a
    /// generation so a superseded load can't clear the flags of its successor.
    private func startLoad(reset: Bool) -> Task<Void, Never> {
        isLoading.send(true)
        loadGeneration += 1
        let generation = loadGeneration
        return Task { await load(reset: reset, generation: generation) }
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
        exhaustion.reset()
        hasLoadedOnce = false
        seenIDs.removeAll()
        readIDs.removeAll()
        persistTask?.cancel()
        persistTask = nil
        freshnessAnchor = nil
        freshness.send(nil)
        tweets.send([])
    }

    // MARK: - Engagement

    /// Writes a confirmed like/unlike back into the published tweets (and the
    /// on-disk seed), so cell reconfigures, context menus and swipe actions all
    /// see the new state — without this, a second heart tap re-sends "like"
    /// forever and any reuse repaints the stale, unliked model.
    func applyLike(id: String, favorited: Bool) {
        applyEngagement(id: id) { $0.togglingLike(to: favorited) }
    }

    /// Writes a confirmed repost/undo back into the published tweets, same
    /// contract as `applyLike`.
    func applyRetweet(id: String, retweeted: Bool) {
        applyEngagement(id: id) { $0.togglingRetweet(to: retweeted) }
    }

    /// Writes a confirmed bookmark/unbookmark back into the published tweets,
    /// same contract as `applyLike`.
    func applyBookmark(id: String, bookmarked: Bool) {
        applyEngagement(id: id) { $0.togglingBookmark(to: bookmarked) }
    }

    /// The shared confirmed-engagement write-back: replaces the matching tweet
    /// with `transform`'s copy (nil = already in that state, nothing to do)
    /// and re-persists the display seed.
    private func applyEngagement(id: String, _ transform: (Tweet) -> Tweet?) {
        var changed = false
        let updated = tweets.value.map { tweet -> Tweet in
            guard tweet.restID == id, let toggled = transform(tweet) else { return tweet }
            changed = true
            return toggled
        }
        guard changed else { return }
        tweets.send(updated)
        schedulePersist()
    }

    private var persistTask: Task<Void, Never>?

    /// Coalesces a burst of engagement write-backs into one disk write: each
    /// call pushes the pending save out another 500 ms, and the latest
    /// published snapshot wins when it fires.
    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled else { return }
            self.persistTask = nil
            self.persistCache(self.tweets.value)
        }
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

    /// Marks every loaded, not-yet-read tweet as seen — the "mark all read"
    /// action (the TUI's `U`). Optimistically flips local state so rows dim and
    /// the unread pill clears immediately, then routes the server write through
    /// the same batched, retry/backoff-protected `flushSeen` path as scroll-past
    /// seen tracking — a one-shot fire-and-forget would let a single network
    /// blip permanently lose the read-state the batched path would have retried.
    func markAllRead() {
        guard supportsSeenTracking else { return }
        let unseen = tweets.value.map(\.restID).filter { !readIDs.contains($0) }
        guard !unseen.isEmpty else { return }
        readIDs.formUnion(unseen)
        seenChanged.send(unseen)
        pendingSeen.formUnion(unseen)
        scheduleFlush()
        AppLogger.shared.info("mark all read queued (\(unseen.count) tweets)", category: .timeline)
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

    private static let maxFlushRetries = 5

    /// Consecutive failed `markSeen` flushes; drives the retry backoff and
    /// resets on the first success.
    private var flushRetries = 0

    private func scheduleFlush(after seconds: Double = 1) {
        guard markTask == nil else { return }
        markTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            await self?.flushSeen()
        }
    }

    /// Sends the pending seen batch. On failure the batch is re-queued and the
    /// flush re-armed with exponential backoff (capped), so one network blip
    /// doesn't silently lose a screenful of read-state; past the cap the ids
    /// stay queued and the next scroll-past re-arms the flush.
    private func flushSeen() async {
        markTask = nil
        let batch = Array(pendingSeen)
        guard !batch.isEmpty else { return }
        pendingSeen.removeAll()
        do {
            _ = try await api.markSeen(ids: batch)
            flushRetries = 0
            readIDs.formUnion(batch)
            seenChanged.send(batch)
            AppLogger.shared.debug("marked \(batch.count) tweets seen", category: .timeline)
        } catch {
            pendingSeen.formUnion(batch)
            guard flushRetries < Self.maxFlushRetries else {
                AppLogger.shared.warn("markSeen failed (retries exhausted, \(batch.count) ids held): \(error)",
                                      category: .timeline)
                return
            }
            flushRetries += 1
            let delay = pow(2, Double(flushRetries))
            AppLogger.shared.warn("markSeen failed, retrying in \(Int(delay))s: \(error)", category: .timeline)
            scheduleFlush(after: delay)
        }
    }

    /// The maximum number of concurrent `checkSeen` round-trips per page —
    /// the API has no batch read-check, but an unbounded burst of 25-40
    /// requests starves the feed fetch and media streams on slow links.
    private static let reconcileWidth = 4

    /// On load, asks the server which freshly-fetched ids are already read so
    /// they render dimmed from the first frame. Checks run a bounded few at a
    /// time.
    private func reconcileSeen(_ ids: [String]) {
        guard ClientSettings.markSeenEnabled, supportsSeenTracking, !ids.isEmpty else { return }
        let api = self.api
        Task { [weak self] in
            let confirmed = await withTaskGroup(of: String?.self) { group -> [String] in
                var pending = ids.makeIterator()
                func addNext() -> Bool {
                    guard let id = pending.next() else { return false }
                    group.addTask { ((try? await api.checkSeen(id: id)) == true) ? id : nil }
                    return true
                }
                for _ in 0..<Self.reconcileWidth where addNext() {}
                var hits: [String] = []
                for await result in group {
                    if let result { hits.append(result) }
                    _ = addNext()
                }
                return hits
            }
            guard let self, !confirmed.isEmpty else { return }
            self.readIDs.formUnion(confirmed)
            self.seenChanged.send(confirmed)
        }
    }

    // MARK: - Freshness

    /// The local-clock instant the materialized buffer was last ingested
    /// (`now - ageSecs` captured at fetch). Re-deriving the label from this lets
    /// "updated Nm ago" climb live without re-fetching; nil hides the label.
    private var freshnessAnchor: Date?

    /// The `/api/feed/status` variant key for the current Home source, or nil on
    /// non-Home sources (search/profile/mentions/bookmarks have no buffer).
    private var homeVariant: String? {
        switch source {
        case let .home(following, _): return following ? "home_following" : "home_foryou"
        default: return nil
        }
    }

    /// Fetches the materialized-buffer status and anchors "updated Nm ago" for
    /// the current Home variant. Publishes nil for non-Home sources, a cold
    /// buffer (`ageSecs < 0`), or any error — so the caption simply hides.
    private func updateFreshness() async {
        guard let variant = homeVariant else {
            freshnessAnchor = nil
            freshness.send(nil)
            return
        }
        do {
            let status = try await api.feedStatus()
            if let age = status.feeds.first(where: { $0.variant == variant })?.ageSecs, age >= 0 {
                freshnessAnchor = Date().addingTimeInterval(-Double(age))
            } else {
                freshnessAnchor = nil
            }
            freshness.send(currentFreshnessLabel())
        } catch {
            AppLogger.shared.debug("feed status failed: \(error)", category: .timeline)
            freshnessAnchor = nil
            freshness.send(nil)
        }
    }

    /// Re-derives "updated Nm ago" from the stored ingest instant so the label
    /// climbs over time without re-fetching. Driven by a timer in the feed view.
    func tickFreshness() {
        guard freshnessAnchor != nil else { return }
        freshness.send(currentFreshnessLabel())
    }

    private func currentFreshnessLabel() -> String? {
        guard let anchor = freshnessAnchor else { return nil }
        return Self.freshnessLabel(ageSecs: max(0, Int(Date().timeIntervalSince(anchor))))
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
    /// Bookmarks never wait — an empty query means the full timeline.
    private var isAwaitingQuery: Bool {
        switch source {
        case let .search(query, _): return query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default: return false
        }
    }

    private func load(reset: Bool, generation: Int) async {
        defer {
            if generation == loadGeneration {
                isLoading.send(false)
                isRefreshing.send(false)
                collectingProgress.send(nil)
            }
        }
        if isAwaitingQuery {
            tweets.send([])
            return
        }
        if reset {
            cursor = nil
            exhaustion.reset()
        }
        if AppSettings.filterEnabled, usesFilterCollect {
            await collectBatch(reset: reset)
        } else {
            await fetchPage(reset: reset)
        }
    }

    /// Filter-off path: fetch one page and publish it immediately. A nil or
    /// echoed-back cursor exhausts the feed at once; live feeds that mint a
    /// fresh cursor per page only exhaust after `FeedExhaustion.emptyAppendLimit`
    /// consecutive pages yield nothing new.
    private func fetchPage(reset: Bool) async {
        do {
            let requestCursor = reset ? nil : cursor
            let page = try await fetch(cursor: requestCursor)
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
            exhaustion.registerPage(added: newIDs.count, pageCursor: page.cursor,
                                    requestCursor: requestCursor, isReset: reset)
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
                let isResetPage = reset && pages == 0
                let requestCursor = isResetPage ? nil : cursor
                let page = try await fetch(cursor: requestCursor)
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
                exhaustion.registerPage(added: fresh.count, pageCursor: page.cursor,
                                        requestCursor: requestCursor, isReset: isResetPage)
                if exhaustion.isExhausted { break }
            }
            var current = reset ? [] : tweets.value
            current.append(contentsOf: survivors)
            tweets.send(current)
            persistCache(current)
            reconcileSeen(survivors.map(\.restID))
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
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty else {
                return try await EngageService.engage.bookmarksTimeline(cursor: cursor)
            }
            return try await api.bookmarks(query: q, cursor: cursor)
        }
    }
}
