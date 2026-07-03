import Foundation
import Testing
@testable import UnragerKit

private actor CapturingTransport: HTTPTransport {
    private(set) var requests: [HTTPRequest] = []
    private let responseBody: String

    init(responseBody: String) {
        self.responseBody = responseBody
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        return HTTPResponse(status: 200, headers: [:], body: Data(responseBody.utf8))
    }

    func stream(_ request: HTTPRequest) async throws -> (Int, AsyncThrowingStream<String, Error>) {
        requests.append(request)
        return (200, AsyncThrowingStream { $0.finish() })
    }

    func lastRequest() -> HTTPRequest? { requests.last }
}

@Suite("Tweet repost/bookmark write-back")
struct TweetRetweetBookmarkTests {
    private func fixture() throws -> Tweet {
        let json = """
        {"rest_id":"42","author":{"rest_id":"2","handle":"a","name":"A","verified":true,
          "followers":9,"following":1},"created_at":"2026-06-19T12:00:00Z","text":"hi @b",
          "reply_count":3,"retweet_count":4,"like_count":10,"quote_count":1,"view_count":99,
          "bookmark_count":2,"favorited":true,"retweeted":false,"bookmarked":false,"lang":"en",
          "quoted_tweet":{"rest_id":"41","author":{"rest_id":"3","handle":"q","name":"Q",
            "verified":false,"followers":0,"following":0},"created_at":"2026-06-18T08:00:00Z",
            "text":"inner","reply_count":0,"retweet_count":0,"like_count":0,"quote_count":0,
            "url":"https://x.com/q/status/41"},
          "urls":[{"expanded_url":"https://example.com/a","display_url":"example.com/a"}],
          "url":"https://x.com/a/status/42"}
        """
        return try UnragerJSON.decode(Tweet.self, from: Data(json.utf8))
    }

    @Test("withRetweet flips only the repost state and count")
    func withRetweetFlipsState() throws {
        let tweet = try fixture()
        let reposted = tweet.withRetweet(retweeted: true, retweetCount: 5)
        #expect(reposted.retweeted)
        #expect(reposted.retweetCount == 5)
        #expect(reposted.restID == tweet.restID)
        #expect(reposted.text == tweet.text)
        #expect(reposted.author == tweet.author)
        #expect(reposted.createdAt == tweet.createdAt)
        #expect(reposted.favorited == tweet.favorited)
        #expect(reposted.likeCount == tweet.likeCount)
        #expect(reposted.bookmarked == tweet.bookmarked)
        #expect(reposted.bookmarkCount == tweet.bookmarkCount)
        #expect(reposted.viewCount == tweet.viewCount)
        #expect(reposted.quotedTweet?.restID == "41")
        #expect(reposted.urls.count == tweet.urls.count)
        #expect(reposted.displayDiffers(from: tweet))
    }

    @Test("withRetweet floors the count at zero")
    func withRetweetFloorsAtZero() throws {
        #expect(try fixture().withRetweet(retweeted: false, retweetCount: -1).retweetCount == 0)
    }

    @Test("togglingRetweet applies the ±1 delta and round-trips")
    func togglingRetweetAppliesDelta() throws {
        let tweet = try fixture()
        let reposted = try #require(tweet.togglingRetweet(to: true))
        #expect(reposted.retweeted)
        #expect(reposted.retweetCount == 5)
        let undone = try #require(reposted.togglingRetweet(to: false))
        #expect(!undone.retweeted)
        #expect(undone.retweetCount == 4)
    }

    @Test("togglingRetweet is nil when already in that state")
    func togglingRetweetGuardsDuplicates() throws {
        let tweet = try fixture()
        #expect(tweet.togglingRetweet(to: false) == nil)
        let reposted = try #require(tweet.togglingRetweet(to: true))
        #expect(reposted.togglingRetweet(to: true) == nil)
    }

    @Test("togglingRetweet never drops the count below zero")
    func togglingRetweetFloorsAtZero() throws {
        let zeroed = try fixture().withRetweet(retweeted: true, retweetCount: 0)
        let undone = try #require(zeroed.togglingRetweet(to: false))
        #expect(undone.retweetCount == 0)
    }

    @Test("withBookmark flips only the bookmark state and count")
    func withBookmarkFlipsState() throws {
        let tweet = try fixture()
        let marked = tweet.withBookmark(bookmarked: true, bookmarkCount: 3)
        #expect(marked.bookmarked)
        #expect(marked.bookmarkCount == 3)
        #expect(marked.retweeted == tweet.retweeted)
        #expect(marked.retweetCount == tweet.retweetCount)
        #expect(marked.favorited == tweet.favorited)
        #expect(marked.likeCount == tweet.likeCount)
        #expect(marked.displayDiffers(from: tweet))
    }

    @Test("togglingBookmark round-trips with the duplicate guard")
    func togglingBookmarkRoundTrips() throws {
        let tweet = try fixture()
        #expect(tweet.togglingBookmark(to: false) == nil)
        let marked = try #require(tweet.togglingBookmark(to: true))
        #expect(marked.bookmarked)
        #expect(marked.bookmarkCount == 3)
        #expect(marked.togglingBookmark(to: true) == nil)
        let unmarked = try #require(marked.togglingBookmark(to: false))
        #expect(!unmarked.bookmarked)
        #expect(unmarked.bookmarkCount == 2)
    }

    @Test("togglingBookmark never drops the count below zero")
    func togglingBookmarkFloorsAtZero() throws {
        let zeroed = try fixture().withBookmark(bookmarked: true, bookmarkCount: 0)
        let unmarked = try #require(zeroed.togglingBookmark(to: false))
        #expect(unmarked.bookmarkCount == 0)
    }
}

@Suite("EngageAPI requests")
struct EngageAPITests {
    private func client(_ transport: CapturingTransport) -> EngageAPI {
        EngageAPI(transport: transport, baseURL: { URL(string: "http://server:7777")! })
    }

    @Test("retweet posts to /api/tweets/{id}/retweet and decodes the idempotent flag")
    func retweetRequest() async throws {
        let transport = CapturingTransport(responseBody: #"{"ok":true,"idempotent":true}"#)
        let result = try await client(transport).retweet(tweetID: "42")
        #expect(result.ok)
        #expect(result.idempotent == true)
        let request = try #require(await transport.lastRequest())
        #expect(request.method == .post)
        #expect(request.url.absoluteString == "http://server:7777/api/tweets/42/retweet")
    }

    @Test("unretweet issues DELETE on the same path")
    func unretweetRequest() async throws {
        let transport = CapturingTransport(responseBody: #"{"ok":true}"#)
        let result = try await client(transport).unretweet(tweetID: "42")
        #expect(result.ok)
        #expect(result.idempotent == nil)
        let request = try #require(await transport.lastRequest())
        #expect(request.method == .delete)
        #expect(request.url.absoluteString == "http://server:7777/api/tweets/42/retweet")
    }

    @Test("bookmark and unbookmark hit /api/tweets/{id}/bookmark")
    func bookmarkRequests() async throws {
        let transport = CapturingTransport(responseBody: #"{"ok":true}"#)
        _ = try await client(transport).bookmark(tweetID: "7")
        var request = try #require(await transport.lastRequest())
        #expect(request.method == .post)
        #expect(request.url.absoluteString == "http://server:7777/api/tweets/7/bookmark")
        _ = try await client(transport).unbookmark(tweetID: "7")
        request = try #require(await transport.lastRequest())
        #expect(request.method == .delete)
    }

    @Test("bookmarksTimeline sends no q and percent-encodes a '+' cursor")
    func bookmarksTimelineRequest() async throws {
        let transport = CapturingTransport(responseBody: #"{"tweets":[],"cursor":null}"#)
        _ = try await client(transport).bookmarksTimeline(cursor: "AB+CD==", count: 20)
        let request = try #require(await transport.lastRequest())
        #expect(request.url.path == "/api/sources/bookmarks")
        let query = try #require(request.url.query(percentEncoded: true))
        #expect(!query.contains("q="))
        #expect(query.contains("cursor=AB%2BCD"))
        #expect(query.contains("count=20"))
        #expect(!query.contains("+"))
    }

    @Test("a server error surfaces as APIError, not a decode failure")
    func errorSurfaces() async throws {
        let transport = CapturingTransport(responseBody: #"{"error":"nope","kind":"upstream"}"#)
        actor Failing: HTTPTransport {
            func send(_ request: HTTPRequest) async throws -> HTTPResponse {
                HTTPResponse(status: 502, headers: [:], body: Data(#"{"error":"nope","kind":"upstream"}"#.utf8))
            }
            func stream(_ request: HTTPRequest) async throws -> (Int, AsyncThrowingStream<String, Error>) {
                (502, AsyncThrowingStream { $0.finish() })
            }
        }
        _ = transport
        let api = EngageAPI(transport: Failing(), baseURL: { URL(string: "http://server:7777")! })
        await #expect(throws: APIError.self) {
            try await api.retweet(tweetID: "42")
        }
    }
}

@Suite("MediaUploadAPI requests")
struct MediaUploadAPITests {
    private let attachment = ComposeMedia(
        data: Data([0xFF, 0xD8, 0xFF]), filename: "photo.jpg", mimeType: "image/jpeg")

    private func client(_ transport: CapturingTransport) -> MediaUploadAPI {
        MediaUploadAPI(transport: transport, baseURL: { URL(string: "http://server:7777")! })
    }

    @Test("upload posts a multipart 'media' part and returns the media id")
    func uploadRequest() async throws {
        let transport = CapturingTransport(responseBody: #"{"media_id":"12345"}"#)
        let id = try await client(transport).upload(attachment)
        #expect(id == "12345")
        let request = try #require(await transport.lastRequest())
        #expect(request.method == .post)
        #expect(request.url.absoluteString == "http://server:7777/api/media/upload")
        let contentType = try #require(request.headers["Content-Type"])
        #expect(contentType.hasPrefix("multipart/form-data; boundary="))
        let body = try #require(request.body.flatMap { String(decoding: $0, as: UTF8.self) })
        #expect(body.contains("Content-Disposition: form-data; name=\"media\"; filename=\"photo.jpg\""))
        #expect(body.contains("Content-Type: image/jpeg"))
    }

    @Test("compose carries text, one media_ids part per id, and quote_tweet_id")
    func composeRequest() async throws {
        let transport = CapturingTransport(responseBody:
            #"{"id":"99","url":"https://x.com/me/status/99"}"#)
        let result = try await client(transport).compose(
            text: "hello", mediaIDs: ["1", "2"], quoteTweetID: "42")
        #expect(result.id == "99")
        #expect(!result.idempotent)
        let request = try #require(await transport.lastRequest())
        #expect(request.url.absoluteString == "http://server:7777/api/compose")
        let body = try #require(request.body.flatMap { String(decoding: $0, as: UTF8.self) })
        #expect(body.contains("name=\"text\"\r\n\r\nhello"))
        #expect(body.ranges(of: "name=\"media_ids\"").count == 2)
        #expect(body.contains("name=\"quote_tweet_id\"\r\n\r\n42"))
    }

    @Test("reply targets /api/reply/{id} and omits quote_tweet_id")
    func replyRequest() async throws {
        let transport = CapturingTransport(responseBody:
            #"{"id":"100","url":"https://x.com/me/status/100"}"#)
        _ = try await client(transport).reply(to: "42", text: "yo", mediaIDs: ["1"])
        let request = try #require(await transport.lastRequest())
        #expect(request.url.absoluteString == "http://server:7777/api/reply/42")
        let body = try #require(request.body.flatMap { String(decoding: $0, as: UTF8.self) })
        #expect(body.contains("name=\"media_ids\"\r\n\r\n1"))
        #expect(!body.contains("quote_tweet_id"))
    }

    @Test("MediaUploadResult decodes the wire shape")
    func mediaUploadResultDecodes() throws {
        let decoded = try UnragerJSON.decode(MediaUploadResult.self,
                                             from: Data(#"{"media_id":"777"}"#.utf8))
        #expect(decoded == MediaUploadResult(mediaID: "777"))
    }
}
