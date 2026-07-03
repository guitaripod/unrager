import Foundation

/// Typed client for the engagement endpoints — `POST`/`DELETE
/// /api/tweets/{id}/retweet` and `/bookmark` (like-shaped `{"ok":true}`
/// responses, idempotent on duplicates) — plus the full Bookmarks timeline
/// (`GET /api/sources/bookmarks` with no query), which the keyword-search
/// variant on `APIClient` can't reach because it always sends `q`.
/// Standalone rather than `APIClient` methods so the new surface ships
/// without touching the shared client — the `NotificationSeenAPI` pattern.
public final class EngageAPI: Sendable {
    private let transport: HTTPTransport
    private let baseURL: @Sendable () -> URL

    public init(transport: HTTPTransport = URLSessionTransport(),
                baseURL: @escaping @Sendable () -> URL) {
        self.transport = transport
        self.baseURL = baseURL
    }

    @discardableResult
    public func retweet(tweetID: String) async throws -> EngageResult {
        try await engage(.post, tweetID: tweetID, action: "retweet")
    }

    @discardableResult
    public func unretweet(tweetID: String) async throws -> EngageResult {
        try await engage(.delete, tweetID: tweetID, action: "retweet")
    }

    @discardableResult
    public func bookmark(tweetID: String) async throws -> EngageResult {
        try await engage(.post, tweetID: tweetID, action: "bookmark")
    }

    @discardableResult
    public func unbookmark(tweetID: String) async throws -> EngageResult {
        try await engage(.delete, tweetID: tweetID, action: "bookmark")
    }

    /// One page of the viewer's full Bookmarks timeline (newest first).
    public func bookmarksTimeline(cursor: String?, count: Int? = nil) async throws -> TimelinePage {
        var query: [URLQueryItem] = []
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        if let count { query.append(URLQueryItem(name: "count", value: String(count))) }
        return try await perform(HTTPRequest(method: .get, url: url("api/sources/bookmarks", query: query)))
    }

    private func engage(_ method: HTTPMethod, tweetID: String, action: String) async throws -> EngageResult {
        let path = "api/tweets/\(RequestPlumbing.pathSegment(tweetID))/\(action)"
        return try await perform(HTTPRequest(method: method, url: url(path)))
    }

    private func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        RequestPlumbing.url(base: baseURL(), path: path, query: query)
    }

    private func perform<T: Decodable>(_ request: HTTPRequest) async throws -> T {
        try await RequestPlumbing.perform(request, over: transport)
    }
}

/// The request plumbing shared by the standalone clients in this kit
/// (`EngageAPI`, `MediaUploadAPI`): URL building with the `+` → `%2B`
/// re-encoding the server's form-urlencoded query decoding requires (a
/// bookmarks cursor can carry a literal `+`), and the success-or-`APIError`
/// response handling — all mirroring `APIClient`'s private helpers, which new
/// surface can't reach.
enum RequestPlumbing {
    static func url(base: URL, path: String, query: [URLQueryItem] = []) -> URL {
        let full = base.appendingPathComponent(path)
        guard !query.isEmpty,
              var comps = URLComponents(url: full, resolvingAgainstBaseURL: false) else {
            return full
        }
        comps.queryItems = query
        comps.percentEncodedQuery = comps.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return comps.url ?? full
    }

    static func pathSegment(_ raw: String) -> String {
        raw.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? raw
    }

    static func perform<T: Decodable>(_ request: HTTPRequest, over transport: HTTPTransport) async throws -> T {
        let response = try await transport.send(request)
        guard response.isSuccess else {
            let body = try? UnragerJSON.decoder.decode(ServerError.self, from: response.body)
            throw APIError.from(status: response.status, body: body)
        }
        return try UnragerJSON.decode(T.self, from: response.body)
    }
}
