import Foundation

struct FoundFile: Identifiable, Equatable, Hashable {
    var id: String { path }
    let path: String
    let size: Int64
    let modified: Date?
    var name: String { (path as NSString).lastPathComponent }
    var folder: String { ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent }
}

enum DuplicateFinder {
    /// Files that share a size with at least one other. Only these can be copies of each other, so only these are read.
    static func sizeGroups(_ files: [FoundFile], minimumSize: Int64 = 1_048_576) -> [[FoundFile]] {
        Dictionary(grouping: files.filter { $0.size >= minimumSize }, by: \.size).values.filter { $0.count > 1 }.map { $0.sorted { $0.path < $1.path } }
            .sorted { ($0.first?.size ?? 0) > ($1.first?.size ?? 0) }
    }

    /// Splits one size group into sets of really identical files, given each file's content fingerprint.
    static func duplicates(in group: [FoundFile], fingerprint: (FoundFile) -> String?) -> [[FoundFile]] {
        var byHash: [String: [FoundFile]] = [:]
        for file in group { if let h = fingerprint(file) { byHash[h, default: []].append(file) } }
        return byHash.values.filter { $0.count > 1 }.map { $0.sorted { $0.path < $1.path } }
    }

    /// The room that would come back if all but one of each set were removed.
    static func reclaimable(_ sets: [[FoundFile]]) -> Int64 {
        sets.reduce(0) { $0 + Int64(max($1.count - 1, 0)) * ($1.first?.size ?? 0) }
    }

    static func largest(_ files: [FoundFile], count: Int, minimumSize: Int64 = 50 * 1_048_576) -> [FoundFile] {
        Array(files.filter { $0.size >= minimumSize }.sorted { $0.size > $1.size }.prefix(count))
    }
}
