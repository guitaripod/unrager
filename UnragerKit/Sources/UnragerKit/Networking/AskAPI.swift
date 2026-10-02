import Foundation

/// Typed client for `POST /api/sse/ask` — the conversational ask stream. The
/// request body carries the whole turn history plus any thread context the
/// caller has loaded (mirroring the TUI's ask view), and the response is the
/// same `TokenEvent` SSE the single-shot ask uses. Standalone so it ships
/// without touching the shared `APIClient`.
public final class AskAPI: Sendable {
    private let transport: HTTPTransport
    private let baseURL: @Sendable () -> URL

    public init(transport: HTTPTransport = URLSessionTransport(),
                baseURL: @escaping @Sendable () -> URL) {
        self.transport = transport
        self.baseURL = baseURL
    }

    public func askStream(_ request: AskRequest) -> AsyncThrowingStream<TokenEvent, Error> {
        let url = baseURL().appendingPathComponent("api/sse/ask")
        return SSEStream.open(
            transport: transport,
            request: {
                HTTPRequest(method: .post, url: url,
                            headers: ["Content-Type": "application/json"],
                            body: try UnragerJSON.encoder.encode(request))
            },
            as: TokenEvent.self, failure: { $0.error }, isTerminal: { $0.done })
    }
}
