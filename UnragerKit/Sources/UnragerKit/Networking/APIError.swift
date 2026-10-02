import Foundation

/// The machine-readable `kind` tag the server returns alongside an error body
/// (`{"error": "...", "kind": "..."}`).
public enum ServerErrorKind: String, Sendable {
    case badRequest = "bad_request"
    case config
    case auth
    case notFound = "not_found"
    case unavailable
    case rateLimited = "rate_limited"
    case offline
    case credits
    case upstream
    case filterOnly = "filter_only"
    case forbiddenOrigin = "forbidden_origin"
    case `internal`
    case unknown
}

/// The error JSON shape every non-2xx API response carries:
/// `{"error": "...", "kind": "...", "retry_after_secs"?: n, "reason"?: "..."}`.
/// The last two are absent from older servers and from most errors.
public struct ServerError: Decodable, Sendable {
    public let error: String
    public let kind: String
    /// How long X asked to wait, on a rate limit.
    public let retryAfterSecs: Int?
    /// Why something is gone, on an `unavailable` error ("suspended",
    /// "protected", "deleted", …).
    public let reason: String?

    enum CodingKeys: String, CodingKey {
        case error, kind, reason
        case retryAfterSecs = "retry_after_secs"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        error = try c.decode(String.self, forKey: .error)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ServerErrorKind.unknown.rawValue
        retryAfterSecs = try? c.decodeIfPresent(Int.self, forKey: .retryAfterSecs)
        reason = try? c.decodeIfPresent(String.self, forKey: .reason)
    }

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
    /// HTTP 410: the account or post is gone or hidden; `reason` says why
    /// ("suspended", "protected", "deleted", …) when the server knows.
    case unavailable(reason: String?, message: String)
    /// HTTP 429, with how long X asked to wait when it said.
    case rateLimited(String, retryAfter: TimeInterval? = nil)
    /// HTTP 503 `offline`: the server can't reach X.
    case offline(String)
    /// HTTP 402: posting through X's API needs credits the account lacks.
    case credits(String)
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

    /// Maps an HTTP status + decoded server body (and the response headers,
    /// for `Retry-After`) to a typed error.
    public static func from(status: Int, body: ServerError?, headers: [String: String] = [:]) -> APIError {
        let message = body?.error ?? "HTTP \(status)"
        switch status {
        case 400: return .invalidRequest(message)
        case 401: return .unauthorized(message)
        case 402: return .credits(message)
        case 403: return .forbidden(message)
        case 404: return .notFound(message)
        case 410: return .unavailable(reason: body?.reason, message: message)
        case 429: return .rateLimited(message, retryAfter: retryAfter(body: body, headers: headers))
        case 502: return .upstream(message)
        case 503 where body?.parsedKind == .offline: return .offline(message)
        case 500...599: return .server(status: status, message: message)
        default: return .unexpectedStatus(status)
        }
    }

    /// The wait a rate limit asks for: the body's `retry_after_secs`, else a
    /// `Retry-After` header given in seconds.
    private static func retryAfter(body: ServerError?, headers: [String: String]) -> TimeInterval? {
        if let seconds = body?.retryAfterSecs, seconds > 0 { return TimeInterval(seconds) }
        let header = headers.first { $0.key.caseInsensitiveCompare("Retry-After") == .orderedSame }?.value
        guard let seconds = header.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }), seconds > 0 else {
            return nil
        }
        return TimeInterval(seconds)
    }

    /// Whether the same request may succeed if the user tries again.
    public var isRetryable: Bool {
        switch self {
        case .timeout, .network, .connectionLost, .rateLimited, .offline, .upstream, .server, .streamEndedEarly:
            return true
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
        case let .unavailable(reason, message): return Self.unavailableMessage(reason: reason, message: message)
        case let .rateLimited(_, retryAfter):
            return "X is rate-limiting requests. Try again \(retryAfter.map(Self.waitPhrase) ?? "shortly")."
        case .offline: return "The unrager server can't reach X right now. Try again in a moment."
        case .credits:
            return "Posting needs X API credits, and the server's X API account has none left. Add credits in the X developer portal, or turn on posting through the X app in Settings."
        case .upstream(let m): return m
        case .server(_, let m): return m
        case .decoding: return "The server sent data this app couldn't read."
        case .unexpectedStatus(let s): return "Unexpected response (HTTP \(s))."
        case .publishTimedOut:
            return "The server didn't answer in time, so the post may have gone out anyway. Check your profile before posting it again."
        case .streamEndedEarly: return "The connection to the unrager server dropped before the answer finished. Try again."
        }
    }

    /// "in 45 s", "in 4 min", "in 2 h": a wait rounded up to the unit that
    /// reads naturally.
    static func waitPhrase(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded(.up))
        if whole < 60 { return "in \(max(1, whole)) s" }
        if whole < 3_600 { return "in \((whole + 59) / 60) min" }
        return "in \((whole + 3_599) / 3_600) h"
    }

    private static func unavailableMessage(reason: String?, message: String) -> String {
        switch reason {
        case "suspended": return "This account is suspended."
        case "protected": return "This account's posts are protected: only its approved followers can see them."
        case "deactivated": return "This account was deactivated."
        default: return message.hasPrefix("HTTP ") ? "This is no longer available." : message
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
