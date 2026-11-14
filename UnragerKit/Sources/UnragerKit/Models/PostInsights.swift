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
    /// Parts the server answered from its cache while it asks X for newer
    /// ones, or is still asking X for: ask again in a moment.
    public let refreshing: [InsightPart]
    /// When X answered each part given (unix milliseconds).
    public let fetchedAt: [InsightPart: Int64]

    enum CodingKeys: String, CodingKey {
        case analytics, likers, reposters, deferred, failed, refreshing
        case retryAfterSecs = "retry_after_secs"
        case fetchedAt = "fetched_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        analytics = try c.decodeIfPresent(PostAnalytics.self, forKey: .analytics)
        likers = try c.decodeIfPresent(UserListPage.self, forKey: .likers)
        reposters = try c.decodeIfPresent(UserListPage.self, forKey: .reposters)
        deferred = Self.parts(try c.decodeIfPresent([String].self, forKey: .deferred))
        failed = Self.parts(try c.decodeIfPresent([String].self, forKey: .failed))
        retryAfterSecs = try c.decodeIfPresent(Int.self, forKey: .retryAfterSecs)
        refreshing = Self.parts(try c.decodeIfPresent([String].self, forKey: .refreshing))
        let times = try c.decodeIfPresent([String: Int64].self, forKey: .fetchedAt) ?? [:]
        fetchedAt = Dictionary(uniqueKeysWithValues: times.compactMap { key, value in
            InsightPart(rawValue: key).map { ($0, value) }
        })
    }

    /// Parts a newer server may name that this client doesn't know are
    /// skipped rather than failing the whole answer.
    private static func parts(_ names: [String]?) -> [InsightPart] {
        (names ?? []).compactMap(InsightPart.init(rawValue:))
    }
}

/// `POST /api/insights`: glances at several posts at once, by post id. The
/// server never waits on X for these: what it lacks comes back in
/// `refreshing`. A post whose every part failed is in `errors`, with the
/// error's kind.
public struct InsightsBatch: Decodable, Sendable {
    public let posts: [String: PostInsights]
    public let errors: [String: String]

    enum CodingKeys: String, CodingKey { case posts, errors }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        posts = try c.decodeIfPresent([String: PostInsights].self, forKey: .posts) ?? [:]
        errors = try c.decodeIfPresent([String: String].self, forKey: .errors) ?? [:]
    }
}

/// One post a batch glance asks about, with the counts the client sees, so
/// likers or reposters the server cached at a lower count are fetched again.
public struct InsightsBatchPost: Encodable, Sendable, Hashable {
    public let id: String
    public let likes: Int?
    public let reposts: Int?

    public init(id: String, likes: Int? = nil, reposts: Int? = nil) {
        self.id = id
        self.likes = likes
        self.reposts = reposts
    }
}
