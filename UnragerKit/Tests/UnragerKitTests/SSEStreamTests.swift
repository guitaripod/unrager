import Foundation
import Testing
@testable import UnragerKit

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

private struct ScriptedStream: HTTPTransport {
    let status: Int
    let lines: [String]
    var hangs = false
    var terminated = Flag()

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        HTTPResponse(status: status, headers: [:], body: Data())
    }

    func stream(_ request: HTTPRequest) async throws -> (Int, AsyncThrowingStream<String, Error>) {
        let lines = lines
        let hangs = hangs
        let terminated = terminated
        return (status, AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            if !hangs { continuation.finish() }
            continuation.onTermination = { _ in terminated.set() }
        })
    }
}

@Suite("SSE streams")
struct SSEStreamTests {
    private func client(_ transport: ScriptedStream) -> APIClient {
        APIClient(transport: transport, baseURL: { URL(string: "http://server:7777")! })
    }

    private func collect<T>(_ stream: AsyncThrowingStream<T, Error>) async throws -> [T] {
        var events: [T] = []
        for try await event in stream { events.append(event) }
        return events
    }

    @Test("A non-2xx JSON body becomes the typed APIError")
    func errorStatus() async {
        let transport = ScriptedStream(status: 400, lines: ["{", #""error":"bad handle","#, #""kind":"bad_request"}"#])
        await #expect(throws: APIError.invalidRequest("bad handle")) {
            _ = try await collect(client(transport).briefStream(handle: "x"))
        }
    }

    @Test("Keep-alive comments and undecodable payloads are skipped; [DONE] ends the stream")
    func skipsNoiseAndStopsAtDone() async throws {
        let transport = ScriptedStream(status: 200, lines: [
            ":", ": keep-alive", "",
            #"data: {"id":"1","verdict":"hide","reason":"rage"}"#,
            "data: {not json",
            "event: ping",
            #"data:{"id":"2","verdict":"keep"}"#,
            "data: [DONE]",
            #"data: {"id":"3","verdict":"keep"}"#,
        ])
        let verdicts = try await collect(client(transport).filterStream(ids: ["1", "2", "3"]))
        #expect(verdicts.map(\.id) == ["1", "2"])
        #expect(verdicts.first?.reason == "rage")
    }

    @Test("A done event carrying an error throws it")
    func doneWithError() async {
        let transport = ScriptedStream(status: 200, lines: [
            #"data: {"token":"Hal","done":false}"#,
            #"data: {"token":"","done":true,"error":"model unreachable"}"#,
            "data: [DONE]",
        ])
        await #expect(throws: APIError.upstream("model unreachable")) {
            _ = try await collect(client(transport).translateStream(tweetID: "1"))
        }
    }

    @Test("A token stream that stops without its terminal event is an error, not an answer")
    func endedEarly() async {
        let transport = ScriptedStream(status: 200, lines: [#"data: {"token":"Half an","done":false}"#])
        await #expect(throws: APIError.streamEndedEarly) {
            _ = try await collect(client(transport).askStream(tweetID: "1", preset: .explain))
        }
        let ask = AskAPI(transport: transport, baseURL: { URL(string: "http://server:7777")! })
        await #expect(throws: APIError.streamEndedEarly) {
            _ = try await collect(ask.askStream(AskRequest(tweetID: "1", turns: [AskTurn(role: .user, text: "hi")])))
        }
    }

    @Test("A filter stream that stops before [DONE] is an error")
    func filterEndedEarly() async {
        let transport = ScriptedStream(status: 200, lines: [#"data: {"id":"1","verdict":"keep"}"#])
        await #expect(throws: APIError.streamEndedEarly) {
            _ = try await collect(client(transport).filterStream(ids: ["1", "2"]))
        }
    }

    @Test("The done event completes a token stream even if [DONE] never follows")
    func doneEventIsTerminal() async throws {
        let transport = ScriptedStream(status: 200, lines: [
            #"data: {"token":"Hi","done":false}"#,
            #"data: {"token":"","done":true}"#,
        ])
        let events = try await collect(client(transport).briefStream(handle: "x"))
        #expect(events.map(\.token).joined() == "Hi")
    }

    @Test("Cancelling the consumer cancels the transport stream and finishes quietly")
    func consumerCancellation() async throws {
        let transport = ScriptedStream(status: 200, lines: [#"data: {"token":"a","done":false}"#], hangs: true)
        let stream = client(transport).askStream(tweetID: "1", preset: .explain)
        let consumer = Task {
            var tokens: [String] = []
            for try await event in stream { tokens.append(event.token) }
            return tokens
        }
        try await Task.sleep(for: .milliseconds(100))
        consumer.cancel()
        let tokens = try await consumer.value
        #expect(tokens == ["a"])
        for _ in 0..<50 where !transport.terminated.isSet {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(transport.terminated.isSet)
    }

    @Test("SSE lines parse into data, the sentinel and noise")
    func lineParsing() {
        #expect(SSELine("data: x") == .data("x"))
        #expect(SSELine("data:x") == .data("x"))
        #expect(SSELine("data:  x") == .data(" x"))
        #expect(SSELine("data: [DONE]") == .done)
        #expect(SSELine("data:") == .ignored)
        #expect(SSELine(": keep-alive") == .ignored)
        #expect(SSELine("") == .ignored)
    }
}
