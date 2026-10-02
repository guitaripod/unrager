import CoreGraphics
import Foundation
import Testing
import UnragerKit
@testable import Unrager

@MainActor
@Suite("Profile media grid")
struct ProfileMediaGridTests {
    private func tweet(_ id: String, media: String, reply: Bool = false, repost: Bool = false) throws -> Tweet {
        let json = """
        {"rest_id":"\(id)","author":{"rest_id":"1","handle":"a","name":"A","verified":false,"followers":0,"following":0},
         "created_at":"2026-01-01T00:00:00Z","text":"t","reply_count":0,"retweet_count":0,"like_count":0,
         "quote_count":0,"bookmark_count":0,"favorited":false,"retweeted":false,"bookmarked":false,
         "media":[\(media)],"url":"https://x.com/a/status/\(id)","urls":[]
         \(reply ? #","in_reply_to_tweet_id":"9""# : "")
         \(repost ? #","retweeted_by":{"rest_id":"2","handle":"b","name":"B","verified":false,"followers":0,"following":0}"# : "")}
        """
        return try UnragerJSON.decode(Tweet.self, from: Data(json.utf8))
    }

    private let photo = #"{"kind":"photo","url":"https://pbs.twimg.com/media/a.jpg","width":1200,"height":800}"#
    private let clip = #"{"kind":"video","url":"https://pbs.twimg.com/media/p.jpg","video_url":"https://video.twimg.com/v.mp4","width":720,"height":1280}"#
    private let card = #"{"kind":{"link_card":{"title":"t","description":"d","domain":"x.com","target_url":"https://x.com"}},"url":"https://pbs.twimg.com/c.jpg"}"#

    @Test("Pictures and clip posters of the account's own posts are listed, other things are not")
    func items() throws {
        let tweets = [
            try tweet("1", media: "\(photo),\(clip)"),
            try tweet("2", media: photo, reply: true),
            try tweet("3", media: photo, repost: true),
            try tweet("4", media: card),
            try tweet("5", media: photo),
        ]
        let items = ProfileMediaGrid.items(from: tweets)
        #expect(items.map(\.id) == ["1#0", "1#1", "5#0"])
        #expect(items[1].isVideo && !items[0].isVideo)
        #expect(items[0].url.absoluteString == "https://pbs.twimg.com/media/a.jpg?name=small")
        #expect(items[0].ratio == 1.5)
    }

    @Test("A justified row's pictures fill its width exactly")
    func rowsFillTheWidth() {
        let ratios: [CGFloat?] = [1.5, 0.75, 1.0, 1.78, 0.56, 1.33, 1.0, 2.0, 0.8, 1.2]
        let width: CGFloat = 390
        let rows = ProfileMediaGrid.rows(ratios: ratios, width: width)
        #expect(rows.map(\.range.count).reduce(0, +) == ratios.count)
        for row in rows.dropLast() {
            let total = row.widths.reduce(0, +) + ProfileMediaGrid.gutter * CGFloat(row.widths.count - 1)
            #expect(abs(total - width) < 0.001)
            #expect(row.widths.count <= ProfileMediaGrid.maxPerRow)
        }
    }

    @Test("Each picture keeps its own shape in a justified row")
    func shapesKept() {
        let rows = ProfileMediaGrid.rows(ratios: [1.5, 0.75, 1.0], width: 390)
        let row = rows[0]
        let ratios: [CGFloat] = [1.5, 0.75, 1.0]
        for (index, width) in row.widths.enumerated() where index < row.widths.count - 1 {
            #expect(abs(width / row.height - ratios[index]) < 0.001)
        }
    }

    @Test("A short last row keeps the target height rather than stretching tall")
    func lastRowNotStretched() {
        let rows = ProfileMediaGrid.rows(ratios: [1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 0.8], width: 390)
        let last = rows.last!
        #expect(last.height <= ProfileMediaGrid.targetHeight * ProfileMediaGrid.lastRowStretchLimit + 0.001)
        #expect(last.range.upperBound == 10)
    }

    @Test("Extreme shapes are held to the limits and unknown ones are square")
    func layoutRatios() {
        #expect(ProfileMediaGrid.layoutRatio(nil) == 1)
        #expect(ProfileMediaGrid.layoutRatio(0.1) == MediaShape.tallestInGroup)
        #expect(ProfileMediaGrid.layoutRatio(8) == MediaShape.widestInGroup)
        #expect(ProfileMediaGrid.layoutRatio(1.3) == 1.3)
    }

    @Test("Nothing in, no rows out")
    func empty() {
        #expect(ProfileMediaGrid.rows(ratios: [], width: 390).isEmpty)
        #expect(ProfileMediaGrid.rows(ratios: [1], width: 0).isEmpty)
    }
}
