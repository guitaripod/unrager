import Foundation

public struct User: Codable, Sendable, Hashable, Identifiable {
    public let restID: String
    public let handle: String
    public let name: String
    public let verified: Bool
    public let followers: Int
    public let following: Int
    public let avatarURL: String?

    public var id: String { restID }

    enum CodingKeys: String, CodingKey {
        case restID = "rest_id"
        case handle
        case name
        case verified
        case followers
        case following
        case avatarURL = "avatar_url"
    }

    public init(restID: String, handle: String, name: String, verified: Bool,
                followers: Int, following: Int, avatarURL: String?) {
        self.restID = restID
        self.handle = handle
        self.name = name
        self.verified = verified
        self.followers = followers
        self.following = following
        self.avatarURL = avatarURL
    }
}
