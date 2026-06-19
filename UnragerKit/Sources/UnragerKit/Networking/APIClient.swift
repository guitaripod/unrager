import Foundation

/// Multipart file part for compose/reply.
public struct ComposeMedia: Sendable {
    public let data: Data
    public let filename: String
    public let mimeType: String

    public init(data: Data, filename: String, mimeType: String) {
        self.data = data
        self.filename = filename
        self.mimeType = mimeType
    }
}

public struct ServerHealth: Decodable, Sendable {
    public let ok: Bool
    public let name: String
    public let version: String
}

/// Typed client for the unrager HTTP API. Stateless aside from the transport
/// and a base-URL provider (so the server address can change at runtime via
/// Settings). Cross-platform — shared by both apps.
public final class APIClient: Sendable {
    private let transport: HTTPTransport
    private let baseURL: @Sendable () -> URL

    public init(transport: HTTPTransport, baseURL: @escaping @Sendable () -> URL) {
        self.transport = transport
        self.baseURL = baseURL
    }

    public convenience init(baseURL: @escaping @Sendable () -> URL) {
        self.init(transport: URLSessionTransport(), baseURL: baseURL)
    }

    // MARK: - Health / Whoami

    public func health() async throws -> ServerHealth {
        try await get("api/health", as: ServerHealth.self)
    }

    public func whoami() async throws -> Whoami {
        try await get("api/whoami", as: Whoami.self)
    }

    // MARK: - Timelines / Sources

    public func home(following: Bool, originals: Bool, cursor: String?, count: Int? = nil) async throws -> TimelinePage {
        var query = [URLQueryItem(name: "following", value: following ? "true" : "false")]
        if originals { query.append(URLQueryItem(name: "mode", value: "originals")) }
        append(&query, cursor: cursor, count: count)
        return try await get("api/sources/home", query: query, as: TimelinePage.self)
    }

    public func userTimeline(handle: String, cursor: String?, count: Int? = nil) async throws -> TimelinePage {
        var query: [URLQueryItem] = []
        append(&query, cursor: cursor, count: count)
        return try await get("api/sources/user/\(pathSegment(handle))", query: query, as: TimelinePage.self)
    }

    public func search(query q: String, product: SourceProduct, cursor: String?, count: Int? = nil) async throws -> TimelinePage {
        var query = [
            URLQueryItem(name: "q", value: q),
            URLQueryItem(name: "product", value: product.apiValue),
        ]
        append(&query, cursor: cursor, count: count)
        return try await get("api/sources/search", query: query, as: TimelinePage.self)
    }

    public func mentions(cursor: String?, count: Int? = nil) async throws -> TimelinePage {
        var query: [URLQueryItem] = []
        append(&query, cursor: cursor, count: count)
        return try await get("api/sources/mentions", query: query, as: TimelinePage.self)
    }

    public func bookmarks(query q: String, cursor: String?, count: Int? = nil) async throws -> TimelinePage {
        var query = [URLQueryItem(name: "q", value: q)]
        append(&query, cursor: cursor, count: count)
        return try await get("api/sources/bookmarks", query: query, as: TimelinePage.self)
    }

    public func notifications(cursor: String?, count: Int? = nil) async throws -> NotificationsPage {
        var query: [URLQueryItem] = []
        append(&query, cursor: cursor, count: count)
        return try await get("api/sources/notifications", query: query, as: NotificationsPage.self)
    }

    // MARK: - Tweets / Threads

    public func tweet(id: String) async throws -> Tweet {
        try await get("api/tweet/\(pathSegment(id))", as: Tweet.self)
    }

    public func thread(id: String, cursor: String? = nil) async throws -> ThreadView {
        var query: [URLQueryItem] = []
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await get("api/thread/\(pathSegment(id))", query: query, as: ThreadView.self)
    }

    // MARK: - Profiles / Likers

    public func profile(handle: String, includeReplies: Bool = false) async throws -> ProfileView {
        var query: [URLQueryItem] = []
        if includeReplies { query.append(URLQueryItem(name: "include_replies", value: "true")) }
        return try await get("api/profile/\(pathSegment(handle))", query: query, as: ProfileView.self)
    }

    public func likers(tweetID: String, cursor: String?, count: Int? = nil) async throws -> LikersPage {
        var query: [URLQueryItem] = []
        append(&query, cursor: cursor, count: count)
        return try await get("api/likers/\(pathSegment(tweetID))", query: query, as: LikersPage.self)
    }

    // MARK: - Engage

    public func like(tweetID: String) async throws -> EngageResult {
        try await postEmpty("api/engage/\(pathSegment(tweetID))/like", as: EngageResult.self)
    }

    public func unlike(tweetID: String) async throws -> EngageResult {
        try await postEmpty("api/engage/\(pathSegment(tweetID))/unlike", as: EngageResult.self)
    }

    // MARK: - Compose

    public func compose(text: String, media: [ComposeMedia] = []) async throws -> ComposeResult {
        try await multipart("api/compose", text: text, media: media)
    }

    public func reply(to tweetID: String, text: String, media: [ComposeMedia] = []) async throws -> ComposeResult {
        try await multipart("api/reply/\(pathSegment(tweetID))", text: text, media: media)
    }

    // MARK: - Seen

    @discardableResult
    public func markSeen(ids: [String]) async throws -> MarkSeenResult {
        try await postJSON("api/seen", body: MarkSeenRequest(ids: ids), as: MarkSeenResult.self)
    }

    public func checkSeen(id: String) async throws -> Bool {
        try await get("api/seen/\(pathSegment(id))", as: SeenCheck.self).seen
    }

    // MARK: - Session

    public func session() async throws -> SessionState {
        try await get("api/session", as: SessionState.self)
    }

    @discardableResult
    public func patchSession(_ patch: SessionPatch) async throws -> SessionState {
        try await self.patch("api/session", body: patch, as: SessionState.self)
    }

    // MARK: - Filter config

    public func filterConfig() async throws -> FilterConfig {
        try await get("api/config/filter", as: FilterConfig.self)
    }

    @discardableResult
    public func patchFilterConfig(_ patch: FilterPatch) async throws -> FilterConfig {
        try await self.patch("api/config/filter", body: patch, as: FilterConfig.self)
    }

    // MARK: - Media

    /// The proxy URL for a tweet's media at `index`; stream bytes from here to
    /// display an image/video (the server forwards X CDN bytes with a real
    /// content-type and a 7-day cache header).
    public func mediaURL(tweetID: String, index: Int) -> URL {
        url("api/media/\(pathSegment(tweetID))/\(index)")
    }

    // MARK: - SSE / LLM streams

    public func filterStream(ids: [String]) -> AsyncThrowingStream<FilterVerdictEvent, Error> {
        sseStream("api/sse/filter",
                  query: [URLQueryItem(name: "ids", value: ids.joined(separator: ","))],
                  as: FilterVerdictEvent.self)
    }

    public func askStream(tweetID: String, preset: AskPreset) -> AsyncThrowingStream<TokenEvent, Error> {
        sseStream("api/sse/ask",
                  query: [URLQueryItem(name: "tweet_id", value: tweetID),
                          URLQueryItem(name: "preset", value: preset.rawValue)],
                  as: TokenEvent.self)
    }

    public func briefStream(handle: String) -> AsyncThrowingStream<TokenEvent, Error> {
        sseStream("api/sse/brief",
                  query: [URLQueryItem(name: "handle", value: handle)],
                  as: TokenEvent.self)
    }

    public func translateStream(tweetID: String) -> AsyncThrowingStream<TokenEvent, Error> {
        sseStream("api/sse/translate",
                  query: [URLQueryItem(name: "tweet_id", value: tweetID)],
                  as: TokenEvent.self)
    }

    // MARK: - Request plumbing

    private func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        let base = baseURL().appendingPathComponent(path)
        guard !query.isEmpty,
              var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return base
        }
        comps.queryItems = query
        return comps.url ?? base
    }

    private func pathSegment(_ raw: String) -> String {
        raw.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? raw
    }

    private func append(_ query: inout [URLQueryItem], cursor: String?, count: Int?) {
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        if let count { query.append(URLQueryItem(name: "count", value: String(count))) }
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], as type: T.Type) async throws -> T {
        try await perform(HTTPRequest(method: .get, url: url(path, query: query)))
    }

    private func postEmpty<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        try await perform(HTTPRequest(method: .post, url: url(path)))
    }

    private func postJSON<Body: Encodable, T: Decodable>(_ path: String, body: Body, as type: T.Type) async throws -> T {
        let data = try UnragerJSON.encoder.encode(body)
        let request = HTTPRequest(
            method: .post, url: url(path),
            headers: ["Content-Type": "application/json"], body: data)
        return try await perform(request)
    }

    private func patch<Body: Encodable, T: Decodable>(_ path: String, body: Body, as type: T.Type) async throws -> T {
        let data = try UnragerJSON.encoder.encode(body)
        let request = HTTPRequest(
            method: .patch, url: url(path),
            headers: ["Content-Type": "application/json"], body: data)
        return try await perform(request)
    }

    private func multipart(_ path: String, text: String, media: [ComposeMedia]) async throws -> ComposeResult {
        let boundary = "unrager.\(UUID().uuidString)"
        var body = Data()
        func appendString(_ string: String) { body.append(Data(string.utf8)) }

        if !text.isEmpty {
            appendString("--\(boundary)\r\n")
            appendString("Content-Disposition: form-data; name=\"text\"\r\n\r\n")
            appendString(text)
            appendString("\r\n")
        }
        for item in media {
            appendString("--\(boundary)\r\n")
            appendString("Content-Disposition: form-data; name=\"media\"; filename=\"\(item.filename)\"\r\n")
            appendString("Content-Type: \(item.mimeType)\r\n\r\n")
            body.append(item.data)
            appendString("\r\n")
        }
        appendString("--\(boundary)--\r\n")

        let request = HTTPRequest(
            method: .post, url: url(path),
            headers: ["Content-Type": "multipart/form-data; boundary=\(boundary)"], body: body)
        return try await perform(request)
    }

    private func perform<T: Decodable>(_ request: HTTPRequest) async throws -> T {
        let response = try await transport.send(request)
        guard response.isSuccess else { throw apiError(from: response) }
        return try UnragerJSON.decode(T.self, from: response.body)
    }

    private func apiError(from response: HTTPResponse) -> APIError {
        let body = try? UnragerJSON.decoder.decode(ServerError.self, from: response.body)
        return APIError.from(status: response.status, body: body)
    }

    private func sseStream<T: Decodable & Sendable>(
        _ path: String, query: [URLQueryItem], as type: T.Type
    ) -> AsyncThrowingStream<T, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = HTTPRequest(method: .get, url: url(path, query: query))
                    let (status, lines) = try await transport.stream(request)
                    guard (200..<300).contains(status) else {
                        var raw = ""
                        for try await line in lines { raw += line }
                        let body = try? UnragerJSON.decoder.decode(ServerError.self, from: Data(raw.utf8))
                        throw APIError.from(status: status, body: body)
                    }
                    for try await line in lines {
                        guard line.hasPrefix("data:") else { continue }
                        var value = String(line.dropFirst(5))
                        if value.hasPrefix(" ") { value.removeFirst() }
                        if value == "[DONE]" { break }
                        if value.isEmpty { continue }
                        if let event = try? UnragerJSON.decoder.decode(T.self, from: Data(value.utf8)) {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
