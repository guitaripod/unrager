import Foundation
import UnragerKit

/// A glance at how an account's recent posts did, worked out from the posts
/// already on screen: no extra request, and only the numbers X itself shows on
/// each post. Shown on your own profile.
struct ProfileInsights: Equatable {
    static let window = 20
    static let minimumPosts = 3

    let postCount: Int
    let views: Int?
    let likes: Int
    let reposts: Int
    let replies: Int
    let top: Top

    /// The post that did best: the most viewed, or the most liked when X
    /// gave no view counts.
    struct Top: Equatable {
        let tweetID: String
        let text: String
        let metric: String
    }

    /// The last `window` original posts of `tweets` (not reposts, not
    /// replies), or nil when there are fewer than `minimumPosts` to say
    /// anything about.
    static func make(from tweets: [Tweet]) -> ProfileInsights? {
        let own = tweets.filter { $0.retweetedBy == nil && $0.inReplyToTweetID == nil }.prefix(window)
        guard own.count >= minimumPosts, let best = own.max(by: { score($0) < score($1) }) else { return nil }
        let known = own.compactMap(\.viewCount)
        return ProfileInsights(
            postCount: own.count,
            views: known.isEmpty ? nil : known.reduce(0, +),
            likes: own.reduce(0) { $0 + $1.likeCount },
            reposts: own.reduce(0) { $0 + $1.retweetCount },
            replies: own.reduce(0) { $0 + $1.replyCount },
            top: Top(tweetID: best.restID, text: best.text, metric: metric(best)))
    }

    private static func score(_ tweet: Tweet) -> Int {
        tweet.viewCount ?? tweet.likeCount
    }

    private static func metric(_ tweet: Tweet) -> String {
        if let views = tweet.viewCount { return "\(Format.count(views)) \(views == 1 ? "view" : "views")" }
        return "\(Format.count(tweet.likeCount)) \(tweet.likeCount == 1 ? "like" : "likes")"
    }
}
