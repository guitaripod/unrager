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

    /// Entries older than this are still left on disk but not painted as a seed
    /// — very stale data shouldn't flash before the fresh fetch lands.
    public static let maxSeedAge: TimeInterval = 24 * 60 * 60

    private let directory: URL?
    private let queue = DispatchQueue(label: "cc.midgar.unrager.timelinecache", qos: .utility)

    private struct Entry: Codable {
        let savedAt: Date
        let tweets: [Tweet]
    }

    public init() {
        if let caches = try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("unrager/timeline", isDirectory: true) {
            try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
            directory = caches
        } else {
            directory = nil
        }
    }

    /// The most-recently-saved snapshot for `key`, paired with its age. Returns
    /// `nil` when absent, empty, undecodable, or older than `maxSeedAge` — every
    /// failure is silent so a bad cache never blocks the feed.
    public func load(key: String) -> (tweets: [Tweet], age: TimeInterval)? {
        guard let url = fileURL(for: key) else { return nil }
        return queue.sync {
            guard let data = try? Data(contentsOf: url) else { return nil }
            guard let entry = try? UnragerJSON.decoder.decode(Entry.self, from: data) else {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            let age = Date().timeIntervalSince(entry.savedAt)
            guard !entry.tweets.isEmpty, age <= Self.maxSeedAge else { return nil }
            return (entry.tweets, age)
        }
    }

    /// Overwrites the snapshot for `key` with the most recent `entryCap` tweets.
    /// An empty array clears the entry. Writes happen off-caller on a utility
    /// queue; failures are swallowed.
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
        }
    }

    /// Drops the snapshot for `key`. Used when a feed should forget its seed.
    public func clear(key: String) {
        guard let url = fileURL(for: key) else { return }
        queue.async { try? FileManager.default.removeItem(at: url) }
    }

    /// Maps an arbitrary cache key to a filesystem-safe `<sanitized>.json` URL so
    /// keys like `search-#foo/bar` can't escape the cache directory.
    private func fileURL(for key: String) -> URL? {
        guard let directory else { return nil }
        let safe = key.unicodeScalars.map { scalar -> Character in
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
            return allowed.contains(scalar) ? Character(scalar) : "_"
        }
        let name = String(safe).isEmpty ? "_" : String(safe)
        return directory.appendingPathComponent("\(name).json")
    }
}
