import Foundation

/// The folders Finder has open, and the ones it had open a moment ago. Kept as folder paths only, and only while the person
/// has turned the tracking on.
struct FinderWindowHistory: Codable, Equatable {
    static let capacity = 20
    private(set) var open: [String] = []
    private(set) var closed: [String] = []

    /// Takes the folders open now. A folder that was open and is gone is recorded as closed; one that is open again is no
    /// longer closed. Folders the person left out are never kept.
    mutating func observe(_ paths: [String], isExcluded: (String) -> Bool = { _ in false }) {
        var seen = Set<String>()
        let now = paths.map(Self.clean).filter { !$0.isEmpty && !isExcluded($0) && seen.insert($0).inserted }
        for path in open where !seen.contains(path) {
            closed.removeAll { $0 == path }
            closed.insert(path, at: 0)
        }
        closed.removeAll { seen.contains($0) }
        if closed.count > Self.capacity { closed.removeLast(closed.count - Self.capacity) }
        open = now
    }

    mutating func forget(_ path: String) { closed.removeAll { $0 == path } }
    mutating func clear() { open = []; closed = [] }

    static func clean(_ path: String) -> String { path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path }
}

/// A group of folders opened together, such as everything for one project.
struct FolderSet: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var paths: [String]

    /// The folders that can still be opened, in order, each once.
    func openable(exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [String] {
        var seen = Set<String>()
        return paths.map(FinderWindowHistory.clean).filter { exists($0) && seen.insert($0).inserted }
    }
}

enum FolderSets {
    static let limit = 20

    /// A set of the folders open in Finder now, or nil when none are.
    static func from(open: [String], named name: String) -> FolderSet? {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, !open.isEmpty else { return nil }
        return FolderSet(name: clean, paths: open)
    }

    /// Whether a folder is inside one the person left out of the recent lists.
    static func isExcluded(_ path: String, folders: [String]) -> Bool {
        folders.map(FinderWindowHistory.clean).contains { $0 == path || path.hasPrefix($0 + "/") }
    }
}
