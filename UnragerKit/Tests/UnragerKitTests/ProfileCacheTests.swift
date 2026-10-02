import Foundation
import Testing
@testable import UnragerKit

@Suite("ProfileCache", .serialized)
struct ProfileCacheTests {
    private func makeUser(_ handle: String) throws -> User {
        let json = """
        {"rest_id":"1","handle":"\(handle)","name":"Name","verified":false,"followers":10,"following":2}
        """
        return try UnragerJSON.decode(User.self, from: Data(json.utf8))
    }

    private func makeCache(maxFiles: Int = 60) -> (ProfileCache, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("profile-cache-\(UUID().uuidString)", isDirectory: true)
        return (ProfileCache(directory: directory, maxFiles: maxFiles), directory)
    }

    @Test("A saved profile reads back, with its follow state")
    func roundTrip() async throws {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(await cache.load(handle: "noralind") == nil)
        cache.save(user: try makeUser("noralind"), followedByMe: true, handle: "noralind")
        let snapshot = await cache.load(handle: "NoraLind")
        #expect(snapshot?.user.handle == "noralind")
        #expect(snapshot?.followedByMe == true)
        #expect((snapshot?.age ?? 99) < 5)
    }

    @Test("Only the oldest beyond the cap are pruned")
    func prunes() async throws {
        let (cache, directory) = makeCache(maxFiles: 2)
        defer { try? FileManager.default.removeItem(at: directory) }
        for handle in ["a1", "b2", "c3"] {
            cache.save(user: try makeUser(handle), followedByMe: nil, handle: handle)
            await cache.flush()
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        await cache.flush()
        #expect(await cache.load(handle: "a1") == nil)
        #expect(await cache.load(handle: "c3") != nil)
    }

    @Test("A handle that could escape the directory is refused")
    func refusesOddHandles() async throws {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        cache.save(user: try makeUser("x"), followedByMe: nil, handle: "../etc")
        #expect(await cache.load(handle: "../etc") == nil)
        #expect(cache.fileURL(for: "a b") == nil)
    }

    @Test("Clearing a handle forgets it")
    func clears() async throws {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        cache.save(user: try makeUser("kit"), followedByMe: nil, handle: "kit")
        cache.clear(handle: "kit")
        #expect(await cache.load(handle: "kit") == nil)
    }
}
