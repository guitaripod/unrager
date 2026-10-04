import UIKit
import UnragerKit

/// A paginated "Liked by" list for a post, under a heading that says how many
/// likes it has and which post they are on. Tapping a row opens that user's
/// profile; each row offers Follow where X says whether the viewer does.
final class LikersViewController: PagedUserListViewController {
    private let tweetID: String
    private let likeCount: Int?
    private let heading: UserListHeader?

    init(tweetID: String, tweet: Tweet? = nil) {
        self.tweetID = tweetID
        self.likeCount = tweet?.likeCount
        self.heading = tweet.map(Self.heading(for:))
        super.init(nibName: nil, bundle: nil)
        title = "Liked by"
    }

    /// The likes of a post known only by what a notification says about it.
    init(tweetID: String, likeCount: Int?, snippet: String?) {
        self.tweetID = tweetID
        self.likeCount = likeCount
        self.heading = likeCount.map { Self.heading(likeCount: $0, post: snippet.flatMap(Self.post(from:))) }
        super.init(nibName: nil, bundle: nil)
        title = "Liked by"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var listHeader: UserListHeader? { heading }

    override var emptyCopy: EmptyCopy {
        EmptyCopy(symbol: "heart", title: "No likes yet",
                  subtitle: "Nobody has liked this post, or X isn't sharing the list.")
    }

    override var logCategory: LogCategory { .timeline }

    override func fetchPage(cursor: String?) async throws -> Page {
        let page = try await AppEnvironment.shared.api.likers(tweetID: tweetID, cursor: cursor)
        let shown = (cursor == nil ? 0 : order.count) + page.users.count
        return Page(users: page.users, cursor: page.cursor, endNote: Self.endNote(shown: shown, of: likeCount))
    }

    /// "1,284 likes", and the post they are on in a line under it.
    static func heading(for tweet: Tweet) -> UserListHeader {
        let line = post(from: tweet.text).map { "@\(tweet.author.handle): \($0)" }
            ?? "A post by @\(tweet.author.handle)"
        return heading(likeCount: tweet.likeCount, post: line)
    }

    static func heading(likeCount count: Int, post: String?) -> UserListHeader {
        UserListHeader(
            symbol: "heart.fill", tint: DesignSystem.Color.like,
            title: count == 1 ? "1 like" : "\(count.formatted()) likes", subtitle: post)
    }

    /// `text` on one line, or nil when there is none.
    static func post(from text: String) -> String? {
        let words = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return words.isEmpty ? nil : words
    }

    /// Said under the last row when X lists fewer people than the post has
    /// likes, so a short list isn't taken for everyone.
    static func endNote(shown: Int, of total: Int?) -> String? {
        guard let total, total > shown, shown > 0 else { return nil }
        return "X lists \(shown.formatted()) of the \(total.formatted()) people who liked this."
    }
}
