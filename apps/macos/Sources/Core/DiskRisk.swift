import Foundation

/// How careful to be before removing something the disk map shows. A guide, never a promise: Kriya only ever moves things to
/// the Trash, and only when asked. Nothing is called safe; the best it says is "likely rebuildable".
enum DiskRisk {
    enum Level: Int, Comparable {
        /// Something its app makes again (a cache, build output). Still worth a look before it goes.
        case safe = 0, review, keep
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }

        var title: String {
            switch self {
            case .safe: return "Likely rebuildable"
            case .review: return "Look first"
            case .keep: return "Keep"
            }
        }
    }

    struct Verdict: Equatable {
        let level: Level
        let reason: String
    }

    /// Build output and package folders: made again from the project, wherever the project is.
    private static let projectArtifacts: [(marker: [String], reason: String)] = [
        (["deriveddata"], "Xcode builds these again."),
        (["node_modules"], "Reinstalled from the project's package list."),
        (["__pycache__"], "Python makes these again."),
        (["library", "developer", "xcode", "ios devicesupport"], "Xcode fetches these again when a device connects."),
        (["library", "developer", "coresimulator", "caches"], "A simulator cache."),
    ]

    /// Caches and logs: apps make them again, but only counted as such outside the folders that hold a person's own files.
    private static let appCaches: [(marker: [String], reason: String)] = [
        (["library", "caches"], "Apps rebuild their caches."),
        (["library", "logs"], "Old logs are not needed."),
        ([".trash"], "Already in the Trash."),
        ([".cache"], "A cache folder."),
    ]

    private static let personal: [(marker: [String], reason: String)] = [
        (["documents"], "Your documents."), (["desktop"], "Your desktop."), (["pictures"], "Your pictures."),
        (["movies"], "Your movies."), (["music"], "Your music."), (["library", "mobile documents"], "iCloud Drive files."),
        (["library", "mail"], "Your mail."), (["library", "messages"], "Your messages."), ([".ssh"], "Your keys."), ([".gnupg"], "Your keys."),
        (["library", "keychains"], "Your passwords."), (["library", "application support"], "Apps keep their data here."),
    ]

    /// A path's pieces, lower-cased, so "/Users/me/Library" is never mistaken for "/Users/me/Libraryx".
    static func components(_ path: String) -> [String] { path.lowercased().split(separator: "/").map(String.init) }

    /// True when `marker` appears as whole, consecutive pieces of `parts` (anywhere, or only at the start when `anchored`).
    static func has(_ marker: [String], in parts: [String], anchored: Bool = false) -> Bool {
        guard !marker.isEmpty, parts.count >= marker.count else { return false }
        if anchored { return Array(parts.prefix(marker.count)) == marker }
        for start in 0...(parts.count - marker.count) where Array(parts[start..<start + marker.count]) == marker { return true }
        return false
    }

    /// True when `path` is `folder` or inside it, by whole path pieces.
    static func isInside(_ path: String, _ folder: String) -> Bool {
        let p = components(path), f = components(folder)
        return !f.isEmpty && p.count >= f.count && Array(p.prefix(f.count)) == f
    }

    static func classify(_ path: String, home: String = NSHomeDirectory()) -> Verdict {
        let parts = components(path)
        let homeParts = components(home)
        let inHome = homeParts.count <= parts.count && Array(parts.prefix(homeParts.count)) == homeParts
        let rest = inHome ? Array(parts.dropFirst(homeParts.count)) : []
        for system in ["system", "usr", "bin", "sbin"] where parts.first == system { return Verdict(level: .keep, reason: "Part of macOS.") }
        if has(["private", "var", "db"], in: parts, anchored: true) { return Verdict(level: .keep, reason: "Part of macOS.") }
        if parts.contains(where: { $0.hasSuffix(".photoslibrary") }) { return Verdict(level: .keep, reason: "Your Photos library.") }
        if parts.contains(".git") { return Verdict(level: .keep, reason: "A project's history.") }
        if parts.first == "applications" { return Verdict(level: .review, reason: "An app. Removing it uninstalls it.") }
        let inPersonal = inHome && personal.contains { has($0.marker, in: rest, anchored: true) }
        for item in projectArtifacts where has(item.marker, in: parts) { return Verdict(level: .safe, reason: item.reason) }
        if !inPersonal {
            for item in appCaches where has(item.marker, in: parts) { return Verdict(level: .safe, reason: item.reason) }
        }
        if inHome, has(["downloads"], in: rest, anchored: true) { return Verdict(level: .review, reason: "Downloads often hold things you still want.") }
        if inHome { for item in personal where has(item.marker, in: rest, anchored: true) { return Verdict(level: .keep, reason: item.reason) } }
        return Verdict(level: .review, reason: "Kriya cannot tell what this is for.")
    }

    /// A file that is only a name in iCloud, not on this Mac: removing it frees nothing.
    static func isCloudPlaceholder(_ name: String) -> Bool { name.hasPrefix(".") && name.hasSuffix(".icloud") }

    /// The first `limit` that are likely rebuildable, biggest first, with their combined size.
    static func cleanupSuggestions(_ items: [(path: String, size: Int64)], limit: Int = 10, home: String = NSHomeDirectory()) -> (items: [(path: String, size: Int64)], total: Int64) {
        let safe = items.filter { classify($0.path, home: home).level == .safe }.sorted { $0.size > $1.size }.prefix(limit)
        return (Array(safe), safe.reduce(0) { $0 + $1.size })
    }
}
