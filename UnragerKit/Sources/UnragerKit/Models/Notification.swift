import Foundation

public struct NotificationActor: Decodable, Sendable, Hashable {
    public let handle: String
    public let name: String
    public let restID: String
    public let verified: Bool

    enum CodingKeys: String, CodingKey {
        case handle, name
        case restID = "rest_id"
        case verified
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        handle = try c.decode(String.self, forKey: .handle)
        name = try c.decode(String.self, forKey: .name)
        restID = try c.decode(String.self, forKey: .restID)
        verified = try c.decodeIfPresent(Bool.self, forKey: .verified) ?? false
    }
}

/// A notification feed item. Named `XNotification` to avoid colliding with
/// `Foundation.Notification` in app targets that import both.
public struct XNotification: Decodable, Sendable, Hashable, Identifiable {
    public let id: String
    public let type: String
    public let actors: [NotificationActor]
    public let targetTweetID: String?
    public let targetTweetSnippet: String?
    public let targetTweetLikeCount: Int?
    public let timestamp: Date

    enum CodingKeys: String, CodingKey {
        case id, type, actors
        case targetTweetID = "target_tweet_id"
        case targetTweetSnippet = "target_tweet_snippet"
        case targetTweetLikeCount = "target_tweet_like_count"
        case timestamp
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decode(String.self, forKey: .type)
        actors = try c.decodeIfPresent([NotificationActor].self, forKey: .actors) ?? []
        targetTweetID = try c.decodeIfPresent(String.self, forKey: .targetTweetID)
        targetTweetSnippet = try c.decodeIfPresent(String.self, forKey: .targetTweetSnippet)
        targetTweetLikeCount = try c.decodeIfPresent(Int.self, forKey: .targetTweetLikeCount)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
    }
}

public struct NotificationsPage: Decodable, Sendable {
    public let notifications: [XNotification]
    public let cursor: String?
}
