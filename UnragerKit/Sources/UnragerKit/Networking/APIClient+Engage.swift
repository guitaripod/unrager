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

    public init(transport: HTTPTransport = URLSessionTransport.shared,
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

/// The request plumbing shared by every client in this kit: URL building with
/// the `+` → `%2B` re-encoding the server's form-urlencoded query decoding
/// requires (a bookmarks cursor can carry a literal `+`), the one retry a GET
/// gets after a dropped connection, and the success-or-`APIError` response
/// handling.
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

    /// Sends a request whose success carries no body (a 204).
    static func performEmpty(_ request: HTTPRequest, over transport: HTTPTransport) async throws {
        _ = try await send(request, over: transport)
    }

    /// Sends `request` and returns its successful response, or throws the
    /// typed error for a failed one.
    static func send(_ request: HTTPRequest, over transport: HTTPTransport) async throws -> HTTPResponse {
        let response = try await sendRetryingGet(request, over: transport)
        guard response.isSuccess else { throw apiError(from: response) }
        return response
    }

    /// The typed error for a non-2xx response, from its JSON body.
    static func apiError(from response: HTTPResponse) -> APIError {
        let body = try? UnragerJSON.decoder.decode(ServerError.self, from: response.body)
        return APIError.from(status: response.status, body: body)
    }

    /// How long a GET waits before its one retry.
    static let getRetryDelay: Duration = .milliseconds(300)

    /// Sends `request`, trying a GET once more after `getRetryDelay` when the
    /// connection dropped or timed out. After the app returns from the
    /// background the first request often lands on a keep-alive connection
    /// the server or Tailscale already closed; a GET is safe to repeat, while a
    /// write never is, since the server may already have acted on it.
    private static func sendRetryingGet(_ request: HTTPRequest, over transport: HTTPTransport) async throws -> HTTPResponse {
        do {
            return try await transport.send(request)
        } catch let error as APIError where request.method == .get && error.retriesOnce {
            try await Task.sleep(for: getRetryDelay)
            return try await transport.send(request)
        }
    }

    /// Runs a post or reply, turning a timeout into `APIError.publishTimedOut`:
    /// the server has no idempotency key, so the user must check before
    /// posting the same thing again.
    static func publishing<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch APIError.timeout {
            throw APIError.publishTimedOut
        }
    }

    static func perform<T: Decodable>(_ request: HTTPRequest, over transport: HTTPTransport) async throws -> T {
        try UnragerJSON.decode(T.self, from: try await send(request, over: transport).body)
    }
}
