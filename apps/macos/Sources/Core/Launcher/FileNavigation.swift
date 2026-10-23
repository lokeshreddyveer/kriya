import Foundation

/// Browsing folders from the launcher: type a path (starting with / or ~), and the folder's contents are listed. Pure logic,
/// so it can be tried on a temporary folder.
enum FileNavigation {
    static let maxResults = 80

    /// Whether the text is a path the person is typing.
    static func isPath(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("/") || t == "~" || t.hasPrefix("~/")
    }

    /// The folder being browsed and what was typed of the next name, from text such as "~/Doc" or "/Users/me/Downloads/".
    static func split(_ text: String, home: String = NSHomeDirectory()) -> (folder: String, prefix: String)? {
        guard isPath(text) else { return nil }
        var t = text.trimmingCharacters(in: .whitespaces)
        if t == "~" { t = "~/" }
        if t.hasPrefix("~") { t = home + t.dropFirst() }
        guard !t.contains("\0"), t.hasPrefix("/") else { return nil }
        if t.hasSuffix("/") { return ((t as NSString).standardizingPath, "") }
        return (((t as NSString).deletingLastPathComponent as NSString).standardizingPath, (t as NSString).lastPathComponent)
    }

    struct Item: Equatable {
        let url: URL
        let isDirectory: Bool
    }

    /// The folder's contents that start with `prefix` (ignoring case), folders first, hidden items only if the prefix starts with
    /// a dot. A folder that cannot be read lists nothing.
    static func list(folder: String, prefix: String) -> [Item] {
        let base = URL(fileURLWithPath: folder, isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        let wantsHidden = prefix.hasPrefix(".")
        let wanted = prefix.lowercased()
        let items: [Item] = names.compactMap { name in
            if name.hasPrefix(".") && !wantsHidden { return nil }
            if !wanted.isEmpty && !name.lowercased().hasPrefix(wanted) { return nil }
            var isDir: ObjCBool = false
            let url = base.appendingPathComponent(name)
            _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            // An app is opened, not entered.
            return Item(url: url, isDirectory: isDir.boolValue && url.pathExtension.lowercased() != "app")
        }
        let sorted = items.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
        return Array(sorted.prefix(maxResults))
    }

    /// The text for going into a folder: its path, with ~ for the home folder, and a slash after.
    static func enter(_ url: URL, home: String = NSHomeDirectory()) -> String {
        let path = url.standardizedFileURL.path
        let shown = path == home ? "~" : (path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path)
        return shown.hasSuffix("/") ? shown : shown + "/"
    }

    /// The text for going up one folder from what is typed; nil at the top.
    static func up(from text: String, home: String = NSHomeDirectory()) -> String? {
        guard let (folder, prefix) = split(text, home: home) else { return nil }
        // With part of a name typed, "up" first clears that part.
        if !prefix.isEmpty { return enter(URL(fileURLWithPath: folder), home: home) }
        guard folder != "/" else { return nil }
        return enter(URL(fileURLWithPath: (folder as NSString).deletingLastPathComponent), home: home)
    }
}

/// Files collected from several places to act on together.
final class FileBuffer: ObservableObject {
    static let limit = 200
    @Published private(set) var urls: [URL] = []

    var isEmpty: Bool { urls.isEmpty }

    func add(_ url: URL) {
        let clean = url.standardizedFileURL
        guard !urls.contains(clean), urls.count < Self.limit else { return }
        urls.append(clean)
    }

    func remove(_ url: URL) { urls.removeAll { $0 == url.standardizedFileURL } }
    func clear() { urls = [] }

    /// Drops files that are no longer on the disk (moved or deleted since they were added).
    func prune(exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) { urls = urls.filter(exists) }
}
