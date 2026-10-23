import Foundation

/// The temporary files kept in the Finder drawer, in the order the person arranged them. Paths only; nothing is copied.
struct FinderDrawerList: Equatable {
    static let capacity = 30
    private(set) var paths: [String] = []

    /// Adds files at the end, each once. Returns how many were added; files past the capacity are left out.
    @discardableResult
    mutating func add(_ new: [String]) -> Int {
        var added = 0
        for path in new where !path.isEmpty && !paths.contains(path) && paths.count < Self.capacity {
            paths.append(path)
            added += 1
        }
        return added
    }

    mutating func remove(_ path: String) { paths.removeAll { $0 == path } }
    mutating func clear() { paths = [] }

    /// Moves items the way a list's drag does: `offsets` to just before `destination`.
    mutating func move(from offsets: IndexSet, to destination: Int) {
        let moving = offsets.filter { paths.indices.contains($0) }.map { paths[$0] }
        guard !moving.isEmpty else { return }
        let before = offsets.filter { $0 < destination }.count
        for index in offsets.sorted(by: >) where paths.indices.contains(index) { paths.remove(at: index) }
        let target = min(max(destination - before, 0), paths.count)
        paths.insert(contentsOf: moving, at: target)
    }

    /// Drops files that are no longer there.
    mutating func prune(exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        paths = paths.filter(exists)
    }
}
