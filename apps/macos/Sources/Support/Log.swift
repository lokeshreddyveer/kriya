import Foundation
import os

extension LogLevel: Comparable {
    static var all: [LogLevel] { [.debug, .info, .warning, .error] }

    var rank: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warning: return 2
        case .error: return 3
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rank < rhs.rank }

    var title: String {
        switch self {
        case .debug: return "Debug"
        case .info: return "Info"
        case .warning: return "Warning"
        case .error: return "Error"
        }
    }

    fileprivate var tag: String { title.uppercased() }

    fileprivate var osType: OSLogType {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .warning: return .default
        case .error: return .error
        }
    }
}

/// Local diagnostic log. It only ever stays on this Mac: a small rotating file in ~/Library/Logs/Kriya plus the system
/// log. Messages describe what the app did; they never include text the person typed or selected.
final class Log {
    static let shared = Log()

    private static let maxBytes = 1_000_000
    private static let keptFiles = 3

    private let queue = DispatchQueue(label: "app.kriya.log", qos: .utility)
    private let lock = NSLock()
    private var level: LogLevel = .info
    private var fileURL: URL?
    private var handle: FileHandle?
    private let osLogger = Logger(subsystem: "app.kriya", category: "app")
    private let timestamps = ISO8601DateFormatter()

    func configure(fileURL: URL, level: LogLevel) {
        lock.lock()
        self.fileURL = fileURL
        self.level = level
        lock.unlock()
    }

    func setLevel(_ newLevel: LogLevel) {
        lock.lock()
        level = newLevel
        lock.unlock()
    }

    private func allows(_ candidate: LogLevel) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return candidate >= level
    }

    func write(_ level: LogLevel, _ category: String, _ message: String) {
        guard allows(level) else { return }
        osLogger.log(level: level.osType, "\(category, privacy: .public): \(message, privacy: .public)")
        let line = "\(timestamps.string(from: Date())) [\(level.tag)] \(category): \(message)\n"
        queue.async { [weak self] in self?.append(line) }
    }

    /// Waits until everything written so far is on disk. Used before the app exits on a crash.
    func flush() {
        queue.sync {}
    }

    // MARK: File handling (always on `queue`)

    private func append(_ line: String) {
        lock.lock()
        let url = fileURL
        lock.unlock()
        guard let url else { return }
        if handle == nil { handle = openHandle(url) }
        guard let handle else { return }
        try? handle.write(contentsOf: Data(line.utf8))
        if let size = try? handle.offset(), size > UInt64(Log.maxBytes) { rotate(url) }
    }

    private func openHandle(_ url: URL) -> FileHandle? {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let h = try? FileHandle(forWritingTo: url) else { return nil }
        _ = try? h.seekToEnd()
        return h
    }

    private func rotate(_ url: URL) {
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        for index in stride(from: Log.keptFiles - 1, through: 1, by: -1) {
            let from = rotated(url, index)
            let to = rotated(url, index + 1)
            try? fm.removeItem(at: to)
            if fm.fileExists(atPath: from.path) { try? fm.moveItem(at: from, to: to) }
        }
        try? fm.removeItem(at: rotated(url, 1))
        try? fm.moveItem(at: url, to: rotated(url, 1))
    }

    private func rotated(_ url: URL, _ index: Int) -> URL {
        let base = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent().appendingPathComponent("\(base).\(index).log")
    }

    // MARK: Reading

    /// The newest lines, for the Diagnostics screen.
    func recentLines(limit: Int) -> [String] {
        queue.sync {
            lock.lock()
            let url = fileURL
            lock.unlock()
            guard let url, let reader = try? FileHandle(forReadingFrom: url) else { return [] }
            defer { try? reader.close() }
            let size = (try? reader.seekToEnd()) ?? 0
            let window: UInt64 = 256 * 1024
            let start = size > window ? size - window : 0
            try? reader.seek(toOffset: start)
            guard let data = try? reader.readToEnd(), let text = String(data: data, encoding: .utf8) else { return [] }
            var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            if start > 0, !lines.isEmpty { lines.removeFirst() }
            return Array(lines.suffix(limit))
        }
    }

    /// Every log file, oldest first, for the diagnostic report.
    func allLogFiles() -> [URL] {
        lock.lock()
        let url = fileURL
        lock.unlock()
        guard let url else { return [] }
        let candidates = (1...Log.keptFiles).reversed().map { rotated(url, $0) } + [url]
        return candidates.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: Convenience

    static func debug(_ category: String, _ message: @autoclosure () -> String) {
        guard shared.allows(.debug) else { return }
        shared.write(.debug, category, message())
    }

    static func info(_ category: String, _ message: @autoclosure () -> String) {
        guard shared.allows(.info) else { return }
        shared.write(.info, category, message())
    }

    static func warning(_ category: String, _ message: @autoclosure () -> String) {
        shared.write(.warning, category, message())
    }

    static func error(_ category: String, _ message: @autoclosure () -> String) {
        shared.write(.error, category, message())
    }
}
