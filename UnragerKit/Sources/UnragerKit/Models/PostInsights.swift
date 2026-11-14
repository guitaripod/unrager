import Foundation

/// One part of `GET /api/tweets/{id}/insights`, as `?parts=` names it and as
/// the answer lists what it held back or failed on.
public enum InsightPart: String, Codable, Sendable, Hashable, CaseIterable {
    case analytics, likers, reposters
}

/// X's analytics for one of the signed-in account's own posts and the newest
/// people who liked and reposted it, from `GET /api/tweets/{id}/insights`.
/// The server holds a part back (`deferred`) rather than spend the last of
/// X's budget on it, and says when to ask again.
public struct PostInsights: Decodable, Sendable {
    public let analytics: PostAnalytics?
    public let likers: UserListPage?
    public let reposters: UserListPage?
    public let deferred: [InsightPart]
    public let failed: [InsightPart]
    public let retryAfterSecs: Int?

    enum CodingKeys: String, CodingKey {
        case analytics, likers, reposters, deferred, failed
        case retryAfterSecs = "retry_after_secs"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        analytics = try c.decodeIfPresent(PostAnalytics.self, forKey: .analytics)
        likers = try c.decodeIfPresent(UserListPage.self, forKey: .likers)
        reposters = try c.decodeIfPresent(UserListPage.self, forKey: .reposters)
        deferred = Self.parts(try c.decodeIfPresent([String].self, forKey: .deferred))
        failed = Self.parts(try c.decodeIfPresent([String].self, forKey: .failed))
        retryAfterSecs = try c.decodeIfPresent(Int.self, forKey: .retryAfterSecs)
    }

    /// Parts a newer server may name that this client doesn't know are
    /// skipped rather than failing the whole answer.
    private static func parts(_ names: [String]?) -> [InsightPart] {
        (names ?? []).compactMap(InsightPart.init(rawValue:))
    }
}
