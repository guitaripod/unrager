import Foundation

/// One line of the server's SSE responses, as the client reads it.
enum SSELine: Equatable {
    /// A `data:` payload, with the optional single leading space removed.
    case data(String)
    /// The `data: [DONE]` sentinel the server sends last.
    case done
    /// Keep-alive comments (`:`), blank separators, other fields and empty
    /// payloads.
    case ignored

    init(_ line: String) {
        guard line.hasPrefix("data:") else {
            self = .ignored
            return
        }
        var value = String(line.dropFirst(5))
        if value.hasPrefix(" ") { value.removeFirst() }
        if value == "[DONE]" {
            self = .done
        } else if value.isEmpty {
            self = .ignored
        } else {
            self = .data(value)
        }
    }
}

/// The event loop every SSE endpoint shares (filter verdicts and the
/// ask/brief/translate token streams). A stream only counts as complete when
/// the server's terminal event arrives: the `[DONE]` sentinel, or an event
/// `isTerminal` recognises (the token streams' `done: true`). A byte stream
/// that just stops, because the connection dropped or the server died, throws
/// `APIError.streamEndedEarly`, so a half-written answer is never taken for a
/// whole one. When the consumer stops listening the stream finishes quietly.
enum SSEStream {
    static func open<Event: Decodable & Sendable>(
        transport: HTTPTransport,
        request: @escaping @Sendable () throws -> HTTPRequest,
        as type: Event.Type,
        failure: @escaping @Sendable (Event) -> String? = { _ in nil },
        isTerminal: @escaping @Sendable (Event) -> Bool = { _ in false }
    ) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(transport: transport, request: try request(), failure: failure,
                                  isTerminal: isTerminal, continuation: continuation)
                    continuation.finish()
                } catch {
                    if Task.isCancelled {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func run<Event: Decodable & Sendable>(
        transport: HTTPTransport,
        request: HTTPRequest,
        failure: @Sendable (Event) -> String?,
        isTerminal: @Sendable (Event) -> Bool,
        continuation: AsyncThrowingStream<Event, Error>.Continuation
    ) async throws {
        let (status, lines) = try await transport.stream(request)
        guard (200..<300).contains(status) else {
            throw try await errorResponse(status: status, lines: lines)
        }
        var sawTerminal = false
        for try await line in lines {
            switch SSELine(line) {
            case .ignored:
                continue
            case .done:
                return
            case .data(let value):
                guard let event = try? UnragerJSON.decoder.decode(Event.self, from: Data(value.utf8)) else {
                    continue
                }
                if let message = failure(event) { throw APIError.upstream(message) }
                continuation.yield(event)
                if isTerminal(event) { sawTerminal = true }
            }
        }
        guard sawTerminal || Task.isCancelled else { throw APIError.streamEndedEarly }
    }

    /// The typed error for a non-2xx stream response, read from its JSON body.
    private static func errorResponse(status: Int, lines: AsyncThrowingStream<String, Error>) async throws -> APIError {
        var raw: [String] = []
        for try await line in lines { raw.append(line) }
        let body = try? UnragerJSON.decoder.decode(ServerError.self, from: Data(raw.joined(separator: "\n").utf8))
        return APIError.from(status: status, body: body)
    }
}
