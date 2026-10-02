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

    /// The same ISO 8601 style the notification timestamps are parsed with,
    /// at the millisecond precision they carry.
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plain = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

    /// The marker string for `date` at the nearest millisecond, so a timestamp
    /// that went through a `Double` on the way here still names the
    /// millisecond it came from. The fraction is written by hand: the format
    /// style truncates, turning a hair under `.001` into `.000`.
    public static func encode(_ date: Date) -> String {
        let (seconds, millis) = NotificationPrefs.milliseconds(date).quotientAndRemainder(dividingBy: 1000)
        let whole = plain.format(Date(timeIntervalSince1970: TimeInterval(seconds)))
        return whole.dropLast() + String(format: ".%03dZ", Int(millis))
    }

    public static func decode(_ marker: String) -> Date? {
        (try? fractional.parse(marker)) ?? (try? plain.parse(marker))
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

    public init(transport: HTTPTransport = URLSessionTransport.shared,
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
        let response = try await RequestPlumbing.send(request, over: transport)
        return (try? UnragerJSON.decode(NotificationSeenMarker.self, from: response.body)) ?? marker
    }

    private func endpoint() -> URL {
        baseURL().appendingPathComponent("api/notifications/seen")
    }

    private func perform(_ request: HTTPRequest) async throws -> NotificationSeenMarker {
        try await RequestPlumbing.perform(request, over: transport)
    }
}
