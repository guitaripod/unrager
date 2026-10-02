import UIKit
import UnragerKit

/// Likes, reposts and bookmarks from any list of posts: the row flips at once,
/// the request goes out, and the confirmed state is handed back to the screen
/// to write into its model. One request per post and kind is in flight at a
/// time — a second tap while the first is pending is ignored — and both the
/// optimistic count and the rollback come from what the row shows, so quick
/// taps can't leave a count off by one.
@MainActor
enum Engagement {
    enum Kind: String {
        case like, repost, bookmark
    }

    /// Sends the request that puts `kind` on (`true`) or off a post. Swapped in
    /// tests.
    static var send: (Kind, Bool, String) async throws -> Void = { kind, on, id in
        switch (kind, on) {
        case (.like, true): _ = try await AppEnvironment.shared.api.like(tweetID: id)
        case (.like, false): _ = try await AppEnvironment.shared.api.unlike(tweetID: id)
        case (.repost, true): _ = try await EngageService.engage.retweet(tweetID: id)
        case (.repost, false): _ = try await EngageService.engage.unretweet(tweetID: id)
        case (.bookmark, true): _ = try await EngageService.engage.bookmark(tweetID: id)
        case (.bookmark, false): _ = try await EngageService.engage.unbookmark(tweetID: id)
        }
    }

    private static var inFlight = Set<String>()
    private static var lastToast = Date.distantPast
    /// A burst of failures (a rate limit hitting several taps) says so once.
    private static let toastInterval: TimeInterval = 3

    /// Toggles `kind` on `tweet`, reading the current state from `cell` when it
    /// still shows that post. `confirmed` runs with the new state once the
    /// server accepts it; a failure puts the row back as it was and tells the
    /// user why through `host`.
    static func toggle(_ kind: Kind, tweet: Tweet, cell: TweetCell?, host: UIViewController?,
                       confirmed: @escaping @MainActor (Bool) -> Void) {
        let key = key(kind, tweet.restID)
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        let shown = cell?.tweetID == tweet.restID ? cell : nil
        let before = shown?.engagement(kind) ?? modelState(kind, of: tweet)
        let target = !before.on
        shown?.applyEngagement(kind, on: target, count: max(0, before.count + (target ? 1 : -1)))
        weak var weakCell = shown
        weak var weakHost = host
        Task {
            defer { inFlight.remove(key) }
            do {
                try await send(kind, target, tweet.restID)
                confirmed(target)
            } catch {
                AppLogger.shared.warn("\(kind.rawValue) failed for \(tweet.restID): \(error)", category: .timeline)
                if let cell = weakCell, cell.tweetID == tweet.restID {
                    cell.applyEngagement(kind, on: before.on, count: before.count)
                }
                Haptics.error()
                report(error, on: weakHost)
            }
        }
    }

    private static func key(_ kind: Kind, _ id: String) -> String { "\(id)-\(kind.rawValue)" }

    private static func modelState(_ kind: Kind, of tweet: Tweet) -> (on: Bool, count: Int) {
        switch kind {
        case .like: return (tweet.favorited, tweet.likeCount)
        case .repost: return (tweet.retweeted, tweet.retweetCount)
        case .bookmark: return (tweet.bookmarked, tweet.bookmarkCount)
        }
    }

    private static func report(_ error: any Error, on host: UIViewController?) {
        guard let host, host.viewIfLoaded?.window != nil, host.presentedViewController == nil,
              Date().timeIntervalSince(lastToast) > toastInterval else { return }
        lastToast = Date()
        host.showToast(error.localizedDescription)
    }
}
