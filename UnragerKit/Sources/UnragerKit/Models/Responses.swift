import Foundation

public struct TimelinePage: Decodable, Sendable {
    public let tweets: [Tweet]
    public let cursor: String?
}

/// Freshness of one materialized Home variant from `GET /api/feed/status`.
/// `ageSecs == -1` means that variant has never been ingested (cold buffer).
public struct FeedStatus: Decodable, Sendable {
    public let variant: String
    public let lastIngestAt: Int
    public let lastIngestCount: Int
    public let ageSecs: Int

    enum CodingKeys: String, CodingKey {
        case variant
        case lastIngestAt = "last_ingest_at"
        case lastIngestCount = "last_ingest_count"
        case ageSecs = "age_secs"
    }
}

public struct FeedStatusResponse: Decodable, Sendable {
    public let feeds: [FeedStatus]
}

public struct ThreadView: Decodable, Sendable {
    public let focal: Tweet
    public let ancestors: [Tweet]
    public let replies: [Tweet]
    public let cursor: String?

    enum CodingKeys: String, CodingKey {
        case focal, ancestors, replies, cursor
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        focal = try c.decode(Tweet.self, forKey: .focal)
        ancestors = try c.decodeIfPresent([Tweet].self, forKey: .ancestors) ?? []
        replies = try c.decodeIfPresent([Tweet].self, forKey: .replies) ?? []
        cursor = try c.decodeIfPresent(String.self, forKey: .cursor)
    }
}

public struct ProfileView: Decodable, Sendable {
    public let user: User
    public let pinned: Tweet?
    public let recent: [Tweet]
    public let cursor: String?

    enum CodingKeys: String, CodingKey {
        case user, pinned, recent, cursor
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        user = try c.decode(User.self, forKey: .user)
        pinned = try c.decodeIfPresent(Tweet.self, forKey: .pinned)
        recent = try c.decodeIfPresent([Tweet].self, forKey: .recent) ?? []
        cursor = try c.decodeIfPresent(String.self, forKey: .cursor)
    }
}

public struct LikersPage: Decodable, Sendable {
    public let users: [User]
    public let cursor: String?
}

public struct Whoami: Decodable, Sendable, Hashable {
    public let handle: String
    public let restID: String
    public let name: String

    enum CodingKeys: String, CodingKey {
        case handle
        case restID = "rest_id"
        case name
    }
}

public struct ComposeResult: Decodable, Sendable {
    public let id: String
    public let url: String
    public let idempotent: Bool

    enum CodingKeys: String, CodingKey { case id, url, idempotent }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        url = try c.decode(String.self, forKey: .url)
        idempotent = try c.decodeIfPresent(Bool.self, forKey: .idempotent) ?? false
    }
}

public struct EngageResult: Decodable, Sendable {
    public let ok: Bool
    public let idempotent: Bool?
}

public struct MarkSeenRequest: Encodable, Sendable {
    public let ids: [String]
    public init(ids: [String]) { self.ids = ids }
}

public struct MarkSeenResult: Decodable, Sendable {
    public let marked: Int
}

public struct SeenCheck: Decodable, Sendable {
    public let id: String
    public let seen: Bool
}

/// The five `ask` presets the SSE endpoint accepts.
public enum AskPreset: String, Sendable, CaseIterable {
    case explain
    case summary
    case counter
    case eli5
    case entities

    public var title: String {
        switch self {
        case .explain: return "Explain"
        case .summary: return "Summary"
        case .counter: return "Counterpoint"
        case .eli5: return "ELI5"
        case .entities: return "Entities"
        }
    }
}

public enum FilterVerdict: String, Decodable, Sendable {
    case hide
    case keep
}

/// One `data:` payload on `GET /api/sse/filter`.
public struct FilterVerdictEvent: Decodable, Sendable {
    public let id: String
    public let verdict: FilterVerdict
}

/// One `data:` payload on the ask/brief/translate token streams.
public struct TokenEvent: Decodable, Sendable {
    public let token: String
    public let done: Bool

    enum CodingKeys: String, CodingKey { case token, done }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        token = try c.decodeIfPresent(String.self, forKey: .token) ?? ""
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
    }
}
