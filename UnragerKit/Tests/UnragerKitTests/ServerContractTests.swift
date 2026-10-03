import Foundation
import Testing
@testable import UnragerKit

private let userJSON = #"{"rest_id":"7","handle":"ada","name":"Ada","verified":false,"followers":1,"following":2}"#

private func tweetJSON(id: String, extra: String = "") -> String {
    """
    {"rest_id":"\(id)","author":\(userJSON),"created_at":"2026-06-19T12:30:00Z","text":"t",
     "url":"https://x.com/ada/status/\(id)","reply_count":0,"retweet_count":0,"like_count":0,
     "quote_count":0,"media":[]\(extra)}
    """
}

@Suite("Server error contract")
struct ServerErrorContractTests {
    private func error(_ status: Int, _ body: String, headers: [String: String] = [:]) async -> APIError? {
        let transport = ScriptedTransport(status: status, body: body, headers: headers)
        do {
            _ = try await APIClient(transport: transport, baseURL: { .testServer }).health()
            return nil
        } catch {
            return error as? APIError
        }
    }

    @Test("404 not_found keeps the server's message")
    func notFound() async {
        let error = await error(404, #"{"error":"no such post","kind":"not_found"}"#)
        #expect(error == .notFound("no such post"))
        #expect(error?.errorDescription == "no such post")
    }

    @Test("410 unavailable says why the account or post is gone")
    func unavailable() async {
        let suspended = await error(410, #"{"error":"account suspended","kind":"unavailable","reason":"suspended"}"#)
        #expect(suspended == .unavailable(reason: "suspended", message: "account suspended"))
        #expect(suspended?.errorDescription == "This account is suspended.")
        let protected = await error(410, #"{"error":"protected","kind":"unavailable","reason":"protected"}"#)
        #expect(protected?.errorDescription?.hasPrefix("This account's posts are protected") == true)
        let deleted = await error(410, #"{"error":"This post was deleted.","kind":"unavailable","reason":"deleted"}"#)
        #expect(deleted?.errorDescription == "This post was deleted.")
        let bare = await error(410, "")
        #expect(bare?.errorDescription == "This is no longer available.")
        #expect(suspended?.isRetryable == false)
    }

    @Test("429 carries the wait from the body, or else the Retry-After header")
    func rateLimited() async {
        let fromBody = await error(429, #"{"error":"slow down","kind":"rate_limited","retry_after_secs":235}"#,
                                   headers: ["Retry-After": "10"])
        #expect(fromBody == .rateLimited("slow down", retryAfter: 235))
        #expect(fromBody?.errorDescription == "X is rate-limiting requests. Try again in 4 min.")
        let fromHeader = await error(429, #"{"error":"slow down","kind":"rate_limited"}"#, headers: ["retry-after": "30"])
        #expect(fromHeader == .rateLimited("slow down", retryAfter: 30))
        #expect(fromHeader?.errorDescription == "X is rate-limiting requests. Try again in 30 s.")
        let unknown = await error(429, #"{"error":"slow down","kind":"rate_limited"}"#)
        #expect(unknown?.errorDescription == "X is rate-limiting requests. Try again shortly.")
        #expect(unknown?.isRetryable == true)
    }

    @Test("Waits read in the unit that fits")
    func waitPhrases() {
        #expect(APIError.waitPhrase(0.2) == "in 1 s")
        #expect(APIError.waitPhrase(59) == "in 59 s")
        #expect(APIError.waitPhrase(60) == "in 1 min")
        #expect(APIError.waitPhrase(61) == "in 2 min")
        #expect(APIError.waitPhrase(7_200) == "in 2 h")
    }

    @Test("503 offline is its own error; filter_only keeps the server's explanation")
    func serviceUnavailable() async {
        let offline = await error(503, #"{"error":"X unreachable","kind":"offline"}"#)
        #expect(offline == .offline("X unreachable"))
        #expect(offline?.errorDescription == "The unrager server can't reach X right now. Try again in a moment.")
        let filterOnly = await error(503, #"{"error":"this unrager server runs with --filter-only (all the browser extension needs); run `unrager setup --apps` to serve the iPhone app too","kind":"filter_only"}"#)
        guard case let .server(status, message) = filterOnly else {
            Issue.record("expected .server, got \(String(describing: filterOnly))")
            return
        }
        #expect(status == 503)
        #expect(message.contains("unrager setup --apps"))
    }

    @Test("402 credits, 401 auth and 403 forbidden_origin")
    func otherKinds() async {
        let credits = await error(402, #"{"error":"credits depleted","kind":"credits"}"#)
        #expect(credits == .credits("credits depleted"))
        #expect(credits?.errorDescription?.hasPrefix("Posting needs X API credits") == true)
        #expect(credits?.isRetryable == false)
        let auth = await error(401, #"{"error":"not logged in","kind":"auth"}"#)
        #expect(auth == .unauthorized("not logged in"))
        let origin = await error(403, #"{"error":"unrager only answers its browser extension and the iPhone app, not web pages","kind":"forbidden_origin"}"#)
        #expect(origin == .forbidden("unrager only answers its browser extension and the iPhone app, not web pages"))
    }

    @Test("The error body decodes with and without the new fields")
    func errorBody() throws {
        let full = try UnragerJSON.decoder.decode(ServerError.self, from: Data(
            #"{"error":"x","kind":"rate_limited","retry_after_secs":60,"reason":"r"}"#.utf8))
        #expect(full.parsedKind == .rateLimited)
        #expect(full.retryAfterSecs == 60)
        #expect(full.reason == "r")
        let old = try UnragerJSON.decoder.decode(ServerError.self, from: Data(#"{"error":"x","kind":"something_new"}"#.utf8))
        #expect(old.parsedKind == .unknown)
        #expect(old.retryAfterSecs == nil)
        #expect(old.reason == nil)
        let kinds = ["unavailable", "offline", "credits", "filter_only", "forbidden_origin"].map { ServerErrorKind(rawValue: $0) }
        #expect(kinds == [.unavailable, .offline, .credits, .filterOnly, .forbiddenOrigin])
    }
}

@Suite("Profile and repost fields")
struct ProfileFieldsTests {
    @Test("A repost carries who reposted it; the tweet is the original")
    func retweetedBy() throws {
        let reposter = #"{"rest_id":"9","handle":"bob","name":"Bob","verified":true,"followers":3,"following":4}"#
        let tweet = try UnragerJSON.decode(Tweet.self, from: Data(tweetJSON(id: "1", extra: #","retweeted_by":\#(reposter)"#).utf8))
        #expect(tweet.author.handle == "ada")
        #expect(tweet.retweetedBy?.handle == "bob")
        let again = try UnragerJSON.decode(Tweet.self, from: UnragerJSON.encoder.encode(tweet))
        #expect(again.retweetedBy?.handle == "bob")
        #expect(tweet.withLike(favorited: true, likeCount: 1).retweetedBy?.handle == "bob")
        #expect(tweet.togglingRetweet(to: true)?.retweetedBy?.handle == "bob")
        let plain = try UnragerJSON.decode(Tweet.self, from: Data(tweetJSON(id: "2").utf8))
        #expect(plain.retweetedBy == nil)
    }

    @Test("The profile extras decode, round-trip, and default when absent")
    func userExtras() throws {
        let json = """
        {"rest_id":"7","handle":"ada","name":"Ada","verified":false,"followers":1,"following":2,
         "description":"Counting engines","location":"London","website":"https://ada.example",
         "joined_at":"2018-10-10T20:19:24Z","protected":true,"muting":false,"blocking":true,"followed_by_me":true}
        """
        let user = try UnragerJSON.decode(User.self, from: Data(json.utf8))
        #expect(user.bio == "Counting engines")
        #expect(user.location == "London")
        #expect(user.website == "https://ada.example")
        #expect(user.joinedAt == Date(timeIntervalSince1970: 1_539_202_764))
        #expect(user.isProtected)
        #expect(user.isMuting == false)
        #expect(user.isBlocking == true)
        #expect(user.followedByMe == true)
        #expect(try UnragerJSON.decode(User.self, from: UnragerJSON.encoder.encode(user)) == user)

        let bare = try UnragerJSON.decode(User.self, from: Data(userJSON.utf8))
        #expect(bare.bio == nil && bare.joinedAt == nil && bare.website == nil)
        #expect(!bare.isProtected)
        #expect(bare.isMuting == nil && bare.isBlocking == nil && bare.followedByMe == nil)
        let encoded = try #require(String(data: UnragerJSON.encoder.encode(bare), encoding: .utf8))
        #expect(!encoded.contains("protected"))
    }

    @Test("A malformed profile extra reads as absent instead of failing the user")
    func malformedExtras() throws {
        let json = #"{"rest_id":"7","handle":"ada","name":"Ada","verified":false,"followers":1,"following":2,"joined_at":"last year","protected":"yes"}"#
        let user = try UnragerJSON.decode(User.self, from: Data(json.utf8))
        #expect(user.joinedAt == nil)
        #expect(!user.isProtected)
    }

    @Test("A timeline page carries the pinned post; a bad one is dropped, not fatal")
    func pagePinned() throws {
        let page = try UnragerJSON.decode(TimelinePage.self, from: Data(
            #"{"tweets":[\#(tweetJSON(id: "2"))],"cursor":"c","pinned":\#(tweetJSON(id: "1"))}"#.utf8))
        #expect(page.pinned?.restID == "1")
        #expect(page.tweets.map(\.restID) == ["2"])
        let bad = try UnragerJSON.decode(TimelinePage.self, from: Data(
            #"{"tweets":[\#(tweetJSON(id: "2"))],"cursor":null,"pinned":{"rest_id":1}}"#.utf8))
        #expect(bad.pinned == nil)
        #expect(bad.tweets.count == 1)
        let old = try UnragerJSON.decode(TimelinePage.self, from: Data(#"{"tweets":[],"cursor":null}"#.utf8))
        #expect(old.pinned == nil)
    }

    @Test("A profile's pinned post decodes, and a bad one doesn't fail the profile")
    func profilePinned() throws {
        let json = #"{"user":\#(userJSON),"pinned":\#(tweetJSON(id: "1")),"recent":[],"cursor":null}"#
        #expect(try UnragerJSON.decode(ProfileView.self, from: Data(json.utf8)).pinned?.restID == "1")
        #expect(try UnragerJSON.decode(ProfileRelationshipView.self, from: Data(json.utf8)).pinned?.restID == "1")
        let bad = #"{"user":\#(userJSON),"pinned":{"rest_id":true},"recent":[],"cursor":null}"#
        #expect(try UnragerJSON.decode(ProfileView.self, from: Data(bad.utf8)).pinned == nil)
        #expect(try UnragerJSON.decode(ProfileRelationshipView.self, from: Data(bad.utf8)).pinned == nil)
    }
}

@Suite("New endpoints")
struct NewEndpointTests {
    @Test("deleteTweet sends DELETE /api/tweets/{id} and reads idempotent")
    func deleteTweet() async throws {
        let transport = ScriptedTransport(body: #"{"ok":true,"idempotent":true}"#)
        let result = try await APIClient(transport: transport, baseURL: { .testServer }).deleteTweet(id: "123")
        #expect(result.ok && result.idempotent)
        let request = try #require(await transport.last())
        #expect(request.method == .delete)
        #expect(request.url.absoluteString == "http://server:7777/api/tweets/123")
    }

    @Test("A bad post id is a bad request")
    func badID() async {
        let transport = ScriptedTransport(status: 400, body: #"{"error":"not a post id","kind":"bad_request"}"#)
        await #expect(throws: APIError.invalidRequest("not a post id")) {
            try await APIClient(transport: transport, baseURL: { .testServer }).deleteTweet(id: "abc")
        }
    }

    @Test("Mute and block POST to set and DELETE to clear")
    func muteAndBlock() async throws {
        let transport = ScriptedTransport([
            .response(status: 200, body: #"{"ok":true,"muting":true}"#),
            .response(status: 200, body: #"{"ok":true,"muting":false}"#),
            .response(status: 200, body: #"{"ok":true,"blocking":true}"#),
            .response(status: 200, body: #"{"ok":true,"blocking":false}"#),
        ])
        let api = SocialAPI(transport: transport, baseURL: { .testServer })
        #expect(try await api.setMuted(userID: "7", muted: true).muting)
        #expect(try await !api.setMuted(userID: "7", muted: false).muting)
        #expect(try await api.setBlocked(userID: "7", blocked: true).blocking)
        #expect(try await !api.setBlocked(userID: "7", blocked: false).blocking)
        let requests = await transport.requests
        #expect(requests.map(\.method) == [.post, .delete, .post, .delete])
        #expect(requests.map(\.url.path) == ["/api/users/7/mute", "/api/users/7/mute", "/api/users/7/block", "/api/users/7/block"])
    }

    @Test("quotes reads a search-shaped page and passes the cursor")
    func quotes() async throws {
        let transport = ScriptedTransport(body: #"{"tweets":[\#(tweetJSON(id: "5"))],"cursor":"n+1"}"#)
        let client = APIClient(transport: transport, baseURL: { .testServer })
        let page = try await client.quotes(tweetID: "1", cursor: "c+2")
        #expect(page.tweets.map(\.restID) == ["5"])
        #expect(page.cursor == "n+1")
        let request = try #require(await transport.last())
        #expect(request.method == .get)
        #expect(request.url.path == "/api/tweets/1/quotes")
        #expect(request.url.query(percentEncoded: true) == "cursor=c%2B2")
        _ = try await client.quotes(tweetID: "1")
        #expect(await transport.last()?.url.query == nil)
    }

    @Test("A profile without its posts asks for tweets=false")
    func profileWithoutTweets() async throws {
        let body = #"{"user":\#(userJSON),"pinned":null,"recent":[],"cursor":null}"#
        let transport = ScriptedTransport(body: body)
        let client = APIClient(transport: transport, baseURL: { .testServer })
        _ = try await client.profile(handle: "ada", includeTweets: false)
        #expect(await transport.last()?.url.query == "tweets=false")
        _ = try await client.profile(handle: "ada")
        #expect(await transport.last()?.url.query == nil)
        let social = SocialAPI(transport: transport, baseURL: { .testServer })
        _ = try await social.profile(handle: "ada", includeTweets: false)
        #expect(await transport.last()?.url.query == "tweets=false")
        _ = try await social.profile(handle: "ada")
        #expect(await transport.last()?.url.query == nil)
    }
}
