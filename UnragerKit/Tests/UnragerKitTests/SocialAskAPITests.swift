import Foundation
import Testing
@testable import UnragerKit

private actor CapturingTransport: HTTPTransport {
    private(set) var requests: [HTTPRequest] = []
    private let body: String
    private let status: Int

    init(body: String = "{}", status: Int = 200) {
        self.body = body
        self.status = status
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        return HTTPResponse(status: status, headers: [:], body: Data(body.utf8))
    }

    func stream(_ request: HTTPRequest) async throws -> (Int, AsyncThrowingStream<String, Error>) {
        requests.append(request)
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return (status, AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        })
    }

    func last() -> HTTPRequest? { requests.last }
}

@Suite("SocialAPI")
struct SocialAPITests {
    private func makeAPI(body: String, status: Int = 200) -> (SocialAPI, CapturingTransport) {
        let transport = CapturingTransport(body: body, status: status)
        let api = SocialAPI(transport: transport, baseURL: { URL(string: "http://server:7777")! })
        return (api, transport)
    }

    @Test("follow POSTs to /api/users/{id}/follow and decodes the flag")
    func followRoute() async throws {
        let (api, transport) = makeAPI(body: #"{"ok":true,"following":true}"#)
        let result = try await api.follow(userID: "12345")
        #expect(result.ok)
        #expect(result.following)
        let request = try #require(await transport.last())
        #expect(request.method == .post)
        #expect(request.url.absoluteString == "http://server:7777/api/users/12345/follow")
    }

    @Test("unfollow uses DELETE on the same route")
    func unfollowRoute() async throws {
        let (api, transport) = makeAPI(body: #"{"ok":true,"following":false}"#)
        let result = try await api.unfollow(userID: "someone")
        #expect(!result.following)
        let request = try #require(await transport.last())
        #expect(request.method == .delete)
        #expect(request.url.path == "/api/users/someone/follow")
    }

    @Test("followers page decodes users and cursor, and encodes the cursor param")
    func followersPage() async throws {
        let json = """
        {"users":[{"rest_id":"9","handle":"carol","name":"Carol","verified":false,
                   "followers":10,"following":5,"avatar_url":null}],
         "cursor":"171+2|abc"}
        """
        let (api, transport) = makeAPI(body: json)
        let page = try await api.followers(userID: "1", cursor: "17|xyz+")
        #expect(page.users.count == 1)
        #expect(page.users.first?.handle == "carol")
        #expect(page.cursor == "171+2|abc")
        let request = try #require(await transport.last())
        #expect(request.url.path == "/api/users/1/followers")
        let query = try #require(request.url.query(percentEncoded: true))
        #expect(!query.contains("+"))
    }

    @Test("following list hits its own subresource")
    func followingRoute() async throws {
        let (api, transport) = makeAPI(body: #"{"users":[],"cursor":null}"#)
        _ = try await api.following(userID: "1")
        let request = try #require(await transport.last())
        #expect(request.url.path == "/api/users/1/following")
    }

    @Test("profile decodes followed_by_me riding inside the user object")
    func profileRelationship() async throws {
        let json = """
        {"user":{"rest_id":"11","handle":"nasa","name":"NASA","verified":true,
                 "followers":92000000,"following":119,"avatar_url":null,
                 "followed_by_me":true},
         "pinned":null,"recent":[],"cursor":null}
        """
        let (api, _) = makeAPI(body: json)
        let profile = try await api.profile(handle: "nasa")
        #expect(profile.user.handle == "nasa")
        #expect(profile.followedByMe == true)
    }

    @Test("profile from an older server leaves followedByMe nil")
    func profileWithoutRelationship() async throws {
        let json = """
        {"user":{"rest_id":"11","handle":"nasa","name":"NASA","verified":true,
                 "followers":92000000,"following":119,"avatar_url":null},
         "pinned":null,"recent":[],"cursor":null}
        """
        let (api, _) = makeAPI(body: json)
        let profile = try await api.profile(handle: "nasa")
        #expect(profile.followedByMe == nil)
    }

    @Test("HTTP errors surface as APIError")
    func errorSurfaces() async {
        let (api, _) = makeAPI(body: #"{"error":"nope","kind":"bad_request"}"#, status: 400)
        do {
            _ = try await api.follow(userID: "x")
            Issue.record("expected throw")
        } catch {
            #expect(error is APIError)
        }
    }
}

@Suite("AskAPI")
struct AskAPITests {
    @Test("askStream POSTs the wire-shaped JSON body and parses SSE tokens")
    func askStreamBodyAndTokens() async throws {
        let sse = """
        data: {"token":"Hello","done":false}
        data: {"token":" world","done":false}
        data: {"token":"","done":true}
        data: [DONE]
        """
        let transport = CapturingTransport(body: sse)
        let api = AskAPI(transport: transport, baseURL: { URL(string: "http://server:7777")! })
        let request = AskRequest(
            tweetID: "42",
            turns: [
                AskTurn(role: .user, text: "Explain this post."),
                AskTurn(role: .assistant, text: "It is about tests."),
                AskTurn(role: .user, text: "Summarize the replies."),
            ],
            ancestors: [AskContextEntry(handle: "root", text: "the op")],
            replies: [AskContextEntry(handle: "carol", text: "nice")])

        var tokens: [String] = []
        for try await event in api.askStream(request) where !event.token.isEmpty {
            tokens.append(event.token)
        }
        #expect(tokens == ["Hello", " world"])

        let sent = try #require(await transport.last())
        #expect(sent.method == .post)
        #expect(sent.url.path == "/api/sse/ask")
        #expect(sent.headers["Content-Type"] == "application/json")
        let body = try #require(sent.body)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["tweet_id"] as? String == "42")
        let turns = try #require(json["turns"] as? [[String: Any]])
        #expect(turns.count == 3)
        #expect(turns[0]["role"] as? String == "user")
        #expect(turns[1]["role"] as? String == "assistant")
        let ancestors = try #require(json["ancestors"] as? [[String: Any]])
        #expect(ancestors.first?["handle"] as? String == "root")
        let replies = try #require(json["replies"] as? [[String: Any]])
        #expect(replies.first?["text"] as? String == "nice")
    }

    @Test("an error status surfaces as APIError, not silent completion")
    func askStreamErrorStatus() async {
        let transport = CapturingTransport(body: #"{"error":"turns must not be empty","kind":"bad_request"}"#,
                                           status: 400)
        let api = AskAPI(transport: transport, baseURL: { URL(string: "http://server:7777")! })
        do {
            for try await _ in api.askStream(AskRequest(tweetID: "1", turns: [])) {}
            Issue.record("expected throw")
        } catch {
            #expect(error is APIError)
        }
    }

    @Test("AskContextEntry lifts handle and text from a Tweet")
    func contextEntryFromTweet() throws {
        let json = """
        {"rest_id":"1","author":{"rest_id":"9","handle":"carol","name":"Carol","verified":false,
         "followers":0,"following":0,"avatar_url":null},
         "created_at":"2026-06-19T12:00:00Z","text":"hello thread",
         "reply_count":0,"retweet_count":0,"like_count":0,"quote_count":0,"view_count":null,
         "lang":null,"in_reply_to_tweet_id":null,"quoted_tweet":null,"media":[],
         "url":"https://x.com/carol/status/1"}
        """
        let tweet = try UnragerJSON.decode(Tweet.self, from: Data(json.utf8))
        let entry = AskContextEntry(tweet: tweet)
        #expect(entry.handle == "carol")
        #expect(entry.text == "hello thread")
    }
}
