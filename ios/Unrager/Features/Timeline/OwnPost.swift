import Foundation
import UnragerKit

/// Which posts belong to the signed-in account, decided by handle without
/// case, the same way "Liked by" and the own-post analytics decide it.
enum OwnPost {
    /// Whether the signed-in account wrote `tweet` (for a repost: the original).
    static func isOwn(_ tweet: Tweet, viewerHandle: String?) -> Bool {
        RepostLine.isViewer(tweet.author, viewerHandle: viewerHandle)
    }

    /// Whether `tweet` offers Delete: an own post, except where it shows as the
    /// account's own repost, whose row offers "Undo repost" instead.
    static func canDelete(_ tweet: Tweet, viewerHandle: String?) -> Bool {
        guard isOwn(tweet, viewerHandle: viewerHandle) else { return false }
        guard let reposter = tweet.retweetedBy else { return true }
        return !RepostLine.isViewer(reposter, viewerHandle: viewerHandle)
    }

    /// Posted with the deleted post's id under `idKey` once a delete succeeds,
    /// so every list showing it takes it out.
    static let didDelete = Notification.Name("unrager.postDidDelete")
    static let idKey = "id"
}
