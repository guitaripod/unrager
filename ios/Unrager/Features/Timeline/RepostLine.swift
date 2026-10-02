import Foundation
import UnragerKit

/// The quiet line above a post that reached a list as someone's repost: who
/// reposted it, or "You reposted" when the signed-in account did.
enum RepostLine {
    /// The line for `tweet`, or nil when it isn't a repost.
    static func text(for tweet: Tweet, viewerHandle: String?) -> String? {
        guard let reposter = tweet.retweetedBy else { return nil }
        return isViewer(reposter, viewerHandle: viewerHandle) ? "You reposted" : "\(reposter.name) reposted"
    }

    /// Whether `user` is the signed-in account; handles compare without case.
    static func isViewer(_ user: User, viewerHandle: String?) -> Bool {
        guard let viewerHandle, !viewerHandle.isEmpty else { return false }
        return user.handle.caseInsensitiveCompare(viewerHandle) == .orderedSame
    }
}
