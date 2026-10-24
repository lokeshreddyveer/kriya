import Foundation

/// One file found by a deep look: how much room it really takes on disk (allocated) and its length (logical), which differ for
/// compressed, sparse and cloned files.
struct DiskFile: Identifiable, Equatable, Codable {
    var id: String { path }
    let path: String
    let allocated: Int64
    let logical: Int64
    let modified: Date?

    var name: String { (path as NSString).lastPathComponent }
    var ext: String { (path as NSString).pathExtension.lowercased() }
}

enum DiskText {
    /// Said wherever sizes are shown, because Finder's numbers differ from these.
    static let usageNote = "Sizes are disk usage: the room an item takes on disk. Finder can show a different number because it adds up file lengths, and compressed, sparse or cloned files take less room than their length."
    static let trashNote = "Everything goes to the Trash, so it can be put back. Room comes back once the Trash is emptied."
}

enum DiskFilter {
    /// What is left after the search text, extension, size and age limits. Search matches the name or the folder.
    static func apply(_ files: [DiskFile], query: String = "", ext: String = "", minBytes: Int64 = 0, olderThanDays: Int? = nil, now: Date = Date()) -> [DiskFile] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let e = ext.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
        return files.filter { file in
            if file.allocated < minBytes { return false }
            if !e.isEmpty, file.ext != e { return false }
            if !q.isEmpty, !file.path.lowercased().contains(q) { return false }
            if let days = olderThanDays {
                guard let modified = file.modified, now.timeIntervalSince(modified) >= Double(days) * 86_400 else { return false }
            }
            return true
        }
    }

    enum Sort: String, CaseIterable { case size, logical, modified, name, kind }

    static func sorted(_ files: [DiskFile], by sort: Sort, ascending: Bool = false) -> [DiskFile] {
        let out: [DiskFile]
        switch sort {
        case .size: out = files.sorted { $0.allocated > $1.allocated }
        case .logical: out = files.sorted { $0.logical > $1.logical }
        case .modified: out = files.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        case .name: out = files.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .kind: out = files.sorted { ($0.ext, $0.name) < ($1.ext, $1.name) }
        }
        return ascending ? out.reversed() : out
    }
}

enum DiskExport {
    /// One quoted CSV row per file, with the risk each was given.
    static func csv(_ files: [DiskFile], home: String = NSHomeDirectory()) -> String {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let iso = ISO8601DateFormatter()
        var lines = ["name,path,disk_usage_bytes,length_bytes,modified,kind,risk"]
        for f in files {
            let risk = DiskRisk.classify(f.path, home: home).level.title
            lines.append([q(f.name), q(f.path), String(f.allocated), String(f.logical), f.modified.map { iso.string(from: $0) } ?? "", f.ext, q(risk)].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func json(_ files: [DiskFile]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(files)
    }
}

/// Free space as macOS counts it: what is free now, and what it would be if purgeable things (local snapshots, caches macOS
/// gives back on demand) were counted. The gap is the purgeable space.
struct VolumeReport: Equatable {
    var name: String
    var total: Int64
    var available: Int64
    var availableForImportant: Int64

    var used: Int64 { max(0, total - available) }
    var purgeable: Int64 { max(0, availableForImportant - available) }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    /// What a scan could not account for: used room minus the items measured. Hidden space is system data, snapshots and
    /// anything macOS did not let the scan read.
    func unaccounted(measured: Int64) -> Int64 { max(0, used - measured) }
}

enum SnapshotList {
    /// Time Machine's local snapshot names from `tmutil listlocalsnapshots`, which prints one `com.apple.TimeMachine.DATE.local` per line.
    static func parse(_ output: String) -> [String] {
        output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("com.apple.") }
    }

    /// The date part of a snapshot name ("2026-10-20-101500"), for showing as a date.
    static func date(of name: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        for part in name.split(separator: ".") { if let d = f.date(from: String(part)) { return d } }
        return nil
    }
}

/// Files of the same size and then the same content. Size is checked first because it is cheap; only same-size files are read.
enum DiskDuplicates {
    static let minimumBytes: Int64 = 1_000_000

    /// Groups of two or more files with the same length. A starting point only: `confirm` decides which really match.
    static func sizeGroups(_ files: [DiskFile], minimumBytes: Int64 = minimumBytes) -> [[DiskFile]] {
        Dictionary(grouping: files.filter { $0.logical >= minimumBytes }, by: \.logical).values.filter { $0.count > 1 }
            .map { $0.sorted { $0.path < $1.path } }.sorted { ($0.first?.logical ?? 0) * Int64($0.count) > ($1.first?.logical ?? 0) * Int64($1.count) }
    }

    /// Splits each size group by `fingerprint` (a hash of the content), keeping only the groups that still hold two or more.
    static func confirm(_ groups: [[DiskFile]], fingerprint: (DiskFile) -> String?) -> [[DiskFile]] {
        var out: [[DiskFile]] = []
        for group in groups {
            let byHash = Dictionary(grouping: group) { fingerprint($0) ?? "unreadable:" + $0.path }
            out += byHash.filter { !$0.key.hasPrefix("unreadable:") && $0.value.count > 1 }.values.map { $0.sorted { $0.path < $1.path } }
        }
        return out.sorted { ($0.first?.logical ?? 0) * Int64($0.count) > ($1.first?.logical ?? 0) * Int64($1.count) }
    }

    /// Room freed by keeping one copy of each group.
    static func reclaimable(_ groups: [[DiskFile]]) -> Int64 { groups.reduce(0) { $0 + $1.dropFirst().reduce(0) { $0 + $1.allocated } } }
}

/// Places developers fill up that are made again when needed, by tool. Each is a path under home.
enum DeveloperPlaces {
    static let list: [(name: String, path: String, note: String)] = [
        ("Xcode derived data", "Library/Developer/Xcode/DerivedData", "Build output Xcode makes again."),
        ("Xcode archives", "Library/Developer/Xcode/Archives", "Past app archives. Look first: they hold builds you may need to symbolicate."),
        ("Xcode device support", "Library/Developer/Xcode/iOS DeviceSupport", "Symbols Xcode fetches again when a device connects."),
        ("Simulators", "Library/Developer/CoreSimulator/Devices", "Simulator disks. Look first: they hold simulator app data."),
        ("Swift package cache", "Library/Caches/org.swift.swiftpm", "Package downloads made again."),
        ("CocoaPods cache", "Library/Caches/CocoaPods", "Pod downloads made again."),
        ("Homebrew downloads", "Library/Caches/Homebrew", "Installer downloads Homebrew fetches again."),
        ("npm cache", ".npm", "Packages npm downloads again."),
        ("Yarn cache", "Library/Caches/Yarn", "Packages Yarn downloads again."),
        ("pnpm store", "Library/pnpm", "Packages pnpm downloads again."),
        ("pip cache", "Library/Caches/pip", "Python packages pip downloads again."),
        ("Gradle caches", ".gradle/caches", "Dependencies Gradle downloads again."),
        ("Maven repository", ".m2/repository", "Dependencies Maven downloads again."),
        ("Cargo registry", ".cargo/registry", "Crates Cargo downloads again."),
        ("Docker data", "Library/Containers/com.docker.docker", "Docker's disk image. Look first: it holds your images and volumes."),
        ("Virtual machines", "Parallels", "Virtual machine disks. Look first: they hold whole computers."),
    ]
}

/// A saved reading of one folder, so a later one can say what changed.
struct ScanRecord: Codable, Equatable {
    var date: Date
    var path: String
    var total: Int64
    var items: [Item]

    struct Item: Codable, Equatable { var name: String; var size: Int64 }

    struct Change: Equatable { var name: String; var before: Int64; var after: Int64; var delta: Int64 { after - before } }

    /// What grew or shrank since `old`, biggest change first. Items that were not there count from zero (and the reverse).
    func changes(since old: ScanRecord, minimum: Int64 = 1_000_000) -> [Change] {
        let before = Dictionary(old.items.map { ($0.name, $0.size) }, uniquingKeysWith: { a, _ in a })
        let after = Dictionary(items.map { ($0.name, $0.size) }, uniquingKeysWith: { a, _ in a })
        return Set(before.keys).union(after.keys).map { Change(name: $0, before: before[$0] ?? 0, after: after[$0] ?? 0) }
            .filter { abs($0.delta) >= minimum }.sorted { abs($0.delta) > abs($1.delta) }
    }
}

enum ScanFreshness {
    static let staleAfter: TimeInterval = 600

    /// True once a map is old enough that what it shows may no longer be on the disk.
    static func isStale(scannedAt: Date?, now: Date = Date()) -> Bool {
        guard let scannedAt else { return false }
        return now.timeIntervalSince(scannedAt) > staleAfter
    }
}

enum DiskPaths {
    /// True when `url` leads outside `root` once links are followed: a link inside a folder pointing somewhere else. Such items
    /// are not measured or moved on the folder's behalf.
    static func escapes(_ url: URL, root: URL) -> Bool {
        let real = url.resolvingSymlinksInPath().path
        return !DiskRisk.isInside(real, root.resolvingSymlinksInPath().path)
    }

    /// The age bands the map can colour by.
    enum Age: Int, CaseIterable {
        case week, month, year, older
        var title: String { ["Past week", "Past month", "Past year", "Older"][rawValue] }
        static func of(_ date: Date?, now: Date = Date()) -> Age {
            guard let date else { return .older }
            let days = now.timeIntervalSince(date) / 86_400
            return days <= 7 ? .week : days <= 31 ? .month : days <= 365 ? .year : .older
        }
    }
}
