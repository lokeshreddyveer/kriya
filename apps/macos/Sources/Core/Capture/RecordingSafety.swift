import Foundation

/// Keeping a recording from being lost, and from filling the disk.
enum RecordingDisk {
    enum Level: Equatable { case fine, low, critical }

    /// Below this a warning is shown; below the next the recording is stopped and saved while there is still room to save it.
    static let lowBytes: Int64 = 2_000_000_000
    static let criticalBytes: Int64 = 400_000_000

    static func level(freeBytes: Int64) -> Level {
        if freeBytes < criticalBytes { return .critical }
        if freeBytes < lowBytes { return .low }
        return .fine
    }

    /// "1.4 GB free": what the warning says.
    static func describe(freeBytes: Int64) -> String {
        let gb = Double(freeBytes) / 1_000_000_000
        return gb >= 10 ? String(format: "%.0f GB", gb) : String(format: "%.1f GB", max(gb, 0))
    }

    /// How much room the volume holding `folder` has for a recording, or nil if it cannot be told.
    static func freeBytes(at folder: URL) -> Int64? {
        var probe = folder
        // The folder may not exist yet; its nearest parent that does is on the same volume.
        while !FileManager.default.fileExists(atPath: probe.path), probe.path != "/" { probe.deleteLastPathComponent() }
        guard let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]) else { return nil }
        if let important = values.volumeAvailableCapacityForImportantUsage { return important }
        return values.volumeAvailableCapacity.map(Int64.init)
    }
}

/// Recordings that were being written when Kriya stopped without finishing them (a crash, a power cut, a force quit). While one is
/// recorded a small marker file sits beside the movie; the movie is written in pieces, so what was recorded up to the last piece
/// can still be played. At the next start, markers left behind are found and the person is told where the movie is.
enum RecordingRecovery {
    struct Marker: Codable, Equatable {
        var movie: String
        var started: Date
    }

    static func markerURL(for movie: URL) -> URL {
        movie.deletingLastPathComponent().appendingPathComponent(".\(movie.lastPathComponent).recording")
    }

    static func begin(_ movie: URL, now: Date = Date()) {
        guard let data = try? JSONEncoder().encode(Marker(movie: movie.path, started: now)) else { return }
        try? data.write(to: markerURL(for: movie), options: .atomic)
    }

    static func end(_ movie: URL) { try? FileManager.default.removeItem(at: markerURL(for: movie)) }

    /// The movies in `folder` whose recording did not finish: a marker is there, and so is the movie.
    static func unfinished(in folder: URL, fileManager: FileManager = .default) -> [URL] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: folder.path) else { return [] }
        var found: [URL] = []
        for name in names where name.hasPrefix(".") && name.hasSuffix(".recording") {
            let markerFile = folder.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: markerFile), let marker = try? JSONDecoder().decode(Marker.self, from: data) else { continue }
            let movie = URL(fileURLWithPath: marker.movie)
            if fileManager.fileExists(atPath: movie.path), movie.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL { found.append(movie) }
            else { try? fileManager.removeItem(at: markerFile) }      // the movie is gone, so there is nothing to recover
        }
        return found.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Forgets that a movie was unfinished (it has been looked at).
    static func acknowledge(_ movie: URL) { end(movie) }
}
