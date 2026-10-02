import Foundation
import Testing
@testable import UnragerKit

@Suite("GET retry after a dropped connection")
struct RetryTests {
    private let health = #"{"ok":true,"name":"unrager","version":"1"}"#

    @Test("A GET whose connection dropped is sent once more and succeeds")
    func retriesLostConnection() async throws {
        let transport = ScriptedTransport([.failure(.connectionLost("lost")), .response(status: 200, body: health)])
        let started = ContinuousClock.now
        let result = try await APIClient(transport: transport, baseURL: { .testServer }).health()
        #expect(result.ok)
        #expect(await transport.requests.count == 2)
        #expect(ContinuousClock.now - started >= RequestPlumbing.getRetryDelay)
    }

    @Test("A GET that timed out is retried, in the standalone clients too")
    func retriesTimeout() async throws {
        let transport = ScriptedTransport([.failure(.timeout), .response(status: 200, body: #"{"users":[],"cursor":null}"#)])
        _ = try await SocialAPI(transport: transport, baseURL: { .testServer }).followers(userID: "1")
        #expect(await transport.requests.count == 2)
    }

    @Test("Only one retry: a second drop is reported")
    func retriesOnlyOnce() async {
        let transport = ScriptedTransport([.failure(.connectionLost("lost"))])
        await #expect(throws: APIError.connectionLost("lost")) {
            _ = try await APIClient(transport: transport, baseURL: { .testServer }).health()
        }
        #expect(await transport.requests.count == 2)
    }

    @Test("Writes are never retried")
    func writesNotRetried() async {
        let transport = ScriptedTransport([.failure(.connectionLost("lost")), .response(status: 200, body: #"{"ok":true}"#)])
        let client = APIClient(transport: transport, baseURL: { .testServer })
        await #expect(throws: APIError.connectionLost("lost")) { _ = try await client.like(tweetID: "1") }
        #expect(await transport.requests.count == 1)
        let social = SocialAPI(transport: transport, baseURL: { .testServer })
        _ = try? await social.follow(userID: "1")
        #expect(await transport.requests.map(\.method) == [.post, .post])
    }

    @Test("Refused connections, rate limits and server errors aren't retried")
    func otherFailuresNotRetried() async {
        for outcome: ScriptedTransport.Outcome in [
            .failure(.network("Could not connect to the server.")),
            .response(status: 429, body: #"{"error":"slow","kind":"rate_limited"}"#),
            .response(status: 500, body: #"{"error":"boom","kind":"internal"}"#),
        ] {
            let transport = ScriptedTransport([outcome, .response(status: 200, body: health)])
            _ = try? await APIClient(transport: transport, baseURL: { .testServer }).health()
            #expect(await transport.requests.count == 1)
        }
    }

    @Test("A dropped connection reads like any other unreachable server, and is retryable")
    func connectionLostMessage() {
        let error = APIError.connectionLost("The network connection was lost.")
        #expect(error.errorDescription?.contains("Can't reach the unrager server") == true)
        #expect(error.isRetryable)
        #expect(!APIError.rateLimited("x").retriesOnce)
    }
}
