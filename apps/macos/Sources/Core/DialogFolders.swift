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
