import Foundation

/// How long captures are kept, in three separate parts. 0 days means "never": the history shows everything, and no file is ever
/// offered for cleanup.
struct CaptureRetention: Codable, Equatable {
    /// How far back the history lists reach, and how long Kriya remembers a closed capture card. Older entries are dropped from the
    /// lists by themselves; the files stay where they are.
    var captureHistoryDays = 0
    /// Pictures older than this are offered for cleanup. Never deleted without asking.
    var screenshotFileDays = 0
    /// Recordings and GIFs older than this are offered for cleanup. Never deleted without asking.
    var recordingFileDays = 0

    static let choices = [0, 1, 3, 7, 14, 30, 90, 365]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        captureHistoryDays = c.value(.captureHistoryDays, 0)
        screenshotFileDays = c.value(.screenshotFileDays, 0)
        recordingFileDays = c.value(.recordingFileDays, 0)
    }

    /// Each setting moved to the nearest length that can be chosen (so a hand-edited or damaged value is still sensible).
    func sanitized() -> CaptureRetention {
        func nearest(_ days: Int) -> Int { days <= 0 ? 0 : (Self.choices.filter { $0 > 0 }.min { abs($0 - days) < abs($1 - days) } ?? 0) }
        var next = self
        next.captureHistoryDays = nearest(captureHistoryDays)
        next.screenshotFileDays = nearest(screenshotFileDays)
        next.recordingFileDays = nearest(recordingFileDays)
        return next
    }

    private static func cutoff(days: Int, now: Date) -> Date? {
        days > 0 ? now.addingTimeInterval(-Double(days) * 86_400) : nil
    }

    /// The oldest date the history still shows, or nil when it shows everything.
    func historyCutoff(now: Date = Date()) -> Date? { Self.cutoff(days: captureHistoryDays, now: now) }

    /// Whether the history still keeps something made at this time.
    func keepsInHistory(_ date: Date, now: Date = Date()) -> Bool {
        guard let cutoff = historyCutoff(now: now) else { return true }
        return date >= cutoff
    }

    /// Whether a file made at this time is old enough to be offered for cleanup.
    func fileIsExpired(_ date: Date, isRecording: Bool, now: Date = Date()) -> Bool {
        guard let cutoff = Self.cutoff(days: isRecording ? recordingFileDays : screenshotFileDays, now: now) else { return false }
        return date < cutoff
    }
}

/// Finding the captures that are older than the limits, and moving them to the Trash only when the person has agreed.
enum CaptureCleanup {
    struct File: Equatable, Identifiable {
        let path: String
        let date: Date
        let bytes: Int64
        /// A recording or GIF, which has its own limit.
        let isRecording: Bool
        var id: String { path }
    }

    /// Movies and GIFs follow the recording limit; every other picture follows the screenshot limit.
    static func isRecording(extension ext: String) -> Bool { ["mov", "mp4", "gif"].contains(ext.lowercased()) }

    /// The capture files in a folder (not inside folders within it), with when they were made and how big they are.
    static func files(in folder: URL) -> [File] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { url in
            let ext = url.pathExtension.lowercased()
            guard CaptureHistory.extensions.contains(ext), let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return nil }
            return File(path: url.path, date: values.contentModificationDate ?? .distantPast, bytes: Int64(values.fileSize ?? 0), isRecording: isRecording(extension: ext))
        }
    }

    /// The files past their limit, oldest first. With a limit of 0 for a kind, none of that kind is ever listed.
    static func expired(_ files: [File], retention: CaptureRetention, now: Date = Date()) -> [File] {
        files.filter { retention.fileIsExpired($0.date, isRecording: $0.isRecording, now: now) }.sorted { $0.date < $1.date }
    }

    static func summary(_ files: [File]) -> String {
        guard !files.isEmpty else { return "Nothing is older than the limits." }
        let pictures = files.filter { !$0.isRecording }.count
        let movies = files.count - pictures
        var parts: [String] = []
        if pictures > 0 { parts.append("\(pictures) picture\(pictures == 1 ? "" : "s")") }
        if movies > 0 { parts.append("\(movies) recording\(movies == 1 ? "" : "s")") }
        let size = ByteCountFormatter.string(fromByteCount: files.reduce(0) { $0 + $1.bytes }, countStyle: .file)
        return parts.joined(separator: " and ") + " (\(size)) older than the limits."
    }

    struct Result: Equatable {
        var trashed = 0
        var failed = 0
        /// The person was asked and said no.
        var declined = false

        var message: String {
            if declined { return "Nothing was moved to the Trash." }
            var text = trashed == 0 ? "Nothing was moved to the Trash." : "Moved \(trashed) capture\(trashed == 1 ? "" : "s") to the Trash."
            if failed > 0 { text += " \(failed) could not be moved." }
            return text
        }
    }

    /// Moves the files to the Trash, after asking. `confirm` is shown the files and answers whether to go ahead; nothing is moved
    /// before it says yes, and nothing is ever deleted outright.
    static func run(_ files: [File], confirm: ([File]) -> Bool, trash: (String) throws -> Void) -> Result {
        guard !files.isEmpty else { return Result() }
        guard confirm(files) else { return Result(declined: true) }
        var result = Result()
        for file in files {
            do { try trash(file.path); result.trashed += 1 } catch { result.failed += 1 }
        }
        return result
    }
}
