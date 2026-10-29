import Foundation
import Testing
import UnragerKit
@testable import Unrager

@MainActor
@Suite("Paged people lists")
struct PagedUserListTests {
    /// A list whose pages are scripted per query, each answered after a delay.
    private final class ScriptedList: PagedUserListViewController {
        var query = "old"
        var replies: [String: (delay: Duration, result: Result<Page, Error>)] = [:]
        var requestedCursors: [String?] = []

        override func fetchPage(cursor: String?) async throws -> Page {
            requestedCursors.append(cursor)
            let key = cursor.map { "\(query)+\($0)" } ?? query
            guard let reply = replies[key] else { throw URLError(.badServerResponse) }
            try? await Task.sleep(for: reply.delay)
            return try reply.result.get()
        }
    }

    private static func user(_ id: String) throws -> User {
        let json = #"{"rest_id":"\#(id)","handle":"u\#(id)","name":"User \#(id)","verified":false,"followers":0,"following":0}"#
        return try UnragerJSON.decode(User.self, from: Data(json.utf8))
    }

    private static func settle(_ milliseconds: Int = 400) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }

    @Test("A new query drops the old query's late answer instead of showing or appending it")
    func staleQueryIsDropped() async throws {
        let list = ScriptedList()
        list.replies["old"] = (.milliseconds(250), .success(.init(users: [try Self.user("1")], cursor: nil)))
        list.replies["new"] = (.milliseconds(10), .success(.init(users: [try Self.user("2")], cursor: nil)))
        list.loadViewIfNeeded()
        list.query = "new"
        list.restart()
        await Self.settle()
        #expect(list.order == ["2"])
    }

    @Test("A failed refresh keeps the rows and the cursor, so the next page still follows them")
    func failedRefreshKeepsPaging() async throws {
        let list = ScriptedList()
        list.replies["old"] = (.zero, .success(.init(users: [try Self.user("1")], cursor: "c1")))
        list.loadViewIfNeeded()
        await Self.settle(150)
        #expect(list.order == ["1"])

        list.replies["old"] = (.zero, .failure(URLError(.notConnectedToInternet)))
        list.restartFromPull()
        await Self.settle(150)
        #expect(list.order == ["1"])

        list.replies["old+c1"] = (.zero, .success(.init(users: [try Self.user("3")], cursor: nil)))
        list.loadNextPage()
        await Self.settle(150)
        #expect(list.requestedCursors.last == "c1")
        #expect(list.order == ["1", "3"])
    }

    /// A list with one extra lens, "followers", over people whose `follows_me` is scripted.
    private final class LensedList: PagedUserListViewController {
        var pages: [String?: Page] = [:]
        var requestedCursors: [String?] = []

        override var supportsLens: Bool { true }
        override var lensChips: [LensChip] {
            [LensChip(id: "all", title: "All", count: order.count, tint: .systemBlue),
             LensChip(id: "followers", title: "Followers", count: nil, tint: .systemBlue)]
        }
        override func includes(_ row: UserRow, lens: String) -> Bool { lens == "all" || row.followsMe == true }

        override func fetchPage(cursor: String?) async throws -> Page {
            requestedCursors.append(cursor)
            guard let page = pages[cursor] else { throw URLError(.badServerResponse) }
            return page
        }
    }

    private static func person(_ id: String, followsMe: Bool) throws -> User {
        let json = #"{"rest_id":"\#(id)","handle":"u\#(id)","name":"User \#(id)","verified":false,"followers":0,"following":0,"followed_by_me":false,"follows_me":\#(followsMe)}"#
        return try UnragerJSON.decode(User.self, from: Data(json.utf8))
    }

    @Test("A lens keeps fetching pages while it leaves few people, then shows only its people")
    func lensLoadsUntilItFills() async throws {
        let list = LensedList()
        list.pages[nil] = .init(users: [try Self.person("1", followsMe: false), try Self.person("2", followsMe: true)], cursor: "c1")
        list.pages["c1"] = .init(users: [try Self.person("3", followsMe: false), try Self.person("4", followsMe: true)], cursor: nil)
        list.loadViewIfNeeded()
        await Self.settle(150)
        #expect(list.shownIDs == ["1", "2"])

        list.selectLens("followers")
        await Self.settle(300)
        #expect(list.requestedCursors == [nil, "c1"])
        #expect(list.shownIDs == ["2", "4"])

        list.selectLens("all")
        #expect(list.shownIDs == ["1", "2", "3", "4"])
    }

    @Test("A refresh keeps the chosen lens and applies it to the fresh people")
    func lensSurvivesRefresh() async throws {
        let list = LensedList()
        list.pages[nil] = .init(users: [try Self.person("1", followsMe: false), try Self.person("2", followsMe: true)], cursor: nil)
        list.loadViewIfNeeded()
        await Self.settle(150)
        list.selectLens("followers")
        #expect(list.shownIDs == ["2"])

        list.pages[nil] = .init(users: [try Self.person("5", followsMe: true), try Self.person("6", followsMe: false)], cursor: nil)
        list.restartFromPull()
        await Self.settle(200)
        #expect(list.shownIDs == ["5"])
    }
}
