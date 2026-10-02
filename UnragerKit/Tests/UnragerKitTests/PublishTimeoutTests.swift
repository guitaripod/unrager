import Foundation
import Testing
@testable import UnragerKit

@Suite("Publish timeouts")
struct PublishTimeoutTests {
    private let posted = #"{"id":"9","url":"https://x.com/a/status/9"}"#

    @Test("Uploads, posts and replies wait for the server far longer than plain requests")
    func longTimeouts() async throws {
        let transport = ScriptedTransport(body: #"{"media_id":"m1","id":"9","url":"u"}"#)
        let api = MediaUploadAPI(transport: transport, baseURL: { .testServer })
        _ = try await api.upload(ComposeMedia(data: Data([1]), filename: "a.jpg", mimeType: "image/jpeg"))
        _ = try await api.compose(text: "hi")
        _ = try await api.reply(to: "1", text: "hi")
        let client = APIClient(transport: transport, baseURL: { .testServer })
        _ = try await client.compose(text: "hi")
        _ = try await client.reply(to: "1", text: "hi")
        let timeouts = await transport.requests.map(\.timeout)
        #expect(timeouts == Array(repeating: HTTPRequest.publishTimeout, count: 5))
        #expect(HTTPRequest.publishTimeout >= 300)
    }

    @Test("Plain requests keep the transport's default")
    func plainDefault() async throws {
        let transport = ScriptedTransport(body: #"{"ok":true,"name":"unrager","version":"1"}"#)
        _ = try await APIClient(transport: transport, baseURL: { .testServer }).health()
        #expect(await transport.last()?.timeout == nil)
    }

    @Test("A post that times out says it may have gone out")
    func composeTimeout() async {
        let transport = ScriptedTransport([.failure(.timeout)])
        let api = MediaUploadAPI(transport: transport, baseURL: { .testServer })
        await #expect(throws: APIError.publishTimedOut) { _ = try await api.compose(text: "hi") }
        await #expect(throws: APIError.publishTimedOut) { _ = try await api.reply(to: "1", text: "hi") }
        let client = APIClient(transport: transport, baseURL: { .testServer })
        await #expect(throws: APIError.publishTimedOut) { _ = try await client.compose(text: "hi") }
        #expect(APIError.publishTimedOut.errorDescription?.contains("profile") == true)
        #expect(!APIError.publishTimedOut.isRetryable)
    }

    @Test("An upload that times out is a plain timeout: nothing was posted")
    func uploadTimeout() async {
        let transport = ScriptedTransport([.failure(.timeout)])
        let api = MediaUploadAPI(transport: transport, baseURL: { .testServer })
        await #expect(throws: APIError.timeout) {
            _ = try await api.upload(ComposeMedia(data: Data([1]), filename: "a.jpg", mimeType: "image/jpeg"))
        }
    }

    @Test("A request timeout reaches URLRequest and runs outside the 60 s session cap")
    func transportHonoursTimeout() {
        let transport = URLSessionTransport()
        let slow = HTTPRequest(method: .post, url: .testServer, timeout: 300)
        #expect(transport.urlRequest(from: slow).timeoutInterval == 300)
        #expect(transport.session(for: slow).configuration.timeoutIntervalForResource >= 300)
        let plain = HTTPRequest(url: .testServer)
        #expect(transport.session(for: plain) === transport.session)
    }
}
