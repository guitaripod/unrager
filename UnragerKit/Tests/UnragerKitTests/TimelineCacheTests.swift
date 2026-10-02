import Foundation
import Testing
@testable import UnragerKit

@Suite("Timeline cache")
struct TimelineCacheTests {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("timeline-cache-\(UUID().uuidString)", isDirectory: true)

    private func tweet(_ id: String) -> Tweet {
        let json = """
        {"rest_id":"\(id)","author":{"rest_id":"1","handle":"a","name":"A","verified":false,
          "followers":0,"following":0},"created_at":"2026-06-19T12:00:00Z","text":"t\(id)",
          "reply_count":0,"retweet_count":0,"like_count":0,"quote_count":0,"view_count":null,
          "url":"https://x.com/a/status/\(id)"}
        """
        return try! UnragerJSON.decode(Tweet.self, from: Data(json.utf8))
    }

    private func files() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    }

    private func backdate(_ url: URL, by seconds: TimeInterval) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-seconds)], ofItemAtPath: url.path)
    }

    @Test("A save seeds the next load, a newer save replaces it, an empty save clears it")
    func seedsAndRevalidates() async {
        let cache = TimelineCache(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(await cache.load(key: "home") == nil)

        cache.save([tweet("1"), tweet("2")], key: "home")
        let loaded = await cache.load(key: "home")
        #expect(loaded?.tweets.map(\.restID) == ["1", "2"])
        #expect((loaded?.age ?? .greatestFiniteMagnitude) < 60)

        cache.save([tweet("3"), tweet("1")], key: "home")
        #expect(await cache.load(key: "home")?.tweets.map(\.restID) == ["3", "1"])

        cache.save([], key: "home")
        #expect(await cache.load(key: "home") == nil)
    }

    @Test("A corrupt or expired file is deleted on load")
    func dropsBadFiles() async throws {
        let cache = TimelineCache(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let corrupt = try #require(cache.fileURL(for: "corrupt"))
        try Data("nope".utf8).write(to: corrupt)
        #expect(await cache.load(key: "corrupt") == nil)
        #expect(!FileManager.default.fileExists(atPath: corrupt.path))

        let stale = try #require(cache.fileURL(for: "stale"))
        let old = Date().addingTimeInterval(-TimelineCache.maxSeedAge - 60)
        let json = #"{"savedAt":"\#(old.ISO8601Format())","tweets":[]}"#
        try Data(json.utf8).write(to: stale)
        #expect(await cache.load(key: "stale") == nil)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }

    @Test("Saving prunes expired files and caps the directory, oldest first")
    func prunes() async throws {
        let cache = TimelineCache(directory: directory, maxFiles: 3)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (index, key) in ["a", "b", "c", "d"].enumerated() {
            cache.save([tweet("\(index)")], key: key)
            await cache.flush()
            try backdate(try #require(cache.fileURL(for: key)), by: Double(10 - index) * 60)
        }
        await cache.flush()
        #expect(files().count == 3)
        #expect(await cache.load(key: "a") == nil)

        let expired = try #require(cache.fileURL(for: "b"))
        try backdate(expired, by: TimelineCache.maxSeedAge + 60)
        cache.save([tweet("9")], key: "e")
        await cache.flush()
        #expect(!FileManager.default.fileExists(atPath: expired.path))
        #expect(Set(files().map(\.lastPathComponent)) == Set(try ["c", "d", "e"].map {
            try #require(cache.fileURL(for: $0)).lastPathComponent
        }))
    }

    @Test("Keys that sanitize to the same name keep separate files")
    func keysDoNotCollide() async throws {
        let cache = TimelineCache(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(cache.fileURL(for: "user-jack/replies") != cache.fileURL(for: "user-jack_replies"))
        cache.save([tweet("1")], key: "user-jack/replies")
        cache.save([tweet("2")], key: "user-jack_replies")
        #expect(await cache.load(key: "user-jack/replies")?.tweets.map(\.restID) == ["1"])
        #expect(await cache.load(key: "user-jack_replies")?.tweets.map(\.restID) == ["2"])
    }
}
