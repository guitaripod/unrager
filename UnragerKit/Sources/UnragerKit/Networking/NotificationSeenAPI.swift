import Foundation

/// The cross-client notifications seen marker (`/api/notifications/seen`).
/// The wire value is an opaque string; unrager clients encode the last-seen
/// notification timestamp as ISO 8601 so every platform can compare markers.
public struct NotificationSeenMarker: Codable, Sendable, Equatable {
    public let marker: String?

    public init(marker: String?) {
        self.marker = marker
    }

    public init(timestamp: Date) {
        self.init(marker: Self.encode(timestamp))
    }

    /// The marker parsed as a timestamp, or nil when unset or written by a
    /// client using a format this one doesn't understand (ignored, not fatal).
    public var timestamp: Date? {
        marker.flatMap(Self.decode)
    }

    public static func encode(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    public static func decode(_ marker: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: marker) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: marker)
    }
}

/// Typed client for `GET`/`PUT /api/notifications/seen` — the server-persisted
/// notifications seen marker that keeps badge state in sync across clients.
/// Standalone (not an `APIClient` method) so it can ship without touching the
/// shared client; callers must tolerate `.notFound` from servers that predate
/// the endpoint and fall back to device-local tracking.
public final class NotificationSeenAPI: Sendable {
    private let transport: HTTPTransport
    private let baseURL: @Sendable () -> URL

    public init(transport: HTTPTransport = URLSessionTransport(),
                baseURL: @escaping @Sendable () -> URL) {
        self.transport = transport
        self.baseURL = baseURL
    }

    public func fetch() async throws -> NotificationSeenMarker {
        let request = HTTPRequest(method: .get, url: endpoint())
        return try await perform(request)
    }

    /// Writes the marker. Tolerates an empty/204 success body (echoes the sent
    /// marker back) so it works regardless of what the server chooses to return.
    @discardableResult
    public func update(_ marker: NotificationSeenMarker) async throws -> NotificationSeenMarker {
        let body = try UnragerJSON.encoder.encode(marker)
        let request = HTTPRequest(method: .put, url: endpoint(),
                                  headers: ["Content-Type": "application/json"], body: body)
        let response = try await transport.send(request)
        guard response.isSuccess else {
            let serverError = try? UnragerJSON.decoder.decode(ServerError.self, from: response.body)
            throw APIError.from(status: response.status, body: serverError)
        }
        return (try? UnragerJSON.decode(NotificationSeenMarker.self, from: response.body)) ?? marker
    }

    private func endpoint() -> URL {
        baseURL().appendingPathComponent("api/notifications/seen")
    }

    private func perform(_ request: HTTPRequest) async throws -> NotificationSeenMarker {
        let response = try await transport.send(request)
        guard response.isSuccess else {
            let body = try? UnragerJSON.decoder.decode(ServerError.self, from: response.body)
            throw APIError.from(status: response.status, body: body)
        }
        return try UnragerJSON.decode(NotificationSeenMarker.self, from: response.body)
    }
}
