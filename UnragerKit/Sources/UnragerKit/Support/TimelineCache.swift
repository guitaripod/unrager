import Foundation

/// A display-only seed for timelines: persists a small snapshot of the most
/// recent tweets per feed so a feed can paint instantly on launch instead of
/// showing an empty/loading state.
///
/// This is never the source of truth. Callers paint the cached tweets while the
/// real network fetch is in flight, then replace them wholesale with the fresh
/// result (and overwrite the cache). The cache never short-circuits a fetch and
/// never dedupes fresh content against itself, so new tweets can't be
/// suppressed. A corrupt or undecodable entry is ignored, never fatal.
public final class TimelineCache: Sendable {
    public static let shared = TimelineCache()

    /// Most recent tweets retained per key. Enough to fill a screen on launch
    /// without bloating the on-disk snapshot.
    private static let entryCap = 40

    /// Entries older than this are not painted as a seed (very stale data
    /// shouldn't flash before the fresh fetch lands) and are deleted.
    public static let maxSeedAge: TimeInterval = 24 * 60 * 60

    /// Saved timelines kept on disk, the most recently written first. Every
    /// profile visited and every search gets its own file, so without a cap
    /// the directory only grows.
    static let defaultMaxFiles = 50

    private let directory: URL?
    private let maxFiles: Int
    private let queue = DispatchQueue(label: "cc.midgar.unrager.timelinecache", qos: .utility)

    private struct Entry: Codable {
        let savedAt: Date
        let tweets: [Tweet]
    }

    public convenience init() {
        self.init(directory: Self.defaultDirectory())
    }

    init(directory: URL?, maxFiles: Int = TimelineCache.defaultMaxFiles) {
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        self.directory = directory
        self.maxFiles = maxFiles
    }

    private static func defaultDirectory() -> URL? {
        try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("unrager/timeline", isDirectory: true)
    }

    /// The most-recently-saved snapshot for `key`, paired with its age, read and
    /// decoded off the caller's thread. Returns `nil` when absent, empty,
    /// undecodable, or older than `maxSeedAge` (an undecodable or expired file
    /// is deleted); every failure is silent so a bad cache never blocks the
    /// feed.
    public func load(key: String) async -> (tweets: [Tweet], age: TimeInterval)? {
        guard let url = fileURL(for: key) else { return nil }
        return await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: Self.read(url)) }
        }
    }

    private static func read(_ url: URL) -> (tweets: [Tweet], age: TimeInterval)? {
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
        guard !entry.tweets.isEmpty else { return nil }
        return (entry.tweets, age)
    }

    /// Overwrites the snapshot for `key` with the most recent `entryCap` tweets,
    /// then prunes the directory. An empty array clears the entry. Writes happen
    /// off-caller on a utility queue; failures are swallowed.
    public func save(_ tweets: [Tweet], key: String) {
        guard let url = fileURL(for: key) else { return }
        let capped = Array(tweets.prefix(Self.entryCap))
        queue.async {
            guard !capped.isEmpty else {
                try? FileManager.default.removeItem(at: url)
                return
            }
            let entry = Entry(savedAt: Date(), tweets: capped)
            guard let data = try? UnragerJSON.encoder.encode(entry) else { return }
            try? data.write(to: url, options: .atomic)
            self.prune()
        }
    }

    /// Deletes saved timelines older than `maxSeedAge`, then the least recently
    /// written beyond `maxFiles`. Runs on `queue`.
    private func prune() {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-Self.maxSeedAge)
        let dated = files.map { url in
            (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        .sorted { $0.1 > $1.1 }
        for (index, file) in dated.enumerated() where index >= maxFiles || file.1 < cutoff {
            try? FileManager.default.removeItem(at: file.0)
        }
    }

    /// Waits for every queued write and prune to finish.
    func flush() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    /// Drops the snapshot for `key`. Used when a feed should forget its seed.
    public func clear(key: String) {
        guard let url = fileURL(for: key) else { return }
        queue.async { try? FileManager.default.removeItem(at: url) }
    }

    /// How many bytes the saved timelines take on disk.
    public func diskUsage() -> Int {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return queue.sync {
            files.reduce(0) { total, url in
                total + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
    }

    /// Forgets every saved timeline; feeds paint empty until the next fetch.
    public func clearAll() {
        guard let directory else { return }
        queue.async {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for url in files { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// Maps an arbitrary cache key to a filesystem-safe `<sanitized>.json` URL so
    /// keys like `search-#foo/bar` can't escape the cache directory.
    func fileURL(for key: String) -> URL? {
        guard let directory else { return nil }
        let safe = key.unicodeScalars.map { scalar -> Character in
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
            return allowed.contains(scalar) ? Character(scalar) : "_"
        }
        let name = String(safe).isEmpty ? "_" : String(safe)
        return directory.appendingPathComponent("\(name)-\(stableHash(key)).json")
    }

    /// A deterministic (launch-stable, unlike `Hashable`) short digest of the
    /// full key so two keys that sanitize to the same filename — e.g. the
    /// synthetic `user-jack/replies` and a real handle `jack_replies` — never
    /// collide on disk.
    private func stableHash(_ key: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in key.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return String(hash, radix: 36)
    }
}
