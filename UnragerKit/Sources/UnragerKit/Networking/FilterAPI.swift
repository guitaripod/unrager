import Foundation

/// Typed client for `POST /api/filter/overrides` — the user's own call on a
/// post. It outranks the model in every client (the extension, the terminal
/// client and this app) and survives rule changes. Standalone, like
/// `SocialAPI`, so it ships without touching the shared client.
public final class FilterAPI: Sendable {
    /// The most posts the server takes in one request.
    public static let maxIDsPerRequest = 20

    private let transport: HTTPTransport
    private let baseURL: @Sendable () -> URL

    public init(transport: HTTPTransport = URLSessionTransport(),
                baseURL: @escaping @Sendable () -> URL) {
        self.transport = transport
        self.baseURL = baseURL
    }

    private struct OverrideBody: Encodable {
        let ids: [String]
        let verdict: FilterVerdict?

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(ids, forKey: .ids)
            if let verdict {
                try container.encode(verdict, forKey: .verdict)
            } else {
                try container.encodeNil(forKey: .verdict)
            }
        }

        enum CodingKeys: String, CodingKey { case ids, verdict }
    }

    /// Shows (`.keep`) or hides (`.hide`) the posts whatever the model says;
    /// `nil` hands them back to the model.
    public func setOverride(ids: [String], verdict: FilterVerdict?) async throws {
        let body = try UnragerJSON.encoder.encode(OverrideBody(ids: ids, verdict: verdict))
        let request = HTTPRequest(
            method: .post,
            url: RequestPlumbing.url(base: baseURL(), path: "api/filter/overrides"),
            headers: ["Content-Type": "application/json"], body: body)
        try await RequestPlumbing.performEmpty(request, over: transport)
    }
}
