import Foundation
import Testing
@testable import UnragerKit

@Suite("Model decoding matches the server JSON")
struct DecodingTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try UnragerJSON.decode(type, from: Data(json.utf8))
    }

    @Test("Full tweet with nested quote, media and counts")
    func tweet() throws {
        let json = """
        {
          "rest_id": "1790000000000000001",
          "author": {"rest_id":"44196397","handle":"elonmusk","name":"Elon Musk",
                     "verified":true,"followers":200000000,"following":500,
                     "avatar_url":"https://pbs.twimg.com/x_normal.jpg"},
          "created_at": "2026-06-19T12:00:00Z",
          "text": "Hello world",
          "reply_count": 12, "retweet_count": 34, "like_count": 567, "quote_count": 8,
          "view_count": 102345, "bookmark_count": 5,
          "favorited": false, "retweeted": false, "bookmarked": false,
          "lang": "en", "in_reply_to_tweet_id": null,
          "quoted_tweet": {
            "rest_id":"123","author":{"rest_id":"1","handle":"a","name":"A","verified":false,
              "followers":0,"following":0,"avatar_url":null},
            "created_at":"2026-06-18T12:00:00Z","text":"quoted","reply_count":0,
            "retweet_count":0,"like_count":0,"quote_count":0,"view_count":null,
            "media":[],"url":"https://x.com/a/status/123","urls":[]
          },
          "media": [{"kind":"photo","url":"https://pbs.twimg.com/m.jpg","video_url":null,"alt_text":"a cat"}],
          "url": "https://x.com/elonmusk/status/1790000000000000001",
          "urls": [{"expanded_url":"https://example.com/a","display_url":"example.com/a"}]
        }
        """
        let tweet = try decode(Tweet.self, json)
        #expect(tweet.restID == "1790000000000000001")
        #expect(tweet.author.handle == "elonmusk")
        #expect(tweet.likeCount == 567)
        #expect(tweet.viewCount == 102345)
        #expect(tweet.bookmarkCount == 5)
        #expect(tweet.quotedTweet?.restID == "123")
        #expect(tweet.media.count == 1)
        #expect(tweet.media.first?.kind == .photo)
        #expect(tweet.media.first?.altText == "a cat")
        #expect(tweet.urls.first?.displayURL == "example.com/a")
    }

    @Test("Tweet tolerates missing default-able fields")
    func tweetDefaults() throws {
        let json = """
        {"rest_id":"1","author":{"rest_id":"2","handle":"a","name":"A","verified":false,
          "followers":0,"following":0},"created_at":"2026-06-19T12:00:00Z","text":"hi",
          "reply_count":0,"retweet_count":0,"like_count":0,"quote_count":0,"view_count":null,
          "url":"https://x.com/a/status/1"}
        """
        let tweet = try decode(Tweet.self, json)
        #expect(tweet.bookmarkCount == 0)
        #expect(tweet.favorited == false)
        #expect(tweet.media.isEmpty)
        #expect(tweet.urls.isEmpty)
        #expect(tweet.viewCount == nil)
        #expect(tweet.author.avatarURL == nil)
    }

    @Test("MediaKind unit and struct variants")
    func mediaKinds() throws {
        let video = try decode(Media.self, #"{"kind":"video","url":"p.jpg","video_url":"v.mp4","alt_text":null}"#)
        #expect(video.kind == .video)
        #expect(video.videoURL == "v.mp4")
        #expect(video.isVideo)

        let gif = try decode(Media.self, #"{"kind":"animated_gif","url":"g.jpg","video_url":"g.mp4"}"#)
        #expect(gif.kind == .animatedGif)

        let yt = try decode(Media.self, #"{"kind":{"you_tube":{"video_id":"dQw4w9WgXcQ"}},"url":"y.jpg"}"#)
        #expect(yt.kind == .youTube(videoID: "dQw4w9WgXcQ"))

        let card = try decode(Media.self,
            #"{"kind":{"link_card":{"title":"T","description":"D","domain":"example.com","target_url":"https://example.com"}},"url":"c.jpg"}"#)
        if case let .linkCard(title, _, domain, target) = card.kind {
            #expect(title == "T")
            #expect(domain == "example.com")
            #expect(target == "https://example.com")
        } else {
            Issue.record("expected link_card")
        }

        let poll = try decode(Media.self,
            #"{"kind":{"poll":{"options":[{"label":"A","count":10},{"label":"B","count":3}],"ends_at":"2026-06-20T00:00:00Z","counts_final":false}},"url":""}"#)
        if case let .poll(options, endsAt, final) = poll.kind {
            #expect(options.count == 2)
            #expect(options.first?.count == 10)
            #expect(endsAt != nil)
            #expect(final == false)
        } else {
            Issue.record("expected poll")
        }
    }

    @Test("SourceKind round-trips through encode/decode")
    func sourceKindRoundTrip() throws {
        let cases: [SourceKind] = [
            .home(following: true),
            .user(handle: "elonmusk"),
            .search(query: "rust", product: .top),
            .mentions(target: nil),
            .bookmarks(query: "*"),
        ]
        for value in cases {
            let data = try UnragerJSON.encoder.encode(value)
            let decoded = try UnragerJSON.decoder.decode(SourceKind.self, from: data)
            #expect(decoded == value)
        }
    }

    @Test("SessionState applies defaults")
    func sessionDefaults() throws {
        let state = try decode(SessionState.self, #"{"current_source":null}"#)
        #expect(state.feedMode == .all)
        #expect(state.filterEnabled == false)
        #expect(state.currentSource == nil)
    }

    @Test("TokenEvent and FilterVerdictEvent")
    func sseEvents() throws {
        let token = try decode(TokenEvent.self, #"{"token":"hi","done":false}"#)
        #expect(token.token == "hi")
        let done = try decode(TokenEvent.self, #"{"token":"","done":true}"#)
        #expect(done.done)
        let verdict = try decode(FilterVerdictEvent.self, #"{"id":"1","verdict":"hide"}"#)
        #expect(verdict.verdict == .hide)
    }

    @Test("Notification renames `type` and defaults actors")
    func notification() throws {
        let json = """
        {"id":"n1","type":"like","actors":[{"handle":"a","name":"A","rest_id":"9","verified":false,"avatar_url":"https://pbs.twimg.com/a.jpg"}],
         "target_tweet_id":"1","target_tweet_snippet":"hi","target_tweet_like_count":5,
         "target_media":[{"kind":"photo","url":"https://pbs.twimg.com/media/x.jpg","video_url":null,"alt_text":null,"width":1200,"height":675}],
         "timestamp":"2026-06-19T12:30:00Z"}
        """
        let notif = try decode(XNotification.self, json)
        #expect(notif.type == "like")
        #expect(notif.actors.first?.handle == "a")
        #expect(notif.actors.first?.avatarURL == "https://pbs.twimg.com/a.jpg")
        #expect(notif.targetTweetLikeCount == 5)
        #expect(notif.targetMedia.first?.kind == .photo)
        #expect(notif.thumbnailURL?.absoluteString == "https://pbs.twimg.com/media/x.jpg")
    }

    @Test("Compact count formatting")
    func counts() {
        #expect(Format.count(950) == "950")
        #expect(Format.count(1234) == "1.2K")
        #expect(Format.count(2_500_000) == "2.5M")
    }
}
