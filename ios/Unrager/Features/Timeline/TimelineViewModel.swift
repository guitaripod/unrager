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
    }

    let tweets = CurrentValueSubject<[Tweet], Never>([])
    let isLoading = CurrentValueSubject<Bool, Never>(false)
    let isRefreshing = CurrentValueSubject<Bool, Never>(false)
    let errorMessage = PassthroughSubject<String, Never>()
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
        refresh()
    }

    private func reset() {
        cursor = nil
        exhausted = false
        hasLoadedOnce = false
        seenIDs.removeAll()
        readIDs.removeAll()
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
            reconcileSeen(newIDs)
            cursor = page.cursor
            if page.cursor == nil || (newIDs.isEmpty && !reset) {
                exhausted = true
            }
            AppLogger.shared.info("feed loaded +\(newIDs.count) (\(current.count) total)", category: .timeline)
            hasLoadedOnce = true
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
            tweets.send([])
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
                let hidden = await classifyHidden(fresh.map(\.restID))
                if Task.isCancelled { return }
                for tweet in fresh where !hidden.contains(tweet.restID) {
                    survivors.append(tweet)
                    collectingProgress.send(survivors.count)
                }
                if page.cursor == nil { exhausted = true; break }
            }
            var current = tweets.value
            current.append(contentsOf: survivors)
            tweets.send(current)
            reconcileSeen(survivors.map(\.restID))
            if survivors.isEmpty, cursor == nil { exhausted = true }
            AppLogger.shared.info(
                "filter batch +\(survivors.count) survivors over \(pages) page(s) (\(current.count) total)",
                category: .timeline)
            hasLoadedOnce = true
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

    /// Runs the rage-filter rubric over the given ids and returns the set the
    /// model flagged `hide`. A stream error (e.g. Ollama down) yields an empty
    /// set, so every tweet is treated as a keep.
    private func classifyHidden(_ ids: [String]) async -> Set<String> {
        guard !ids.isEmpty else { return [] }
        var hidden = Set<String>()
        do {
            for try await verdict in api.filterStream(ids: ids) where verdict.verdict == .hide {
                hidden.insert(verdict.id)
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
