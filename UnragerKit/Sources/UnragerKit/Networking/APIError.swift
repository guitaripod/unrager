import Foundation

/// The machine-readable `kind` tag the server returns alongside an error body
/// (`{"error": "...", "kind": "..."}`).
public enum ServerErrorKind: String, Sendable {
    case badRequest = "bad_request"
    case config
    case auth
    case notFound = "not_found"
    case rateLimited = "rate_limited"
    case upstream
    case `internal`
    case unknown
}

/// The error JSON shape every non-2xx API response carries.
public struct ServerError: Decodable, Sendable {
    public let error: String
    public let kind: String

    public var parsedKind: ServerErrorKind { ServerErrorKind(rawValue: kind) ?? .unknown }
}

public enum APIError: Error, Sendable, Equatable {
    case invalidRequest(String)
    case network(String)
    case timeout
    case cancelled
    case unauthorized(String)
    case forbidden(String)
    case notFound(String)
    case rateLimited(String)
    case upstream(String)
    case server(status: Int, message: String)
    case decoding(String)
    case unexpectedStatus(Int)

    /// Maps an HTTP status + decoded server body to a typed error.
    public static func from(status: Int, body: ServerError?) -> APIError {
        let message = body?.error ?? "HTTP \(status)"
        switch status {
        case 400: return .invalidRequest(message)
        case 401: return .unauthorized(message)
        case 403: return .forbidden(message)
        case 404: return .notFound(message)
        case 429: return .rateLimited(message)
        case 502: return .upstream(message)
        case 500...599: return .server(status: status, message: message)
        default: return .unexpectedStatus(status)
        }
    }

    public var isRetryable: Bool {
        switch self {
        case .timeout, .network, .rateLimited, .upstream, .server: return true
        default: return false
        }
    }
}

extension APIError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let m): return m
        case .network: return "Can't reach the unrager server. Check the server address in Settings and that `unrager serve` is running."
        case .timeout: return "The request timed out."
        case .cancelled: return "Cancelled."
        case .unauthorized: return "The server isn't logged in to X (cookies missing or expired)."
        case .forbidden(let m): return m
        case .notFound(let m): return m
        case .rateLimited: return "X is rate-limiting requests. Try again shortly."
        case .upstream(let m): return m
        case .server(_, let m): return m
        case .decoding: return "The server sent data this app couldn't read."
        case .unexpectedStatus(let s): return "Unexpected response (HTTP \(s))."
        }
    }
}
