import Foundation

/// Lifecycle of an about-account lookup on `GET /api/about/{rest_id}`.
/// `resolved` and `none` are final and cacheable for the session; `deferred`
/// means the server was rate-limited (or hit a transient error) upstream and
/// clients must retry later instead of caching.
public enum AboutStatus: String, Codable, Sendable {
    case resolved
    case none
    case deferred
}

/// X's "about this account" profile for a user, carried by a `resolved`
/// `AboutView`. Mirrors the server's `AboutProfile` JSON.
public struct AboutProfile: Codable, Sendable, Hashable {
    public let restID: String
    public let handle: String
    public let name: String
    public let accountBasedIn: String?
    public let locationAccurate: Bool?
    public let source: String?
    public let usernameChanges: Int?
    public let affiliateUsername: String?
    public let createdAt: Date?
    public let isBlueVerified: Bool
    public let verified: Bool
    public let verifiedSince: Date?

    enum CodingKeys: String, CodingKey {
        case restID = "rest_id"
        case handle
        case name
        case accountBasedIn = "account_based_in"
        case locationAccurate = "location_accurate"
        case source
        case usernameChanges = "username_changes"
        case affiliateUsername = "affiliate_username"
        case createdAt = "created_at"
        case isBlueVerified = "is_blue_verified"
        case verified
        case verifiedSince = "verified_since"
    }

    public init(restID: String, handle: String, name: String,
                accountBasedIn: String? = nil, locationAccurate: Bool? = nil,
                source: String? = nil, usernameChanges: Int? = nil,
                affiliateUsername: String? = nil, createdAt: Date? = nil,
                isBlueVerified: Bool = false, verified: Bool = false,
                verifiedSince: Date? = nil) {
        self.restID = restID
        self.handle = handle
        self.name = name
        self.accountBasedIn = accountBasedIn
        self.locationAccurate = locationAccurate
        self.source = source
        self.usernameChanges = usernameChanges
        self.affiliateUsername = affiliateUsername
        self.createdAt = createdAt
        self.isBlueVerified = isBlueVerified
        self.verified = verified
        self.verifiedSince = verifiedSince
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        restID = try c.decode(String.self, forKey: .restID)
        handle = try c.decode(String.self, forKey: .handle)
        name = try c.decode(String.self, forKey: .name)
        accountBasedIn = try c.decodeIfPresent(String.self, forKey: .accountBasedIn)
        locationAccurate = try c.decodeIfPresent(Bool.self, forKey: .locationAccurate)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        usernameChanges = try c.decodeIfPresent(Int.self, forKey: .usernameChanges)
        affiliateUsername = try c.decodeIfPresent(String.self, forKey: .affiliateUsername)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        isBlueVerified = try c.decodeIfPresent(Bool.self, forKey: .isBlueVerified) ?? false
        verified = try c.decodeIfPresent(Bool.self, forKey: .verified) ?? false
        verifiedSince = try c.decodeIfPresent(Date.self, forKey: .verifiedSince)
    }
}

/// The response of `GET /api/about/{rest_id}?screen_name={handle}`. `alpha2`
/// and `flag` are derived server-side from `profile.accountBasedIn`, so a
/// `resolved` view whose country is unset still carries nil for both.
/// `profile`, `alpha2` and `flag` decode tolerantly whether the server omits
/// them or serializes explicit nulls.
public struct AboutView: Decodable, Sendable, Equatable {
    public let status: AboutStatus
    public let profile: AboutProfile?
    public let alpha2: String?
    public let flag: String?

    enum CodingKeys: String, CodingKey { case status, profile, alpha2, flag }

    public init(status: AboutStatus, profile: AboutProfile? = nil,
                alpha2: String? = nil, flag: String? = nil) {
        self.status = status
        self.profile = profile
        self.alpha2 = alpha2
        self.flag = flag
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decode(AboutStatus.self, forKey: .status)
        profile = try c.decodeIfPresent(AboutProfile.self, forKey: .profile)
        alpha2 = try c.decodeIfPresent(String.self, forKey: .alpha2)
        flag = try c.decodeIfPresent(String.self, forKey: .flag)
    }
}
