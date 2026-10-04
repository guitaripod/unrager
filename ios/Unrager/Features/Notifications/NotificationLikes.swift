import UIKit
import UnragerKit

/// Whether the user has liked the post each reply, mention or quote row is
/// about, so the row can offer a heart. A tap flips the heart at once and tells
/// the server; a refusal puts it back. One request per post is in flight at a
/// time, so a second tap while the first is pending is ignored.
@MainActor
final class NotificationLikes {
    var onChange: ((String) -> Void)?

    private var states: [String: Bool] = [:]
    private var pending = Set<String>()

    /// Whether the post behind `notification` is liked, or nil when the row is
    /// not something to like.
    func isLiked(_ notification: XNotification) -> Bool? {
        guard NotificationPresentation.canLike(notification), let id = notification.targetTweetID else { return nil }
        return states[id] ?? notification.targetTweetFavorited
    }

    /// Likes the post behind `notification`, or takes the like back. `failed`
    /// runs with the reason when the server refuses.
    func toggle(_ notification: XNotification, failed: @escaping @MainActor (any Error) -> Void) {
        guard let before = isLiked(notification), let id = notification.targetTweetID,
              pending.insert(id).inserted else { return }
        let target = !before
        set(target, for: id)
        target ? Haptics.tap() : Haptics.selection()
        Task {
            defer { pending.remove(id) }
            do {
                try await Engagement.send(.like, target, id)
            } catch {
                AppLogger.shared.warn("like failed for \(id): \(error)", category: .timeline)
                set(before, for: id)
                Haptics.error()
                failed(error)
            }
        }
    }

    private func set(_ liked: Bool, for tweetID: String) {
        states[tweetID] = liked
        onChange?(tweetID)
    }
}
