import Foundation
import Testing
import UIKit
import UnragerKit
@testable import Unrager

@MainActor
@Suite("Liker standings")
struct LikerRelationshipTests {
    private static func user(_ id: String, following: Bool?, followsMe: Bool?, verified: Bool = false) throws -> User {
        var fields = ["\"rest_id\":\"\(id)\"", "\"handle\":\"u\(id)\"", "\"name\":\"User \(id)\"",
                      "\"verified\":\(verified)", "\"followers\":1200", "\"following\":3"]
        if let following { fields.append("\"followed_by_me\":\(following)") }
        if let followsMe { fields.append("\"follows_me\":\(followsMe)") }
        return try UnragerJSON.decode(User.self, from: Data(("{" + fields.joined(separator: ",") + "}").utf8))
    }

    private static func row(_ id: String, following: Bool?, followsMe: Bool?, verified: Bool = false) throws -> UserRow {
        UserRow(try user(id, following: following, followsMe: followsMe, verified: verified))
    }

    private static func crowd() throws -> [UserRow] {
        [
            try row("1", following: true, followsMe: true),
            try row("2", following: false, followsMe: true, verified: true),
            try row("3", following: false, followsMe: true),
            try row("4", following: true, followsMe: false),
            try row("5", following: false, followsMe: false, verified: true),
            try row("6", following: false, followsMe: nil),
        ]
    }

    @Test("A standing needs both directions, and half a fact is not shown")
    func standingNeedsBoth() {
        #expect(Standing(following: true, followsMe: true) == .mutual)
        #expect(Standing(following: false, followsMe: true) == .followsYou)
        #expect(Standing(following: true, followsMe: false) == .youFollow)
        #expect(Standing(following: false, followsMe: false) == .stranger)
        #expect(Standing(following: true, followsMe: nil) == nil)
        #expect(Standing(following: nil, followsMe: true) == nil)
    }

    @Test("Only followers get a ring and a phrase")
    func ringsAreForFollowers() {
        #expect(Standing.mutual.drawsRing && Standing.mutual.phrase == "Mutual")
        #expect(Standing.followsYou.drawsRing && Standing.followsYou.phrase == "Follows you")
        #expect(!Standing.youFollow.drawsRing && Standing.youFollow.phrase == nil)
        #expect(!Standing.stranger.drawsRing && Standing.stranger.phrase == nil)
    }

    @Test("A follower not followed back is offered Follow back, everyone else Follow or Following")
    func followTitles() throws {
        #expect(try Self.row("1", following: false, followsMe: true).followTitle == "Follow back")
        #expect(try Self.row("2", following: true, followsMe: true).followTitle == "Following")
        #expect(try Self.row("3", following: false, followsMe: false).followTitle == "Follow")
        #expect(try Self.row("4", following: false, followsMe: nil).followTitle == "Follow")
    }

    @Test("The tally counts each standing, the verified, and people the list doesn't place")
    func tally() throws {
        let tally = LikerTally(try Self.crowd())
        #expect(tally.mutual == 1 && tally.followsYou == 2 && tally.youFollow == 1 && tally.strangers == 1)
        #expect(tally.unplaced == 1 && tally.verified == 2)
        #expect(tally.listed == 6 && tally.placed == 5)
        #expect(tally.followers == 3 && tally.followed == 2)
        #expect(tally.hasStandings)
    }

    @Test("A list from an older server places nobody")
    func olderServer() throws {
        let tally = LikerTally([try Self.row("1", following: true, followsMe: nil), try Self.row("2", following: false, followsMe: nil)])
        #expect(!tally.hasStandings)
        #expect(tally.unplaced == 2)
    }

    @Test("Each lens includes exactly the rows its count says")
    func lensesMatchTheirCounts() throws {
        let rows = try Self.crowd()
        let tally = LikerTally(rows)
        for lens in LikerLens.allCases {
            #expect(rows.filter(lens.includes).count == lens.count(in: tally), "\(lens)")
        }
        #expect(rows.filter(LikerLens.followBack.includes).map(\.id) == ["2", "3"])
        #expect(rows.filter(LikerLens.followers.includes).map(\.id) == ["1", "2", "3"])
        #expect(rows.filter(LikerLens.followed.includes).map(\.id) == ["1", "4"])
        #expect(rows.filter(LikerLens.verified.includes).map(\.id) == ["2", "5"])
    }

    @Test("The summary names its scope, and lenses are offered from six people")
    func summary() throws {
        let rows = try Self.crowd()
        let partial = LikersSummary(likeCount: 1_284, rows: rows, loading: false)
        #expect(partial.scope == "Among the 6 of \(1_284.formatted()) X lists")
        #expect(partial.offersLenses)
        let whole = LikersSummary(likeCount: 6, rows: rows, loading: false)
        #expect(whole.scope == "Everyone who liked this")
        let few = LikersSummary(likeCount: 3, rows: Array(rows.prefix(3)), loading: false)
        #expect(!few.offersLenses)
        #expect(LikersSummary(likeCount: 9, rows: [], loading: true).scope == "Loading the people who liked this…")
        #expect(LikersSummary(likeCount: 0, rows: [], loading: false).scope == "Nobody to show yet.")
        #expect(LikersSummary.likesTitle(1) == "1 like")
        #expect(LikersSummary.likesTitle(14_800) == "\(14_800.formatted()) likes")
    }

    @Test("Only followers not followed back wear faces, at most four")
    func faces() throws {
        let followers = try (1...6).map { try Self.row("\($0)", following: false, followsMe: true) }
        let summary = LikersSummary(likeCount: 6, rows: followers + [try Self.row("9", following: true, followsMe: true)], loading: false)
        #expect(summary.followBackFaces.map(\.id) == ["1", "2", "3", "4"])
    }

    @Test("A lens that leaves nobody says so among the people X lists")
    func emptyNotes() {
        #expect(LikerLens.followBack.emptyNote(listed: 40) == "You follow back everyone among the 40 people X lists who follows you.")
        #expect(LikerLens.verified.emptyNote(listed: 40) == "No verified accounts among the 40 people X lists.")
    }

    private static func post(media: [String]) throws -> Tweet {
        let json = """
        {"rest_id":"1","author":{"rest_id":"2","handle":"ada","name":"Ada","verified":false,
          "followers":0,"following":0},"created_at":"2026-06-19T12:00:00Z","text":"hi",
          "reply_count":0,"retweet_count":0,"like_count":0,"quote_count":0,"bookmark_count":0,
          "url":"https://x.com/ada/status/1","media":[\(media.joined(separator: ","))]}
        """
        return try UnragerJSON.decode(Tweet.self, from: Data(json.utf8))
    }

    private static func photo(_ width: Int, _ height: Int) -> String {
        #"{"kind":"photo","url":"https://example.com/p.jpg","width":\#(width),"height":\#(height)}"#
    }

    @Test("A wide picture keeps the card's width, a tall one narrows so the card stays short, and none is cropped")
    func mediaWidthKeepsShapeAndHeight() throws {
        let panorama = try Self.post(media: [Self.photo(2400, 1000)])
        #expect(LikedPostCardView.mediaWidth(for: panorama, contentWidth: 330) == 330)
        let landscape = try Self.post(media: [Self.photo(1600, 900)])
        let shortened = LikedPostCardView.mediaWidth(for: landscape, contentWidth: 330)
        #expect(shortened < 330)
        #expect(abs(shortened / (16.0 / 9.0) - LikedPostCardView.mediaHeight) <= 1)
        let tall = try Self.post(media: [Self.photo(900, 1200)])
        let narrowed = LikedPostCardView.mediaWidth(for: tall, contentWidth: 330)
        #expect(narrowed < 330)
        #expect(narrowed / 0.75 <= LikedPostCardView.mediaHeight + 1)
        let none = try Self.post(media: [])
        #expect(LikedPostCardView.mediaWidth(for: none, contentWidth: 330) == 330)
    }

    @Test("The card counts what isn't a like, drops zeros, and puts them beside a narrowed picture")
    func cardCounts() throws {
        let json = """
        {"rest_id":"1","author":{"rest_id":"2","handle":"ada","name":"Ada","verified":false,
          "followers":0,"following":0},"created_at":"2026-06-19T12:00:00Z","text":"hi",
          "reply_count":4,"retweet_count":0,"like_count":90,"quote_count":2,"view_count":1200,
          "bookmark_count":7,"url":"https://x.com/ada/status/1"}
        """
        let tweet = try UnragerJSON.decode(Tweet.self, from: Data(json.utf8))
        #expect(LikedPostCardView.entries(for: tweet).map(\.noun) == ["replies", "quotes", "views"])
        #expect(LikedPostCardView.statsFitBeside(mediaWidth: 150, contentWidth: 330))
        #expect(!LikedPostCardView.statsFitBeside(mediaWidth: 330, contentWidth: 330))
    }
}
