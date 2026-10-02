import Foundation

public enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
}

public struct HTTPRequest: Sendable {
    public var method: HTTPMethod
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
    /// How long the request may wait for the server, for the few calls the
    /// server answers only after slow work of its own (a media upload to X, a
    /// post). `nil` keeps the transport's tight default.
    public var timeout: TimeInterval?

    public init(method: HTTPMethod = .get, url: URL, headers: [String: String] = [:], body: Data? = nil,
                timeout: TimeInterval? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }

    /// How long a publish call (media upload, post, reply) may take: the
    /// server answers only once X has the upload or the post, and a client that
    /// gives up first leaves the work done anyway.
    public static let publishTimeout: TimeInterval = 300
}

public struct HTTPResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public var isSuccess: Bool { (200..<300).contains(status) }
}

/// Transport abstraction so the API client is testable with a fake and the
/// concrete `URLSession` adapter lives in the app target.
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
    /// Opens an SSE response and yields it line-by-line (newline-stripped) for
    /// the LLM endpoints. Returns the HTTP status alongside the line stream.
    func stream(_ request: HTTPRequest) async throws -> (Int, AsyncThrowingStream<String, Error>)
}
