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
    /// While the rage filter is on, the feed collects keep-verdict tweets across
    /// pages before publishing any. This emits `(collected, target)` so the feed
    /// can show a "collecting tweets… N/25" affordance in place of the spinner,
    /// and `nil` once a batch is published.
    let collectingProgress = CurrentValueSubject<(Int, Int)?, Never>(nil)

    /// The end-of-feed state for the footer: the cursor is exhausted (no more
    /// pages) vs. a page returned nothing but the cursor is still alive (the X
    /// timeline temporarily returned an empty append). Mirrors the TUI's
    /// "[end of timeline]" vs "[caught up · scroll to retry]" header.
    enum FooterState: Equatable { case none, endOfFeed, caughtUp }
    let footerState = CurrentValueSubject<FooterState, Never>(.none)

    /// "updated Nm ago" freshness of the materialized Home buffer, or `nil` for
    /// non-Home feeds, a cold buffer, or a status fetch error — the feed hides
    /// the label when nil. Refreshed after each successful Home load/refresh.
    let freshness = CurrentValueSubject<String?, Never>(nil)

    private(set) var source: Source
    var awaitingQuery: Bool { isAwaitingQuery }
    /// True once a load for the current source has settled (success or error).
    /// Lets the feed show a spinner — not the "Nothing here" illustration —
    /// while a feed (or a feed switch) is still in flight.
    private(set) var hasLoadedOnce = false
    private let api = AppEnvironment.shared.api
    private var cursor: String?
    private var exhausted = false
    private var seenIDs = Set<String>()
    private var loadTask: Task<Void, Never>?
    private var filterTask: Task<Void, Never>?
    private var freshnessTask: Task<Void, Never>?

    /// How many keep-verdict tweets a collect batch aims to gather before
    /// publishing, and the hard cap on pages fetched per batch (so a feed that's
    /// mostly hidden still publishes rather than scrolling forever). Mirrors the
    /// TUI's collect-then-show behavior.
    private static let collectTarget = 25
    private static let collectPageCap = 8

    init(source: Source) {
        self.source = source
    }

    func updateSource(_ newSource: Source) {
        guard newSource != source else { return }
        source = newSource
        reset()
        seedFromCache()
        refresh()
    }

    func refresh() {
        loadTask?.cancel()
        filterTask?.cancel()
        collectingProgress.send(nil)
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
        collectingProgress.send(nil)
        footerState.send(.none)
        freshness.send(nil)
        tweets.send([])
    }

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
        }
        if AppSettings.filterEnabled {
            await collectBatch(reset: reset)
        } else {
            await loadImmediate(reset: reset)
        }
    }

    /// Filter-off path: fetch one page and publish it immediately.
    private func loadImmediate(reset: Bool) async {
        do {
            let page = try await fetch(cursor: reset ? nil : cursor)
            if Task.isCancelled { return }
            if reset {
                seenIDs.removeAll()
                tweets.send([])
            }
            var current = tweets.value
            var added = 0
            for tweet in page.tweets where !seenIDs.contains(tweet.restID) {
                seenIDs.insert(tweet.restID)
                current.append(tweet)
                added += 1
            }
            tweets.send(current)
            persistCache(current)
            cursor = page.cursor
            if page.cursor == nil {
                exhausted = true
                footerState.send(current.isEmpty ? .none : .endOfFeed)
            } else if added == 0 && !reset {
                footerState.send(.caughtUp)
            } else {
                footerState.send(.none)
            }
            AppLogger.shared.info("feed loaded +\(added) (\(current.count) total)", category: .timeline)
            hasLoadedOnce = true
            scheduleFreshness()
        } catch is CancellationError {
            return
        } catch let error as APIError {
            if case .cancelled = error { return }
            errorMessage.send(error.localizedDescription)
            hasLoadedOnce = true
            AppLogger.shared.warn("feed load failed: \(error)", category: .timeline)
        } catch {
            errorMessage.send(error.localizedDescription)
            hasLoadedOnce = true
        }
    }

    /// Filter-on path: keep fetching pages and classifying them, accumulating
    /// only keep-verdict tweets, and publish nothing until ~25 survivors are
    /// gathered (or the cursor runs out, or the page cap is hit). The feed never
    /// sees a hidden tweet inserted then removed. If the classifier is down the
    /// stream yields no hides, so every tweet is a keep and a batch fills from
    /// roughly one page.
    private func collectBatch(reset: Bool) async {
        if reset { seenIDs.removeAll() }
        var survivors: [Tweet] = []
        var pages = 0
        collectingProgress.send((0, Self.collectTarget))
        defer { collectingProgress.send(nil) }
        do {
            while survivors.count < Self.collectTarget, pages < Self.collectPageCap {
                let page = try await fetch(cursor: pages == 0 && reset ? nil : cursor)
                if Task.isCancelled { return }
                pages += 1
                cursor = page.cursor
                let fresh = page.tweets.filter { seenIDs.insert($0.restID).inserted }
                let hidden = await streamHidden(fresh.map(\.restID), baseCount: survivors.count)
                if Task.isCancelled { return }
                for tweet in fresh where !hidden.contains(tweet.restID) {
                    survivors.append(tweet)
                }
                collectingProgress.send((survivors.count, Self.collectTarget))
                if page.cursor == nil { exhausted = true; break }
            }
            if Task.isCancelled { return }
            var current = reset ? [] : tweets.value
            current.append(contentsOf: survivors)
            tweets.send(current)
            persistCache(current)
            if exhausted {
                footerState.send(current.isEmpty ? .none : .endOfFeed)
            } else if survivors.isEmpty && !reset {
                footerState.send(.caughtUp)
            } else {
                footerState.send(.none)
            }
            AppLogger.shared.info("feed collected +\(survivors.count) over \(pages) page(s) (\(current.count) total)", category: .timeline)
            hasLoadedOnce = true
            scheduleFreshness()
        } catch is CancellationError {
            return
        } catch let error as APIError {
            if case .cancelled = error { return }
            errorMessage.send(error.localizedDescription)
            hasLoadedOnce = true
            AppLogger.shared.warn("feed collect failed: \(error)", category: .timeline)
        } catch {
            errorMessage.send(error.localizedDescription)
            hasLoadedOnce = true
        }
    }

    /// Streams the rage-filter rubric over the given ids and returns the set the
    /// model flagged `hide`. Bumps `collectingProgress` as each *keep* verdict
    /// arrives (relative to `baseCount` already-collected survivors) so the
    /// "collecting tweets… N/25" counter climbs live instead of jumping at the
    /// end. A stream error (e.g. the classifier being down) yields an empty set,
    /// so anything without a verdict is treated as a keep.
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
                    collectingProgress.send((baseCount + keeps, Self.collectTarget))
                }
            }
        } catch {
            AppLogger.shared.debug("filter stream ended: \(error)", category: .timeline)
        }
        return hidden
    }

    /// The `variant` string the Home buffer reports for the current source, or
    /// `nil` for non-Home feeds (which have no materialized buffer to age).
    private var homeVariant: String? {
        if case let .home(following, _) = source {
            return following ? "home_following" : "home_foryou"
        }
        return nil
    }

    /// Refreshes the freshness label off the back of a successful Home load. A
    /// no-op (clearing any stale value) for non-Home feeds. Runs detached so it
    /// never blocks the load's spinner teardown; a stale in-flight fetch is
    /// cancelled first so the latest load wins.
    private func scheduleFreshness() {
        guard homeVariant != nil else { freshness.send(nil); return }
        freshnessTask?.cancel()
        freshnessTask = Task { [weak self] in await self?.updateFreshness() }
    }

    /// Fetches the materialized-buffer status and publishes "updated Nm ago" for
    /// the current Home variant. Publishes `nil` for non-Home feeds, a cold
    /// buffer (`ageSecs < 0`), a missing variant, or any fetch error.
    func updateFreshness() async {
        guard let variant = homeVariant else { freshness.send(nil); return }
        do {
            let status = try await api.feedStatus()
            if Task.isCancelled { return }
            guard let feed = status.feeds.first(where: { $0.variant == variant }) else {
                freshness.send(nil)
                return
            }
            freshness.send(Self.freshnessBand(feed.ageSecs))
        } catch {
            if Task.isCancelled { return }
            AppLogger.shared.debug("feed status fetch failed: \(error)", category: .timeline)
            freshness.send(nil)
        }
    }

    /// Bands an age in seconds into an "updated Ns/Nm/Nh/Nd ago" string, or
    /// `nil` for a cold buffer (`ageSecs < 0`). Mirrors the TUI / Linux client.
    private static func freshnessBand(_ ageSecs: Int) -> String? {
        guard ageSecs >= 0 else { return nil }
        let unit: String
        switch ageSecs {
        case ..<60: unit = "\(ageSecs)s"
        case ..<3_600: unit = "\(ageSecs / 60)m"
        case ..<86_400: unit = "\(ageSecs / 3_600)h"
        default: unit = "\(ageSecs / 86_400)d"
        }
        return "updated \(unit) ago"
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
