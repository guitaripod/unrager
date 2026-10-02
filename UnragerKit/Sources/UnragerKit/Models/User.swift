import Foundation

public struct User: Codable, Sendable, Hashable, Identifiable {
    public let restID: String
    public let handle: String
    public let name: String
    public let verified: Bool
    public let followers: Int
    public let following: Int
    public let avatarURL: String?
    /// The profile's header image, only present on profile payloads.
    public let bannerURL: String?
    /// The profile's bio. This and the fields below are only filled on
    /// profile payloads, and absent from older servers.
    public let bio: String?
    public let location: String?
    public let website: String?
    public let joinedAt: Date?
    public let isProtected: Bool
    /// Whether the viewer mutes or blocks this account; nil when the server
    /// doesn't know.
    public let isMuting: Bool?
    public let isBlocking: Bool?

    public var id: String { restID }

    enum CodingKeys: String, CodingKey {
        case restID = "rest_id"
        case handle
        case name
        case verified
        case followers
        case following
        case avatarURL = "avatar_url"
        case bannerURL = "banner_url"
        case bio = "description"
        case location
        case website
        case joinedAt = "joined_at"
        case isProtected = "protected"
        case isMuting = "muting"
        case isBlocking = "blocking"
    }

    public init(restID: String, handle: String, name: String, verified: Bool,
                followers: Int, following: Int, avatarURL: String?, bannerURL: String? = nil,
                bio: String? = nil, location: String? = nil, website: String? = nil,
                joinedAt: Date? = nil, isProtected: Bool = false,
                isMuting: Bool? = nil, isBlocking: Bool? = nil) {
        self.restID = restID
        self.handle = handle
        self.name = name
        self.verified = verified
        self.followers = followers
        self.following = following
        self.avatarURL = avatarURL
        self.bannerURL = bannerURL
        self.bio = bio
        self.location = location
        self.website = website
        self.joinedAt = joinedAt
        self.isProtected = isProtected
        self.isMuting = isMuting
        self.isBlocking = isBlocking
    }

    /// The profile extras decode leniently: a malformed bio or join date
    /// reads as absent rather than failing the user, and with it the page.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        restID = try c.decode(String.self, forKey: .restID)
        handle = try c.decode(String.self, forKey: .handle)
        name = try c.decode(String.self, forKey: .name)
        verified = try c.decode(Bool.self, forKey: .verified)
        followers = try c.decode(Int.self, forKey: .followers)
        following = try c.decode(Int.self, forKey: .following)
        avatarURL = try c.decodeIfPresent(String.self, forKey: .avatarURL)
        bannerURL = try c.decodeIfPresent(String.self, forKey: .bannerURL)
        bio = try? c.decodeIfPresent(String.self, forKey: .bio)
        location = try? c.decodeIfPresent(String.self, forKey: .location)
        website = try? c.decodeIfPresent(String.self, forKey: .website)
        joinedAt = try? c.decodeIfPresent(Date.self, forKey: .joinedAt)
        isProtected = (try? c.decodeIfPresent(Bool.self, forKey: .isProtected)) ?? false
        isMuting = try? c.decodeIfPresent(Bool.self, forKey: .isMuting)
        isBlocking = try? c.decodeIfPresent(Bool.self, forKey: .isBlocking)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(restID, forKey: .restID)
        try c.encode(handle, forKey: .handle)
        try c.encode(name, forKey: .name)
        try c.encode(verified, forKey: .verified)
        try c.encode(followers, forKey: .followers)
        try c.encode(following, forKey: .following)
        try c.encodeIfPresent(avatarURL, forKey: .avatarURL)
        try c.encodeIfPresent(bannerURL, forKey: .bannerURL)
        try c.encodeIfPresent(bio, forKey: .bio)
        try c.encodeIfPresent(location, forKey: .location)
        try c.encodeIfPresent(website, forKey: .website)
        try c.encodeIfPresent(joinedAt, forKey: .joinedAt)
        if isProtected { try c.encode(isProtected, forKey: .isProtected) }
        try c.encodeIfPresent(isMuting, forKey: .isMuting)
        try c.encodeIfPresent(isBlocking, forKey: .isBlocking)
    }
}
