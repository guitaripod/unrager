import Foundation

/// A tweet. Modeled as a `final class` because `quotedTweet` makes the type
/// recursive; all stored properties are immutable so it remains `Sendable`.
/// Identity and equality are by `restID` — the diffable snapshot stores ids,
/// and content changes are surfaced via explicit `reconfigureItems`.
public final class Tweet: Decodable, Sendable, Identifiable, Hashable {
    public let restID: String
    public let author: User
    public let createdAt: Date
    public let text: String
    public let replyCount: Int
    public let retweetCount: Int
    public let likeCount: Int
    public let quoteCount: Int
    public let viewCount: Int?
    public let bookmarkCount: Int
    public let favorited: Bool
    public let retweeted: Bool
    public let bookmarked: Bool
    public let lang: String?
    public let inReplyToTweetID: String?
    public let quotedTweet: Tweet?
    public let media: [Media]
    public let url: String
    public let urls: [TweetURL]

    public var id: String { restID }

    enum CodingKeys: String, CodingKey {
        case restID = "rest_id"
        case author
        case createdAt = "created_at"
        case text
        case replyCount = "reply_count"
        case retweetCount = "retweet_count"
        case likeCount = "like_count"
        case quoteCount = "quote_count"
        case viewCount = "view_count"
        case bookmarkCount = "bookmark_count"
        case favorited
        case retweeted
        case bookmarked
        case lang
        case inReplyToTweetID = "in_reply_to_tweet_id"
        case quotedTweet = "quoted_tweet"
        case media
        case url
        case urls
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        restID = try c.decode(String.self, forKey: .restID)
        author = try c.decode(User.self, forKey: .author)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        text = try c.decode(String.self, forKey: .text)
        replyCount = try c.decode(Int.self, forKey: .replyCount)
        retweetCount = try c.decode(Int.self, forKey: .retweetCount)
        likeCount = try c.decode(Int.self, forKey: .likeCount)
        quoteCount = try c.decode(Int.self, forKey: .quoteCount)
        viewCount = try c.decodeIfPresent(Int.self, forKey: .viewCount)
        bookmarkCount = try c.decodeIfPresent(Int.self, forKey: .bookmarkCount) ?? 0
        favorited = try c.decodeIfPresent(Bool.self, forKey: .favorited) ?? false
        retweeted = try c.decodeIfPresent(Bool.self, forKey: .retweeted) ?? false
        bookmarked = try c.decodeIfPresent(Bool.self, forKey: .bookmarked) ?? false
        lang = try c.decodeIfPresent(String.self, forKey: .lang)
        inReplyToTweetID = try c.decodeIfPresent(String.self, forKey: .inReplyToTweetID)
        quotedTweet = try c.decodeIfPresent(Tweet.self, forKey: .quotedTweet)
        media = try c.decodeIfPresent([Media].self, forKey: .media) ?? []
        url = try c.decode(String.self, forKey: .url)
        urls = try c.decodeIfPresent([TweetURL].self, forKey: .urls) ?? []
    }

    public static func == (lhs: Tweet, rhs: Tweet) -> Bool { lhs.restID == rhs.restID }
    public func hash(into hasher: inout Hasher) { hasher.combine(restID) }

    /// True when a re-fetched copy carries display-affecting changes, so a
    /// visible cell should be reconfigured rather than left stale.
    public func displayDiffers(from other: Tweet) -> Bool {
        likeCount != other.likeCount
            || retweetCount != other.retweetCount
            || replyCount != other.replyCount
            || quoteCount != other.quoteCount
            || bookmarkCount != other.bookmarkCount
            || favorited != other.favorited
            || retweeted != other.retweeted
            || bookmarked != other.bookmarked
    }
}
