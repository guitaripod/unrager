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
    /// The connection dropped mid-request, typically a keep-alive connection
    /// that went stale while the app was in the background.
    case connectionLost(String)
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
    /// A stream stopped before the server's terminal event, so what arrived
    /// is only part of the answer.
    case streamEndedEarly
    /// A post or reply got no answer in time. The server may still have
    /// posted it, so trying again could post it twice.
    case publishTimedOut

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

    /// Whether the same request may succeed if the user tries again.
    public var isRetryable: Bool {
        switch self {
        case .timeout, .network, .connectionLost, .rateLimited, .upstream, .server, .streamEndedEarly: return true
        default: return false
        }
    }

    /// The retryable failures worth one automatic retry of a GET: a dropped
    /// connection or a timeout, which a fresh connection usually clears. Rate
    /// limits and server errors won't clear in a few hundred milliseconds.
    var retriesOnce: Bool {
        switch self {
        case .connectionLost, .timeout: return isRetryable
        default: return false
        }
    }
}

extension APIError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let m): return m
        case .network(let detail), .connectionLost(let detail):
            let cause = detail.isEmpty ? "" : " (\(detail))"
            return "Can't reach the unrager server\(cause). Check the server address in Settings and that `unrager serve` is running."
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
        case .publishTimedOut:
            return "The server didn't answer in time, so the post may have gone out anyway. Check your profile before posting it again."
        case .streamEndedEarly: return "The connection to the unrager server dropped before the answer finished. Try again."
        }
    }
}

public extension Error {
    /// Whether this error only says the work was cancelled (a task cancelled,
    /// a request abandoned), which a screen should drop silently rather than
    /// report as a failure.
    var isCancellation: Bool {
        if self is CancellationError { return true }
        if let error = self as? APIError { return error == .cancelled }
        if let error = self as? URLError { return error.code == .cancelled }
        return false
    }
}
