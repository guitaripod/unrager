import Foundation

/// A display-only seed for profile headers, like `TimelineCache` is for
/// timelines: the last account details shown for each handle, so a profile
/// opens already drawn (name, bio, counts, banner) while the real request is
/// in flight. It never stands in for a fetch; the fresh account replaces it
/// and is saved over it. An entry past `maxSeedAge` is dropped, and the
/// directory is held to `maxFiles`, the most recently saved first.
public final class ProfileCache: Sendable {
    public static let shared = ProfileCache()

    public static let maxSeedAge: TimeInterval = 7 * 24 * 60 * 60
    static let defaultMaxFiles = 60

    private let directory: URL?
    private let maxFiles: Int
    private let queue = DispatchQueue(label: "cc.midgar.unrager.profilecache", qos: .utility)

    /// What a saved profile holds.
    public struct Snapshot: Sendable {
        public let user: User
        public let followedByMe: Bool?
        public let age: TimeInterval
    }

    private struct Entry: Codable {
        let savedAt: Date
        let user: User
        let followedByMe: Bool?
    }

    public convenience init() {
        self.init(directory: Self.defaultDirectory())
    }

    init(directory: URL?, maxFiles: Int = ProfileCache.defaultMaxFiles) {
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        self.directory = directory
        self.maxFiles = maxFiles
    }

    private static func defaultDirectory() -> URL? {
        try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("unrager/profile", isDirectory: true)
    }

    /// The saved account for `handle`, read and decoded off the caller's
    /// thread; nil when absent, undecodable or expired (those are deleted).
    public func load(handle: String) async -> Snapshot? {
        guard let url = fileURL(for: handle) else { return nil }
        return await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: Self.read(url)) }
        }
    }

    private static func read(_ url: URL) -> Snapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let entry = try? UnragerJSON.decoder.decode(Entry.self, from: data) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        let age = Date().timeIntervalSince(entry.savedAt)
        guard age <= maxSeedAge else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return Snapshot(user: entry.user, followedByMe: entry.followedByMe, age: age)
    }

    /// Saves `user` as the account shown for `handle`, then prunes.
    public func save(user: User, followedByMe: Bool?, handle: String) {
        guard let url = fileURL(for: handle) else { return }
        queue.async {
            let entry = Entry(savedAt: Date(), user: user, followedByMe: followedByMe)
            guard let data = try? UnragerJSON.encoder.encode(entry) else { return }
            try? data.write(to: url, options: .atomic)
            self.prune()
        }
    }

    public func clear(handle: String) {
        guard let url = fileURL(for: handle) else { return }
        queue.async { try? FileManager.default.removeItem(at: url) }
    }

    /// Forgets every saved profile.
    public func clearAll() {
        guard let directory else { return }
        queue.async {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
    }

    /// Waits for every queued write and prune to finish.
    func flush() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    private func prune() {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let dated = files.map { url in
            (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        .sorted { $0.1 > $1.1 }
        for (index, file) in dated.enumerated() where index >= maxFiles {
            try? FileManager.default.removeItem(at: file.0)
        }
    }

    /// `<handle>.json` for a handle's lowercase letters, digits and
    /// underscores, which is all X allows; anything else maps to nil.
    func fileURL(for handle: String) -> URL? {
        let name = handle.lowercased()
        guard let directory, !name.isEmpty,
              name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else { return nil }
        return directory.appendingPathComponent("\(name).json")
    }
}
