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
        refresh()
    }

    private func reset() {
        cursor = nil
        exhausted = false
        hasLoadedOnce = false
        seenIDs.removeAll()
        collectingProgress.send(nil)
        footerState.send(.none)
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
                let kept = await keepVerdicts(for: fresh)
                if Task.isCancelled { return }
                survivors.append(contentsOf: kept)
                collectingProgress.send((survivors.count, Self.collectTarget))
                if page.cursor == nil { exhausted = true; break }
            }
            if Task.isCancelled { return }
            var current = reset ? [] : tweets.value
            if reset { tweets.send([]) }
            current.append(contentsOf: survivors)
            tweets.send(current)
            if exhausted {
                footerState.send(current.isEmpty ? .none : .endOfFeed)
            } else if survivors.isEmpty && !reset {
                footerState.send(.caughtUp)
            } else {
                footerState.send(.none)
            }
            AppLogger.shared.info("feed collected +\(survivors.count) over \(pages) page(s) (\(current.count) total)", category: .timeline)
            hasLoadedOnce = true
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

    /// Classifies `tweets` and returns only those the model keeps, in their
    /// original order. Drains the filter SSE stream collecting hide verdicts;
    /// any tweet not flagged hide by stream end is a keep (so an unreachable
    /// classifier keeps everything).
    private func keepVerdicts(for tweets: [Tweet]) async -> [Tweet] {
        guard !tweets.isEmpty else { return [] }
        let ids = tweets.map(\.restID)
        var hidden = Set<String>()
        let stream = api.filterStream(ids: ids)
        do {
            for try await verdict in stream where verdict.verdict == .hide {
                hidden.insert(verdict.id)
            }
        } catch {
            AppLogger.shared.debug("filter stream ended: \(error)", category: .timeline)
        }
        return tweets.filter { !hidden.contains($0.restID) }
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
