import Foundation

/// A background item macOS starts for you or for everyone: a launch agent or a launch daemon, read from its property list. This
/// is a view of what is there; Kriya changes none of it except to move an orphaned item in your own folder to the Trash.
struct LaunchItem: Identifiable, Equatable {
    enum Scope: String, CaseIterable, Identifiable {
        case user, everyone, system
        var id: String { rawValue }
        var title: String {
            switch self {
            case .user: return "Your launch agents"
            case .everyone: return "Launch agents for everyone"
            case .system: return "Launch daemons (run as the system)"
            }
        }
        var folder: String {
            switch self {
            case .user: return NSHomeDirectory() + "/Library/LaunchAgents"
            case .everyone: return "/Library/LaunchAgents"
            case .system: return "/Library/LaunchDaemons"
            }
        }
    }

    let path: String
    let scope: Scope
    let label: String
    let program: String?
    let arguments: [String]
    let runAtLoad: Bool
    let keepAlive: Bool
    let disabled: Bool
    /// Whether the program it starts is there. Nil when the item names none (it uses a socket or a bundle).
    let programExists: Bool?

    var id: String { path }
    var fileName: String { (path as NSString).lastPathComponent }

    /// An item whose program is gone: it can only fail every time it starts.
    var isOrphaned: Bool { programExists == false }

    /// The app that most likely owns it, from the program's path ("/Applications/Zoom.app/…" → "Zoom").
    var ownerApp: String? {
        guard let program else { return nil }
        for part in program.split(separator: "/") where part.hasSuffix(".app") { return String(part.dropLast(4)) }
        return nil
    }

    /// One line on when it runs.
    var when: String {
        var parts: [String] = []
        if runAtLoad { parts.append("starts when you log in or boot") }
        if keepAlive { parts.append("restarted if it stops") }
        if parts.isEmpty { parts.append("starts on demand") }
        return parts.joined(separator: ", ")
    }
}

enum LaunchItems {
    /// A launch item from its property list. Nil if it has no label.
    static func parse(_ plist: [String: Any], path: String, scope: LaunchItem.Scope, exists: (String) -> Bool) -> LaunchItem? {
        guard let label = (plist["Label"] as? String)?.trimmingCharacters(in: .whitespaces), !label.isEmpty else { return nil }
        let arguments = (plist["ProgramArguments"] as? [String]) ?? []
        let program = (plist["Program"] as? String) ?? arguments.first
        let keepAlive: Bool
        switch plist["KeepAlive"] {
        case let flag as Bool: keepAlive = flag
        case is [String: Any]: keepAlive = true
        default: keepAlive = false
        }
        // A bare command name ("sh", "open") is looked up on the path, so only a full path can be called missing.
        let exists: Bool? = program.flatMap { $0.hasPrefix("/") ? exists($0) : nil }
        return LaunchItem(
            path: path, scope: scope, label: label, program: program, arguments: Array(arguments.dropFirst()),
            runAtLoad: plist["RunAtLoad"] as? Bool ?? false, keepAlive: keepAlive, disabled: plist["Disabled"] as? Bool ?? false, programExists: exists
        )
    }

    /// Items sorted with the orphaned ones first, then by label.
    static func sorted(_ items: [LaunchItem]) -> [LaunchItem] {
        items.sorted { a, b in
            if a.isOrphaned != b.isOrphaned { return a.isOrphaned }
            return a.label.localizedCaseInsensitiveCompare(b.label) == .orderedAscending
        }
    }

    /// Reads every property list in a scope's folder.
    static func scan(_ scope: LaunchItem.Scope, fileManager: FileManager = .default) -> [LaunchItem] {
        let folder = scope.folder
        let names = (try? fileManager.contentsOfDirectory(atPath: folder)) ?? []
        let items = names.filter { $0.hasSuffix(".plist") }.compactMap { name -> LaunchItem? in
            let path = folder + "/" + name
            guard let data = fileManager.contents(atPath: path), data.count < 1_000_000,
                  let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] else { return nil }
            return parse(plist, path: path, scope: scope) { fileManager.isExecutableFile(atPath: $0) }
        }
        return sorted(items)
    }
}
