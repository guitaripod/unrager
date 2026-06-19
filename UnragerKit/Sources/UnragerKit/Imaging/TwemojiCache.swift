import Foundation
import ImageIO
import CoreGraphics

/// Twemoji emoji-image cache for the native clients, porting the TUI's
/// `emoji_cache.rs` so the apps render the same flat Twemoji art (most visibly
/// X's flat country flags) instead of Apple's system color-emoji glyphs.
///
/// Emoji art is **Twemoji** (graphics licensed CC-BY 4.0, © Twitter / the
/// `jdecked/twemoji` maintainers). The original `twitter/twemoji` repo is frozen
/// at Emoji 14.0, so assets come from the maintained `jdecked/twemoji` fork; the
/// version is *resolved at runtime* once per process (resolve-then-pin) and all
/// asset URLs are built against that immutable tag, so a new emoji renders
/// against the same binary the moment the fork ships it. On a resolve failure
/// (offline) the pinned ``TwemojiCache/fallbackVersion`` is used.
///
/// ## Hot-path discipline
///
/// The feed builds attributed bodies synchronously on the main thread during
/// cell configuration, which must never block on the network. The hot path uses
/// only ``cachedImage(for:)`` — a lock-guarded in-memory lookup, no I/O — so a
/// cache miss simply leaves the native glyph in place. ``image(for:)`` is the
/// async fetch+cache path (disk → network), used by ``prewarm(graphemesIn:)``
/// during prefetch and by render-once surfaces (the postcard) that can `await`.
///
/// ## Rate-limit safety
///
/// The Twemoji version resolves at most once per process. Concurrent fetches for
/// the same stem dedupe onto a single in-flight `Task`, so N tweets sharing an
/// emoji issue one request, not N. Stems that 404 against the pinned version are
/// remembered for the process so they aren't re-probed on every tweet.
public actor TwemojiCache {
    public static let shared = TwemojiCache()

    /// Maintained Twemoji fork. The original `twitter/twemoji` is frozen at
    /// Emoji 14.0; this fork tracks the latest Unicode emoji release.
    public static let repo = "https://cdn.jsdelivr.net/gh/jdecked/twemoji"
    /// Used when the runtime version resolve fails (offline / CDN unreachable).
    /// Bump alongside a new Emoji release.
    public static let fallbackVersion = "17.0.3"
    /// jsDelivr data API that resolves the `latest` specifier to a concrete,
    /// immutable version. No GitHub-style rate limit; CORS-open; ~300s cached.
    public static let resolveURL =
        "https://data.jsdelivr.com/v1/packages/gh/jdecked/twemoji/resolved?specifier=latest"

    /// Posted (on the main queue) after a batch of previously-missing emoji
    /// images finish downloading, so a feed can re-render the affected rows off
    /// the scroll path. Coalesced: at most one notification per run-loop tick.
    public static let imagesDidLoad = Notification.Name("cc.midgar.unrager.twemojiImagesDidLoad")

    private let memory = TwemojiMemoryCache()
    private let session: URLSession
    private let directory: URL?

    private var resolvedBase: String?
    private var inFlight: [String: Task<CGImage?, Never>] = [:]
    private var knownMissing: Set<String> = []

    public init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 5
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: configuration)

        let caches = try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = caches?.appendingPathComponent("unrager/emoji", isDirectory: true)
        if let dir {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        directory = dir
    }

    // MARK: - Synchronous hot path

    /// A memory-resident Twemoji image for `grapheme`, or `nil` on a miss.
    /// Never touches disk or network — safe to call on the main thread during
    /// cell configuration. A miss means "leave the native glyph"; call
    /// ``image(for:)`` (off the scroll path) to populate the cache.
    public nonisolated func cachedImage(for grapheme: String) -> CGImage? {
        guard Self.isEmoji(grapheme) else { return nil }
        return memory.image(forStem: Self.twemojiStem(for: grapheme))
    }

    // MARK: - Async fetch path

    /// A Twemoji image for `grapheme`, fetching from the disk cache then the
    /// jsDelivr CDN on a miss and populating the memory cache. Returns `nil` for
    /// non-emoji input or when the asset can't be retrieved (offline / 404).
    /// Safe to `await` — used by the postcard (renders once) and by prewarming.
    public func image(for grapheme: String) async -> CGImage? {
        guard Self.isEmoji(grapheme) else { return nil }
        let stem = Self.twemojiStem(for: grapheme)
        if let hit = memory.image(forStem: stem) { return hit }
        return await loadStem(stem)
    }

    /// Fetches every emoji in `text` that isn't already cached, populating disk
    /// and memory so a later synchronous ``cachedImage(for:)`` hits. Call during
    /// feed prefetch; fetches run concurrently and post ``imagesDidLoad`` when a
    /// batch lands so visible rows can re-render.
    public func prewarm(graphemesIn text: String) {
        var pending: Set<String> = []
        for grapheme in text.emojiGraphemes() {
            let stem = Self.twemojiStem(for: grapheme)
            if memory.image(forStem: stem) == nil { pending.insert(stem) }
        }
        guard !pending.isEmpty else { return }
        Task {
            var loadedAny = false
            await withTaskGroup(of: Bool.self) { group in
                for stem in pending {
                    group.addTask { await self.loadStem(stem) != nil }
                }
                for await landed in group where landed { loadedAny = true }
            }
            if loadedAny { Self.postImagesDidLoad() }
        }
    }

    private func loadStem(_ stem: String) async -> CGImage? {
        if let hit = memory.image(forStem: stem) { return hit }
        if knownMissing.contains(stem) { return nil }
        if let task = inFlight[stem] { return await task.value }

        let task = Task<CGImage?, Never> { [self] in
            await fetchStem(stem)
        }
        inFlight[stem] = task
        let result = await task.value
        inFlight[stem] = nil
        if let result {
            memory.set(result, forStem: stem)
        } else {
            knownMissing.insert(stem)
        }
        return result
    }

    private func fetchStem(_ stem: String) async -> CGImage? {
        if let data = diskData(for: stem), let image = Self.decode(data) {
            return image
        }
        let base = await assetBase()
        guard let url = URL(string: "\(base)/\(stem).png") else { return nil }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let image = Self.decode(data) else {
            return nil
        }
        writeDisk(data, for: stem)
        return image
    }

    /// Builds the `assets/72x72` base URL against the resolved-once version.
    private func assetBase() async -> String {
        if let resolvedBase { return resolvedBase }
        let version = await resolveVersion()
        let base = "\(Self.repo)@\(version)/assets/72x72"
        resolvedBase = base
        return base
    }

    private func resolveVersion() async -> String {
        guard let url = URL(string: Self.resolveURL),
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? String else {
            AppLogger.shared.info("twemoji: using fallback version \(Self.fallbackVersion)", category: .media)
            return Self.fallbackVersion
        }
        AppLogger.shared.info("twemoji: resolved latest version \(version)", category: .media)
        return version
    }

    // MARK: - Disk

    private func diskData(for stem: String) -> Data? {
        guard let url = directory?.appendingPathComponent("\(stem).png") else { return nil }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return data
    }

    private func writeDisk(_ data: Data, for stem: String) {
        guard let url = directory?.appendingPathComponent("\(stem).png") else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func postImagesDidLoad() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.imagesDidLoad, object: nil)
        }
    }

    nonisolated static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options = [
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary
        return CGImageSourceCreateImageAtIndex(source, 0, options)
    }
}
