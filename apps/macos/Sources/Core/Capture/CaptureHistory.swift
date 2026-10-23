import Foundation

/// The pictures and recordings in the capture folder, newest first, for the history list.
enum CaptureHistory {
    static let extensions: Set<String> = ["png", "jpg", "jpeg", "gif", "mov", "mp4", "heic"]

    struct Entry: Equatable, Identifiable {
        let path: String
        let date: Date
        var id: String { path }
        var name: String { (path as NSString).lastPathComponent }
        var isMovie: Bool { ["mov", "mp4"].contains((path as NSString).pathExtension.lowercased()) }
    }

    static func recent(_ files: [(path: String, date: Date)], limit: Int) -> [Entry] {
        files.filter { extensions.contains(($0.path as NSString).pathExtension.lowercased()) }
            .sorted { $0.date > $1.date }
            .prefix(limit).map { Entry(path: $0.path, date: $0.date) }
    }

    static func read(folder: URL, limit: Int = 24) -> [Entry] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        let files = urls.map { (path: $0.path, date: (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        return recent(files, limit: limit)
    }
}
