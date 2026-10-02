import CoreGraphics
import Foundation
import ImageIO

/// A small on-disk tier under the pipeline's memory cache. It keeps what the
/// app actually draws, not what X served: one picture per address, downsampled
/// to the size it was last needed at and re-encoded, so a cold start reads a
/// few kilobytes and decodes them in a blink instead of fetching, or decoding,
/// the full-size original. An entry answers any request no bigger than it was
/// stored for, or any request at all once it holds the whole picture. A larger
/// need replaces it. The size on disk is capped and the least recently used go
/// first; nothing is written to a database, the file names carry everything.
public final class MediaDiskCache: @unchecked Sendable {
    public static let shared = MediaDiskCache()

    public static let defaultMaxBytes = 192 * 1024 * 1024
    public static let defaultMaxAge: TimeInterval = 21 * 24 * 60 * 60

    /// The smallest and largest size an entry is stored at, and the step
    /// between them, so pictures wanted at nearby sizes share one entry.
    static let step = 64
    static let largest = 4096

    private struct Entry {
        var file: String
        var bucket: Int
        var complete: Bool
        var bytes: Int
        var accessed: Date
    }

    private let directory: URL?
    private let maxBytes: Int
    private let maxAge: TimeInterval
    private let queue = DispatchQueue(label: "cc.midgar.unrager.mediacache", qos: .utility)
    private var index: [String: Entry] = [:]
    private var totalBytes = 0
    private var indexed = false
    private var writtenSinceTrim = 0

    public convenience init() {
        self.init(directory: Self.defaultDirectory(), maxBytes: Self.defaultMaxBytes, maxAge: Self.defaultMaxAge)
    }

    init(directory: URL?, maxBytes: Int, maxAge: TimeInterval) {
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        self.directory = directory
        self.maxBytes = max(1, maxBytes)
        self.maxAge = maxAge
    }

    private static func defaultDirectory() -> URL? {
        try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("unrager/media", isDirectory: true)
    }

    /// The size a picture wanted at `pixels` (its longest side) is stored at:
    /// the next step up, so a slightly larger ask later is still answered.
    public static func bucket(for pixels: CGFloat) -> Int {
        let wanted = Int(max(1, pixels).rounded(.up))
        return min(largest, max(step, (wanted + step - 1) / step * step))
    }

    /// The stored bytes for `url` when they are big enough for `pixels`, read
    /// off the caller's thread; nil when absent, too small or expired. A hit
    /// counts as a use.
    public func data(for url: URL, atLeast pixels: Int) async -> Data? {
        guard directory != nil else { return nil }
        return await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.read(key: Self.key(for: url), atLeast: pixels)) }
        }
    }

    /// Stores `image`, which was decoded for `bucket` (or is the whole picture
    /// when `complete`), replacing a smaller entry for `url`. Encoded and
    /// written off the caller's thread; failures are silent.
    public func store(_ image: CGImage, for url: URL, bucket: Int, complete: Bool) {
        guard directory != nil else { return }
        queue.async { self.write(image, key: Self.key(for: url), bucket: bucket, complete: complete) }
    }

    /// Whether storing a decode of `image` at `bucket` would add anything: an
    /// entry already big enough makes it pointless, so the caller skips the
    /// work of producing one.
    public func wants(_ url: URL, bucket: Int) async -> Bool {
        guard directory != nil else { return false }
        return await withCheckedContinuation { continuation in
            queue.async {
                self.buildIndexIfNeeded()
                guard let entry = self.index[Self.key(for: url)] else { return continuation.resume(returning: true) }
                continuation.resume(returning: !(entry.complete || entry.bucket >= bucket))
            }
        }
    }

    /// Bytes the stored pictures take on disk.
    public func diskUsage() async -> Int {
        await withCheckedContinuation { continuation in
            queue.async {
                self.buildIndexIfNeeded()
                continuation.resume(returning: self.totalBytes)
            }
        }
    }

    /// Forgets every stored picture.
    public func clear() {
        guard let directory else { return }
        queue.async {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in files { try? FileManager.default.removeItem(at: file) }
            self.index = [:]
            self.totalBytes = 0
            self.indexed = true
        }
    }

    /// Waits for every queued read, write and trim to finish.
    func flush() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    // MARK: - On the queue

    private func read(key: String, atLeast pixels: Int) -> Data? {
        buildIndexIfNeeded()
        guard let directory, var entry = index[key], entry.complete || entry.bucket >= pixels else { return nil }
        let file = directory.appendingPathComponent(entry.file)
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
            drop(key)
            return nil
        }
        entry.accessed = Date()
        index[key] = entry
        try? FileManager.default.setAttributes([.modificationDate: entry.accessed], ofItemAtPath: file.path)
        return data
    }

    private func write(_ image: CGImage, key: String, bucket: Int, complete: Bool) {
        buildIndexIfNeeded()
        guard let directory else { return }
        if let existing = index[key], existing.complete || existing.bucket >= bucket { return }
        let opaque = Self.isOpaque(image)
        guard let data = Self.encode(image, opaque: opaque) else { return }
        let file = "\(key).\(bucket).\(complete ? "c" : "p").\(opaque ? "jpg" : "png")"
        let destination = directory.appendingPathComponent(file)
        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            return
        }
        drop(key)
        index[key] = Entry(file: file, bucket: bucket, complete: complete, bytes: data.count, accessed: Date())
        totalBytes += data.count
        writtenSinceTrim += data.count
        if writtenSinceTrim >= 4 * 1024 * 1024 || totalBytes > maxBytes {
            writtenSinceTrim = 0
            trim()
        }
    }

    /// Removes the entry for `key` and its file.
    private func drop(_ key: String) {
        guard let directory, let entry = index.removeValue(forKey: key) else { return }
        totalBytes -= entry.bytes
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry.file))
    }

    /// Drops what has not been used within `maxAge`, then the least recently
    /// used until the cache is back to 85% of its cap.
    private func trim() {
        let cutoff = Date().addingTimeInterval(-maxAge)
        for (key, entry) in index where entry.accessed < cutoff { drop(key) }
        guard totalBytes > maxBytes else { return }
        let target = maxBytes * 85 / 100
        for (key, _) in index.sorted(by: { $0.value.accessed < $1.value.accessed }) {
            guard totalBytes > target else { break }
            drop(key)
        }
    }

    /// Learns what is on disk from the file names, once; a file whose name does
    /// not parse is removed.
    private func buildIndexIfNeeded() {
        guard !indexed else { return }
        indexed = true
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        for file in files {
            let parts = file.lastPathComponent.split(separator: ".").map(String.init)
            guard parts.count == 4, let bucket = Int(parts[1]), parts[2] == "c" || parts[2] == "p" else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let entry = Entry(file: file.lastPathComponent, bucket: bucket, complete: parts[2] == "c",
                              bytes: values?.fileSize ?? 0, accessed: values?.contentModificationDate ?? .distantPast)
            if index[parts[0]] != nil { drop(parts[0]) }
            index[parts[0]] = entry
            totalBytes += entry.bytes
        }
        trim()
    }

    // MARK: - Encoding

    /// A launch-stable short digest of the address, so the same picture is the
    /// same file in every run.
    static func key(for url: URL) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in url.absoluteString.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 36)
    }

    private static func isOpaque(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return true
        default: return false
        }
    }

    private static func encode(_ image: CGImage, opaque: Bool) -> Data? {
        let data = NSMutableData()
        let type = (opaque ? "public.jpeg" : "public.png") as CFString
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else { return nil }
        let options = [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
