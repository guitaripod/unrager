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

    @Test("The shared transport is one instance with both sessions configured")
    func sharedTransport() {
        let shared = URLSessionTransport.shared
        #expect(shared === URLSessionTransport.shared)
        #expect(shared.session.configuration.timeoutIntervalForResource == 60)
        #expect(shared.streamSession.configuration.timeoutIntervalForResource >= 3_600)
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

@Suite("APIError messages")
struct APIErrorMessageTests {
    @Test("A network failure names its cause, so offline and a refused connection read differently")
    func networkCause() {
        let offline = APIError.network("The Internet connection appears to be offline.").errorDescription ?? ""
        let refused = APIError.network("Could not connect to the server.").errorDescription ?? ""
        #expect(offline.contains("offline"))
        #expect(refused.contains("Could not connect"))
        #expect(offline != refused)
        #expect(APIError.network("").errorDescription?.contains("()") == false)
    }
}

@Suite("Post analytics")
struct PostAnalyticsTests {
    private actor Canned: HTTPTransport {
        let status: Int
        let body: String
        init(status: Int, body: String) { self.status = status; self.body = body }
        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            HTTPResponse(status: status, headers: [:], body: Data(body.utf8))
        }
        func stream(_ request: HTTPRequest) async throws -> (Int, AsyncThrowingStream<String, Error>) {
            (status, AsyncThrowingStream { $0.finish() })
        }
    }

    private func client(status: Int = 200, body: String) -> APIClient {
        APIClient(transport: Canned(status: status, body: body), baseURL: { URL(string: "http://server:7777")! })
    }

    @Test("The analytics JSON decodes, with a rate and the hourly series")
    func decodes() async throws {
        let json = #"{"impressions":155,"engagements":8,"detail_expands":5,"profile_visits":1,"link_clicks":0,"follows":0,"hourly_impressions":[2,130,23]}"#
        let analytics = try #require(try await client(body: json).postAnalytics(tweetID: "1"))
        #expect(analytics.impressions == 155)
        #expect(analytics.detailExpands == 5)
        #expect(analytics.hourlyImpressions == [2, 130, 23])
        #expect(abs(try #require(analytics.engagementRate) - 8.0 / 155.0) < 0.0001)
        #expect(analytics.videoViews == nil)
    }

    @Test("Someone else's post has no analytics, which is nil rather than an error")
    func notYoursIsNil() async throws {
        let none = try await client(status: 404, body: #"{"error":"no analytics for this post","kind":"not_found"}"#)
            .postAnalytics(tweetID: "1")
        #expect(none == nil)
    }

    @Test("Other failures still throw")
    func otherErrorsThrow() async {
        await #expect(throws: APIError.self) {
            _ = try await client(status: 429, body: #"{"error":"slow down","kind":"rate_limited"}"#)
                .postAnalytics(tweetID: "1")
        }
    }

    @Test("No impressions means no rate")
    func noRate() {
        #expect(PostAnalytics(impressions: 0, engagements: 0).engagementRate == nil)
    }
}
