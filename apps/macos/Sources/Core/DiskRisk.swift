import Foundation

/// How careful to be before removing something the disk map shows. A guide, never a promise: Kriya only ever moves things to
/// the Trash, and only when asked.
enum DiskRisk {
    enum Level: Int, Comparable {
        case safe = 0, review, keep
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }

        var title: String {
            switch self {
            case .safe: return "Safe to remove"
            case .review: return "Look first"
            case .keep: return "Keep"
            }
        }
    }

    struct Verdict: Equatable {
        let level: Level
        let reason: String
    }

    /// Folders programs rebuild on their own.
    private static let rebuildable: [(marker: String, reason: String)] = [
        ("/library/caches", "Apps rebuild their caches."),
        ("/library/logs", "Old logs are not needed."),
        ("/.trash", "Already in the Trash."),
        ("/deriveddata", "Xcode builds these again."),
        ("/node_modules", "Reinstalled from the project's package list."),
        ("/__pycache__", "Python makes these again."),
        ("/.cache", "A cache folder."),
        ("/library/developer/xcode/ios devicesupport", "Xcode fetches these again when a device connects."),
        ("/library/developer/coresimulator/caches", "A simulator cache."),
    ]

    private static let personal: [(marker: String, reason: String)] = [
        ("/documents", "Your documents."), ("/desktop", "Your desktop."), ("/pictures", "Your pictures."),
        ("/movies", "Your movies."), ("/music", "Your music."), ("/library/mobile documents", "iCloud Drive files."),
        ("/library/mail", "Your mail."), ("/library/messages", "Your messages."), ("/.ssh", "Your keys."), ("/.gnupg", "Your keys."),
        ("/library/keychains", "Your passwords."), ("/library/application support", "Apps keep their data here."),
    ]

    static func classify(_ path: String, home: String = NSHomeDirectory()) -> Verdict {
        let lower = path.lowercased()
        let homeLower = home.lowercased()
        if lower.hasPrefix("/system") || lower.hasPrefix("/usr") || lower.hasPrefix("/bin") || lower.hasPrefix("/sbin") || lower.hasPrefix("/private/var/db") {
            return Verdict(level: .keep, reason: "Part of macOS.")
        }
        if lower.hasSuffix(".photoslibrary") || lower.contains(".photoslibrary/") { return Verdict(level: .keep, reason: "Your Photos library.") }
        if lower.hasSuffix("/.git") || lower.contains("/.git/") { return Verdict(level: .keep, reason: "A project's history.") }
        for item in rebuildable where lower.contains(item.marker) { return Verdict(level: .safe, reason: item.reason) }
        if lower.hasPrefix("/applications") { return Verdict(level: .review, reason: "An app. Removing it uninstalls it.") }
        if lower.hasPrefix(homeLower + "/downloads") { return Verdict(level: .review, reason: "Downloads often hold things you still want.") }
        for item in personal where lower.hasPrefix(homeLower + item.marker) { return Verdict(level: .keep, reason: item.reason) }
        return Verdict(level: .review, reason: "Kriya cannot tell what this is for.")
    }

    /// A file that is only a name in iCloud, not on this Mac: removing it frees nothing.
    static func isCloudPlaceholder(_ name: String) -> Bool { name.hasPrefix(".") && name.hasSuffix(".icloud") }

    /// The first `limit` that are safe to remove, biggest first, with their combined size.
    static func cleanupSuggestions(_ items: [(path: String, size: Int64)], limit: Int = 10, home: String = NSHomeDirectory()) -> (items: [(path: String, size: Int64)], total: Int64) {
        let safe = items.filter { classify($0.path, home: home).level == .safe }.sorted { $0.size > $1.size }.prefix(limit)
        return (Array(safe), safe.reduce(0) { $0 + $1.size })
    }
}
