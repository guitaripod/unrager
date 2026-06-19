import Foundation
import os

public enum LogCategory: String, Sendable, CaseIterable {
    case app, api, timeline, thread, profile, compose, media, settings, ui
}

public enum LogLevel: String, Sendable {
    case debug, info, warn, error
}

/// File-based logger, day one. Fans every call to OSLog AND an append-only,
/// size-rotated file at `Library/Logs/unrager.log` (writes serialized on a
/// utility queue) so an agent can retrieve diagnostics from the app sandbox
/// without attaching a debugger. Cross-platform; shared by both apps.
public final class AppLogger: Sendable {
    public static let shared = AppLogger()

    private let loggers: [LogCategory: Logger]
    private let fileQueue = DispatchQueue(label: "cc.midgar.unrager.logger.file", qos: .utility)
    private let fileURL: URL?
    private let previousURL: URL?
    private let maxBytes = 2 * 1024 * 1024

    private init() {
        let subsystem = Bundle.main.bundleIdentifier ?? "cc.midgar.unrager"
        var built: [LogCategory: Logger] = [:]
        for category in LogCategory.allCases {
            built[category] = Logger(subsystem: subsystem, category: category.rawValue)
        }
        loggers = built

        if let logs = try? FileManager.default.url(
            for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("Logs", isDirectory: true) {
            try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            fileURL = logs.appendingPathComponent("unrager.log")
            previousURL = logs.appendingPathComponent("unrager.previous.log")
        } else {
            fileURL = nil
            previousURL = nil
        }
    }

    public var currentLogFileURL: URL? { fileURL }

    public func log(_ level: LogLevel, _ message: @autoclosure () -> String, category: LogCategory) {
        let text = message()
        let logger = loggers[category] ?? Logger()
        switch level {
        case .debug: logger.debug("\(text, privacy: .public)")
        case .info: logger.info("\(text, privacy: .public)")
        case .warn: logger.warning("\(text, privacy: .public)")
        case .error: logger.error("\(text, privacy: .public)")
        }
        write(level: level, category: category, text: text)
    }

    public func debug(_ message: @autoclosure () -> String, category: LogCategory = .app) {
        log(.debug, message(), category: category)
    }
    public func info(_ message: @autoclosure () -> String, category: LogCategory = .app) {
        log(.info, message(), category: category)
    }
    public func warn(_ message: @autoclosure () -> String, category: LogCategory = .app) {
        log(.warn, message(), category: category)
    }
    public func error(_ message: @autoclosure () -> String, category: LogCategory = .app) {
        log(.error, message(), category: category)
    }

    private func write(level: LogLevel, category: LogCategory, text: String) {
        guard let fileURL, let previousURL else { return }
        let line = "\(Self.timestamp()) [\(ProcessInfo.processInfo.processIdentifier)] "
            + "[\(level.rawValue.uppercased())] [\(category.rawValue)] \(text)\n"
        let maxBytes = self.maxBytes
        fileQueue.async {
            Self.rotateIfNeeded(current: fileURL, previous: previousURL, maxBytes: maxBytes)
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }

    private static func rotateIfNeeded(current: URL, previous: URL, maxBytes: Int) {
        let size = (try? FileManager.default.attributesOfItem(atPath: current.path)[.size] as? Int) ?? 0
        guard size > maxBytes else { return }
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: current, to: previous)
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
