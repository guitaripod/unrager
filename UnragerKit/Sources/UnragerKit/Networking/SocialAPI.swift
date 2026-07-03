import Foundation

/// Typed client for the social endpoints — follow/unfollow, follower and
/// following lists, and the profile payload with the viewer's follow
/// relationship. Standalone (not an `APIClient` method) so it ships without
/// touching the shared client; mirrors `NotificationSeenAPI`'s pattern.
public final class SocialAPI: Sendable {
    private let transport: HTTPTransport
    private let baseURL: @Sendable () -> URL

    public init(transport: HTTPTransport = URLSessionTransport(),
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

    /// `GET /api/users/{id}/followers` — one page of the followers list.
    public func followers(userID: String, cursor: String? = nil, count: Int? = nil) async throws -> UserListPage {
        try await userList(kind: "followers", userID: userID, cursor: cursor, count: count)
    }

    /// `GET /api/users/{id}/following` — one page of the following list.
    public func following(userID: String, cursor: String? = nil, count: Int? = nil) async throws -> UserListPage {
        try await userList(kind: "following", userID: userID, cursor: cursor, count: count)
    }

    /// `GET /api/profile/{handle}` decoded with the additive `followed_by_me`
    /// flag alongside the shared `User`.
    public func profile(handle: String) async throws -> ProfileRelationshipView {
        try await perform(method: .get, path: "api/profile/\(segment(handle))")
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
        let request = HTTPRequest(method: method, url: url(path, query: query))
        let response = try await transport.send(request)
        guard response.isSuccess else {
            let body = try? UnragerJSON.decoder.decode(ServerError.self, from: response.body)
            throw APIError.from(status: response.status, body: body)
        }
        return try UnragerJSON.decode(T.self, from: response.body)
    }
}
