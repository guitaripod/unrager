import Foundation

/// `POST`/`DELETE /api/users/{id}/follow`.
public struct FollowResult: Decodable, Sendable {
    public let ok: Bool
    public let following: Bool
}

/// One page of `GET /api/users/{id}/followers` or `/following`.
public struct UserListPage: Decodable, Sendable {
    public let users: [User]
    public let cursor: String?

    enum CodingKeys: String, CodingKey { case users, cursor }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        users = try c.decodeIfPresent([User].self, forKey: .users) ?? []
        cursor = try c.decodeIfPresent(String.self, forKey: .cursor)
    }
}

/// The profile payload with the viewer's follow relationship
/// (`GET /api/profile/{handle}`): the shared `User` plus the additive
/// `followed_by_me` flag the shared model predates. `followedByMe` is nil on
/// servers that don't send it, so callers can hide the follow affordance
/// rather than guess.
public struct ProfileRelationshipView: Decodable, Sendable {
    public let user: User
    public let followedByMe: Bool?
    public let pinned: Tweet?
    public let recent: [Tweet]
    public let cursor: String?

    enum CodingKeys: String, CodingKey {
        case user, pinned, recent, cursor
    }

    private struct Relationship: Decodable {
        let followedByMe: Bool?

        enum CodingKeys: String, CodingKey {
            case followedByMe = "followed_by_me"
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        user = try c.decode(User.self, forKey: .user)
        followedByMe = try c.decodeIfPresent(Relationship.self, forKey: .user)?.followedByMe
        pinned = try c.decodeIfPresent(Tweet.self, forKey: .pinned)
        recent = try c.decodeIfPresent([Tweet].self, forKey: .recent) ?? []
        cursor = try c.decodeIfPresent(String.self, forKey: .cursor)
    }
}
