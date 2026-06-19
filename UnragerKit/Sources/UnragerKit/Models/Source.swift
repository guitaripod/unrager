import Foundation

public enum FeedMode: String, Codable, Sendable, CaseIterable {
    case all
    case originals
}

public enum SourceProduct: String, Codable, Sendable, CaseIterable {
    case top
    case latest
    case people
    case photos
    case videos

    /// The capitalized form the search endpoint's `product` param expects.
    public var apiValue: String {
        switch self {
        case .top: return "Top"
        case .latest: return "Latest"
        case .people: return "People"
        case .photos: return "Photos"
        case .videos: return "Videos"
        }
    }
}

/// A selectable feed. Serialized internally-tagged (`{"type": "...", ...}`),
/// snake_case — matches the server's `SourceKind`.
public enum SourceKind: Codable, Sendable, Hashable {
    case home(following: Bool)
    case user(handle: String)
    case search(query: String, product: SourceProduct)
    case mentions(target: String?)
    case bookmarks(query: String)

    private enum CodingKeys: String, CodingKey {
        case type, following, handle, query, product, target
    }

    private enum Kind: String { case home, user, search, mentions, bookmarks }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch Kind(rawValue: type) {
        case .home:
            self = .home(following: try c.decodeIfPresent(Bool.self, forKey: .following) ?? false)
        case .user:
            self = .user(handle: try c.decode(String.self, forKey: .handle))
        case .search:
            let product = (try c.decodeIfPresent(SourceProduct.self, forKey: .product)) ?? .latest
            self = .search(query: try c.decode(String.self, forKey: .query), product: product)
        case .mentions:
            self = .mentions(target: try c.decodeIfPresent(String.self, forKey: .target))
        case .bookmarks:
            self = .bookmarks(query: try c.decodeIfPresent(String.self, forKey: .query) ?? "")
        case .none:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "Unknown SourceKind: \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .home(let following):
            try c.encode(Kind.home.rawValue, forKey: .type)
            try c.encode(following, forKey: .following)
        case .user(let handle):
            try c.encode(Kind.user.rawValue, forKey: .type)
            try c.encode(handle, forKey: .handle)
        case .search(let query, let product):
            try c.encode(Kind.search.rawValue, forKey: .type)
            try c.encode(query, forKey: .query)
            try c.encode(product, forKey: .product)
        case .mentions(let target):
            try c.encode(Kind.mentions.rawValue, forKey: .type)
            try c.encodeIfPresent(target, forKey: .target)
        case .bookmarks(let query):
            try c.encode(Kind.bookmarks.rawValue, forKey: .type)
            try c.encode(query, forKey: .query)
        }
    }
}

public struct SessionState: Decodable, Sendable {
    public let currentSource: SourceKind?
    public let feedMode: FeedMode
    public let filterEnabled: Bool
    public let theme: String?

    enum CodingKeys: String, CodingKey {
        case currentSource = "current_source"
        case feedMode = "feed_mode"
        case filterEnabled = "filter_enabled"
        case theme
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        currentSource = try c.decodeIfPresent(SourceKind.self, forKey: .currentSource)
        feedMode = try c.decodeIfPresent(FeedMode.self, forKey: .feedMode) ?? .all
        filterEnabled = try c.decodeIfPresent(Bool.self, forKey: .filterEnabled) ?? false
        theme = try c.decodeIfPresent(String.self, forKey: .theme)
    }
}

/// Partial update for `PATCH /api/session`; only set fields are sent.
public struct SessionPatch: Encodable, Sendable {
    public var currentSource: SourceKind?
    public var feedMode: FeedMode?
    public var filterEnabled: Bool?
    public var theme: String?

    enum CodingKeys: String, CodingKey {
        case currentSource = "current_source"
        case feedMode = "feed_mode"
        case filterEnabled = "filter_enabled"
        case theme
    }

    public init(currentSource: SourceKind? = nil, feedMode: FeedMode? = nil,
                filterEnabled: Bool? = nil, theme: String? = nil) {
        self.currentSource = currentSource
        self.feedMode = feedMode
        self.filterEnabled = filterEnabled
        self.theme = theme
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(currentSource, forKey: .currentSource)
        try c.encodeIfPresent(feedMode, forKey: .feedMode)
        try c.encodeIfPresent(filterEnabled, forKey: .filterEnabled)
        try c.encodeIfPresent(theme, forKey: .theme)
    }
}
