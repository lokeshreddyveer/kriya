import Foundation

/// The folders offered for an Open or Save dialog, in order: where Finder is now, folders from Finder's other windows,
/// favourites, then recent ones, each once.
enum DialogFolders {
    struct Choice: Equatable, Identifiable {
        enum Kind: Equatable { case finder, window, favorite, recent }
        let path: String
        let kind: Kind
        var id: String { path }
        var name: String { path == "/" ? "Macintosh HD" : (path as NSString).lastPathComponent }
        var shortPath: String {
            let home = NSHomeDirectory()
            if path == home { return "~" }
            return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
        }
        var kindTitle: String {
            switch self.kind {
            case .finder: return "In Finder now"
            case .window: return "Open in Finder"
            case .favorite: return "Favorite"
            case .recent: return "Recent"
            }
        }
    }

    static func choices(finder: String?, windows: [String], favorites: [String], recents: [String], exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [Choice] {
        var seen = Set<String>()
        var out: [Choice] = []
        func add(_ path: String, _ kind: Choice.Kind) {
            let clean = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
            guard !clean.isEmpty, exists(clean), seen.insert(clean).inserted else { return }
            out.append(Choice(path: clean, kind: kind))
        }
        if let finder { add(finder, .finder) }
        windows.forEach { add($0, .window) }
        favorites.forEach { add($0, .favorite) }
        recents.forEach { add($0, .recent) }
        return out
    }

    /// Whether an accessibility description looks like an Open or Save dialog: a sheet, or a dialog window.
    static func looksLikeDialog(role: String?, subrole: String?, title: String?) -> Bool {
        if role == "AXSheet" { return true }
        if subrole == "AXDialog" || subrole == "AXSystemDialog" { return true }
        let t = (title ?? "").lowercased()
        return ["open", "save", "choose", "export", "import", "select", "attach"].contains { t == $0 || t.hasPrefix($0 + " ") }
    }
}


extension DialogFolders {
    /// The choices whose name or path contains every word typed; names that start with the first word come first.
    static func filter(_ choices: [Choice], query: String) -> [Choice] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return choices }
        let found = choices.filter { choice in
            let haystack = (choice.name + " " + choice.shortPath).lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
        let first = words[0]
        return found.enumerated().sorted { a, b in
            let aStarts = a.element.name.lowercased().hasPrefix(first), bStarts = b.element.name.lowercased().hasPrefix(first)
            return aStarts != bStarts ? aStarts : a.offset < b.offset
        }.map(\.element)
    }
}

extension Notification.Name {
    static let kriyaDialogAutoJumpChanged = Notification.Name("app.kriya.dialogAutoJumpChanged")
}

/// Which folder an app's Open or Save dialog should jump to by itself, kept in the app's preferences.
final class DialogAppFolders: ObservableObject {
    static let shared = DialogAppFolders()
    static let limit = 40

    @Published private(set) var folders: [String: String]
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: enabledKey) } }
    private let defaults: UserDefaults
    private let key = "dialogAppFolders.v1"
    private let enabledKey = "dialogAutoJump"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        folders = (defaults.dictionary(forKey: key) as? [String: String]) ?? [:]
        enabled = defaults.bool(forKey: enabledKey)
    }

    func set(_ path: String?, for bundleID: String) {
        if let path, !path.isEmpty, folders.count < Self.limit || folders[bundleID] != nil { folders[bundleID] = path } else { folders[bundleID] = nil }
        defaults.set(folders, forKey: key)
    }

    /// The folder to jump to when `bundleID` shows a dialog it was not showing before. Nil when it should not jump: the feature is
    /// off, no folder is set for that app, the dialog was already up, or the folder is gone.
    static func destination(for bundleID: String?, wasInDialog: Bool, isInDialog: Bool, enabled: Bool, folders: [String: String], exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String? {
        guard enabled, isInDialog, !wasInDialog, let bundleID, let path = folders[bundleID], exists(path) else { return nil }
        return path
    }
}
