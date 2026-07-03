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
        let transport = self.transport
        let url = baseURL().appendingPathComponent("api/sse/ask")
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let body = try UnragerJSON.encoder.encode(request)
                    let httpRequest = HTTPRequest(
                        method: .post, url: url,
                        headers: ["Content-Type": "application/json"], body: body)
                    let (status, lines) = try await transport.stream(httpRequest)
                    guard (200..<300).contains(status) else {
                        var raw = ""
                        for try await line in lines { raw += line }
                        let serverError = try? UnragerJSON.decoder.decode(ServerError.self, from: Data(raw.utf8))
                        throw APIError.from(status: status, body: serverError)
                    }
                    for try await line in lines {
                        guard line.hasPrefix("data:") else { continue }
                        var value = String(line.dropFirst(5))
                        if value.hasPrefix(" ") { value.removeFirst() }
                        if value == "[DONE]" { break }
                        if value.isEmpty { continue }
                        if let event = try? UnragerJSON.decoder.decode(TokenEvent.self, from: Data(value.utf8)) {
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
