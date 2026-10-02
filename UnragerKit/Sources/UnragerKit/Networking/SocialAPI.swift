import Foundation

/// Typed client for the social endpoints — follow/unfollow, follower and
/// following lists, and the profile payload with the viewer's follow
/// relationship. Standalone (not an `APIClient` method) so it ships without
/// touching the shared client; mirrors `NotificationSeenAPI`'s pattern.
public final class SocialAPI: Sendable {
    private let transport: HTTPTransport
    private let baseURL: @Sendable () -> URL

    public init(transport: HTTPTransport = URLSessionTransport.shared,
                baseURL: @escaping @Sendable () -> URL) {
        self.transport = transport
        self.baseURL = baseURL
    }

    /// `POST /api/users/{id}/follow`. `userID` may be a numeric rest_id or a
    /// handle — the server resolves either.
    public func follow(userID: String) async throws -> FollowResult {
        try await perform(method: .post, path: "api/users/\(segment(userID))/follow")
    }

    /// `DELETE /api/users/{id}/follow`.
    public func unfollow(userID: String) async throws -> FollowResult {
        try await perform(method: .delete, path: "api/users/\(segment(userID))/follow")
    }

    /// `POST /api/users/{id}/mute` to mute, `DELETE` to unmute.
    @discardableResult
    public func setMuted(userID: String, muted: Bool) async throws -> MuteResult {
        try await perform(method: muted ? .post : .delete, path: "api/users/\(segment(userID))/mute")
    }

    /// `POST /api/users/{id}/block` to block, `DELETE` to unblock.
    @discardableResult
    public func setBlocked(userID: String, blocked: Bool) async throws -> BlockResult {
        try await perform(method: blocked ? .post : .delete, path: "api/users/\(segment(userID))/block")
    }

    /// `GET /api/users/{id}/followers` — one page of the followers list.
    public func followers(userID: String, cursor: String? = nil, count: Int? = nil) async throws -> UserListPage {
        try await userList(kind: "followers", userID: userID, cursor: cursor, count: count)
    }

    /// `GET /api/users/{id}/following` — one page of the following list.
    public func following(userID: String, cursor: String? = nil, count: Int? = nil) async throws -> UserListPage {
        try await userList(kind: "following", userID: userID, cursor: cursor, count: count)
    }

    /// `GET /api/sources/search/people` — one page of accounts matching `query`
    /// (the People tab of X search).
    public func searchPeople(query: String, cursor: String? = nil, count: Int? = nil) async throws -> UserListPage {
        var items = [URLQueryItem(name: "q", value: query)]
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        if let count { items.append(URLQueryItem(name: "count", value: String(count))) }
        return try await perform(method: .get, path: "api/sources/search/people", query: items)
    }

    /// `GET /api/profile/{handle}` decoded with the additive `followed_by_me`
    /// flag alongside the shared `User`. `includeTweets: false` asks for the
    /// account alone (`?tweets=false`: no recent posts, pinned post or cursor),
    /// for a header that doesn't need the timeline.
    public func profile(handle: String, includeTweets: Bool = true) async throws -> ProfileRelationshipView {
        let query = includeTweets ? [] : [URLQueryItem(name: "tweets", value: "false")]
        return try await perform(method: .get, path: "api/profile/\(segment(handle))", query: query)
    }

    private func userList(kind: String, userID: String, cursor: String?, count: Int?) async throws -> UserListPage {
        var query: [URLQueryItem] = []
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        if let count { query.append(URLQueryItem(name: "count", value: String(count))) }
        return try await perform(method: .get, path: "api/users/\(segment(userID))/\(kind)", query: query)
    }

    private func segment(_ raw: String) -> String {
        raw.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? raw
    }

    /// Builds the request URL, re-encoding literal `+` in query values as
    /// `%2B` — same form-urlencoded hazard the shared client guards against
    /// (cursors can carry `+`).
    private func url(_ path: String, query: [URLQueryItem]) -> URL {
        let base = baseURL().appendingPathComponent(path)
        guard !query.isEmpty,
              var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return base
        }
        comps.queryItems = query
        comps.percentEncodedQuery = comps.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return comps.url ?? base
    }

    private func perform<T: Decodable>(method: HTTPMethod, path: String,
                                       query: [URLQueryItem] = []) async throws -> T {
        try await RequestPlumbing.perform(HTTPRequest(method: method, url: url(path, query: query)), over: transport)
    }
}
