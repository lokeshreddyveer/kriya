import Foundation

/// A folder offered in the Move to / Copy to chooser.
struct DestinationChoice: Identifiable, Equatable {
    let path: String
    let isFavorite: Bool
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }

    /// The path as a person writes it, with the home folder as "~".
    var shortPath: String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

/// Where the person has moved or copied things lately, and the folders they starred. It keeps folder paths only (nothing
/// about the items), drops folders that no longer exist, and never offers a system folder.
final class FolderDestinations: ObservableObject {
    static let recentLimit = 12
    static let favoriteLimit = 30

    @Published private(set) var favorites: [String]
    @Published private(set) var recents: [String]

    private let defaults: UserDefaults
    private let key: String
    private let isFolder: (String) -> Bool
    private let isProtected: (String) -> Bool

    init(
        defaults: UserDefaults = .standard,
        key: String = "finder.destinations.v1",
        isFolder: @escaping (String) -> Bool = { var d: ObjCBool = false; return FileManager.default.fileExists(atPath: $0, isDirectory: &d) && d.boolValue },
        isProtected: @escaping (String) -> Bool = { ProtectedPaths.isProtected($0) && $0 != NSHomeDirectory() }
    ) {
        self.defaults = defaults
        self.key = key
        self.isFolder = isFolder
        self.isProtected = isProtected
        let saved = defaults.dictionary(forKey: key)
        favorites = saved?["favorites"] as? [String] ?? []
        recents = saved?["recents"] as? [String] ?? []
    }

    /// The folder as it is kept: links followed, no trailing slash, so the same folder never appears twice.
    static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.path
    }

    func isFavorite(_ path: String) -> Bool { favorites.contains(Self.normalized(path)) }

    /// Notes that items were sent to this folder.
    func used(_ path: String) {
        let folder = Self.normalized(path)
        guard !isProtected(folder), folder != "/" else { return }
        recents.removeAll { $0 == folder }
        recents.insert(folder, at: 0)
        recents = Array(recents.prefix(Self.recentLimit))
        save()
    }

    func toggleFavorite(_ path: String) {
        let folder = Self.normalized(path)
        if let index = favorites.firstIndex(of: folder) {
            favorites.remove(at: index)
        } else {
            guard !isProtected(folder), folder != "/", favorites.count < Self.favoriteLimit else { return }
            favorites.append(folder)
        }
        save()
    }

    func forget(_ path: String) {
        let folder = Self.normalized(path)
        recents.removeAll { $0 == folder }
        save()
    }

    /// What to list: favorites first, then recent folders that are not favorites, narrowed by what was typed. A search
    /// matches every word typed against the folder's name or path, ignoring case.
    func choices(matching query: String = "") -> [DestinationChoice] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        var seen = Set<String>()
        var result: [DestinationChoice] = []
        for (path, starred) in favorites.map({ ($0, true) }) + recents.map({ ($0, false) }) where !seen.contains(path) {
            guard isFolder(path), !isProtected(path) else { continue }
            seen.insert(path)
            let haystack = path.lowercased()
            if words.allSatisfy({ haystack.contains($0) }) { result.append(DestinationChoice(path: path, isFavorite: starred)) }
        }
        return result
    }

    private func save() {
        defaults.set(["favorites": favorites, "recents": recents], forKey: key)
    }
}
