import Foundation
import Testing
@testable import UnragerKit

@Suite("URLSessionTransport session configuration")
struct TransportConfigurationTests {
    @Test("SSE streams get their own session without the 60s resource cap")
    func streamSessionEscapesResourceCap() {
        let transport = URLSessionTransport()
        #expect(transport.streamSession.configuration.timeoutIntervalForResource >= 3_600)
        #expect(transport.streamSession.configuration.timeoutIntervalForRequest >= 300)
    }

    @Test("Plain requests keep the tight timeouts")
    func requestSessionKeepsTightTimeouts() {
        let transport = URLSessionTransport()
        #expect(transport.session.configuration.timeoutIntervalForResource == 60)
        #expect(transport.session.configuration.timeoutIntervalForRequest == 20)
        #expect(transport.session !== transport.streamSession)
    }

    @Test("An injected session backs both paths")
    func injectedSessionIsShared() {
        let session = URLSession(configuration: .ephemeral)
        let transport = URLSessionTransport(session: session)
        #expect(transport.session === session)
        #expect(transport.streamSession === session)
    }
}

@Suite("APIClient URL construction")
struct QueryEncodingTests {
    private actor RecordingTransport: HTTPTransport {
        private(set) var urls: [URL] = []

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            urls.append(request.url)
            return HTTPResponse(status: 200, headers: [:],
                                body: Data(#"{"tweets":[],"cursor":null}"#.utf8))
        }

        func stream(_ request: HTTPRequest) async throws -> (Int, AsyncThrowingStream<String, Error>) {
            urls.append(request.url)
            return (200, AsyncThrowingStream { $0.finish() })
        }

        func lastURL() -> URL? { urls.last }
    }

    private func recordedURL(
        _ call: (APIClient) async throws -> Void
    ) async throws -> URL {
        let transport = RecordingTransport()
        let client = APIClient(transport: transport, baseURL: { URL(string: "http://server:7777")! })
        try? await call(client)
        return try #require(await transport.lastURL())
    }

    @Test("Literal '+' in a search query survives the server's form-urlencoded decoding")
    func plusInSearchQuery() async throws {
        let url = try await recordedURL { _ = try await $0.search(query: "c++", product: .latest, cursor: nil) }
        let query = try #require(url.query(percentEncoded: true))
        #expect(query.contains("q=c%2B%2B"))
        #expect(!query.contains("+"))
    }

    @Test("Literal '+' in a pagination cursor is percent-encoded")
    func plusInCursor() async throws {
        let url = try await recordedURL {
            _ = try await $0.home(following: false, originals: false, cursor: "DAABCg+ABCD==")
        }
        let query = try #require(url.query(percentEncoded: true))
        #expect(query.contains("cursor=DAABCg%2BABCD%3D%3D") || query.contains("cursor=DAABCg%2BABCD=="))
        #expect(!query.contains("+"))
    }

    @Test("Spaces and reserved characters still round-trip")
    func spacesStillEncode() async throws {
        let url = try await recordedURL { _ = try await $0.bookmarks(query: "1+1 = 2", cursor: nil) }
        let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let q = try #require(comps.queryItems?.first(where: { $0.name == "q" })?.value)
        #expect(q == "1+1 = 2")
    }
}
