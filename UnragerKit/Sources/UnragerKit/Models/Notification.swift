import CoreGraphics
import Foundation

public struct NotificationActor: Decodable, Sendable, Hashable {
    public let handle: String
    public let name: String
    public let restID: String
    public let verified: Bool
    public let avatarURL: String?

    enum CodingKeys: String, CodingKey {
        case handle, name
        case restID = "rest_id"
        case verified
        case avatarURL = "avatar_url"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        handle = try c.decode(String.self, forKey: .handle)
        name = try c.decode(String.self, forKey: .name)
        restID = try c.decode(String.self, forKey: .restID)
        verified = try c.decodeIfPresent(Bool.self, forKey: .verified) ?? false
        avatarURL = try c.decodeIfPresent(String.self, forKey: .avatarURL)
    }
}

/// A notification feed item. Named `XNotification` to avoid colliding with
/// `Foundation.Notification` in app targets that import both.
public struct XNotification: Decodable, Sendable, Hashable, Identifiable {
    public let id: String
    public let type: String
    public let actors: [NotificationActor]
    /// How many additional actors X groups beyond `actors` ("and N others").
    /// Absent on servers that predate the field — treat as zero.
    public let othersCount: Int?
    /// X's fully rendered notification text (e.g. "Your poll has ended").
    /// The fallback copy for actor-less types; absent on older servers.
    public let message: String?
    public let targetTweetID: String?
    public let targetTweetSnippet: String?
    public let targetTweetLikeCount: Int?
    public let targetMedia: [Media]
    public let timestamp: Date

    enum CodingKeys: String, CodingKey {
        case id, type, actors, message
        case othersCount = "others_count"
        case targetTweetID = "target_tweet_id"
        case targetTweetSnippet = "target_tweet_snippet"
        case targetTweetLikeCount = "target_tweet_like_count"
        case targetMedia = "target_media"
        case timestamp
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decode(String.self, forKey: .type)
        actors = try c.decodeIfPresent([NotificationActor].self, forKey: .actors) ?? []
        othersCount = try c.decodeIfPresent(Int.self, forKey: .othersCount)
        message = try c.decodeIfPresent(String.self, forKey: .message)
        targetTweetID = try c.decodeIfPresent(String.self, forKey: .targetTweetID)
        targetTweetSnippet = try c.decodeIfPresent(String.self, forKey: .targetTweetSnippet)
        targetTweetLikeCount = try c.decodeIfPresent(Int.self, forKey: .targetTweetLikeCount)
        targetMedia = try c.decodeIfPresent([Media].self, forKey: .targetMedia) ?? []
        timestamp = try c.decode(Date.self, forKey: .timestamp)
    }

    /// A raster thumbnail for the target tweet's first photo or video poster,
    /// or nil when the notification isn't about media (or only carries
    /// non-image kinds like polls/cards).
    public var thumbnailURL: URL? {
        targetMedia.first(where: { $0.kind == .photo || $0.isVideo }).flatMap { URL(string: $0.url) }
    }
}

public struct NotificationsPage: Decodable, Sendable {
    public let notifications: [XNotification]
    public let cursor: String?
}
