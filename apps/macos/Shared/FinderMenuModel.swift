import Foundation

/// The file the app writes and the Finder extension reads, and the request URL the extension sends back. This file is
/// compiled into both, so they cannot disagree about the format. It has no dependencies on the rest of the app.
struct FinderMenuFile: Codable, Equatable {
    struct Named: Codable, Equatable {
        var id: String
        var title: String
    }

    /// What a submenu holds, when an action offers a choice instead of acting at once.
    enum Submenu: String, Codable {
        case templates, folderTemplates, favoriteApps, conversions
    }

    struct Item: Codable, Equatable {
        var id: String
        var title: String
        /// "anything", "files", "folders", "single_item", "multiple_items", "archives" or "folder_background".
        var applies: String
        var extensions: [String]
        var submenu: Submenu?
    }

    var version = 1
    /// A secret only this user's processes can read. Requests without it are ignored, so a web page cannot trigger actions.
    var token: String
    var title: String
    var flat: Bool
    var items: [Item]
    var templates: [Named]
    var folderTemplates: [Named]
    var favoriteApps: [Named]
    /// Formats each file extension can be converted to.
    var conversions: [String: [Named]]

    static let archiveExtensions: Set<String> = ["zip", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "7z", "rar", "cpgz"]

    // MARK: Which actions a selection gets

    struct Selection: Equatable {
        var count: Int
        var folders: Int
        /// Lower-case extensions of the selected files, one per item (empty for a folder).
        var extensions: [String]
        /// A right-click on the empty space of a folder window.
        var isBackground: Bool

        var files: Int { count - folders }
        var allArchives: Bool { count > 0 && folders == 0 && extensions.allSatisfy { FinderMenuFile.archiveExtensions.contains($0) } }
    }

    func applies(_ item: Item, to selection: Selection) -> Bool {
        if selection.isBackground {
            return item.applies == "folder_background" || item.applies == "anything"
        }
        guard selection.count > 0 else { return false }
        switch item.applies {
        case "folder_background": return false
        case "files": if selection.folders > 0 { return false }
        case "folders": if selection.files > 0 { return false }
        case "single_item": if selection.count != 1 { return false }
        case "multiple_items": if selection.count < 2 { return false }
        case "archives": if !selection.allArchives { return false }
        default: break
        }
        if !item.extensions.isEmpty {
            let wanted = Set(item.extensions.map { $0.lowercased() })
            if selection.folders > 0 || !selection.extensions.allSatisfy({ wanted.contains($0) }) { return false }
        }
        return true
    }

    /// The conversion targets every selected file can become (the same for all of them).
    func conversionTargets(for selection: Selection) -> [Named] {
        guard selection.count > 0, selection.folders == 0 else { return [] }
        let lists = selection.extensions.map { conversions[$0] ?? [] }
        guard var common = lists.first else { return [] }
        for list in lists.dropFirst() {
            let ids = Set(list.map(\.id))
            common = common.filter { ids.contains($0.id) }
        }
        return common
    }

    /// The children of an item's submenu for a selection, or `nil` when the item acts directly.
    func children(of item: Item, for selection: Selection) -> [Named]? {
        switch item.submenu {
        case .none: return nil
        case .templates?: return templates
        case .folderTemplates?: return folderTemplates
        case .favoriteApps?: return favoriteApps
        case .conversions?: return conversionTargets(for: selection)
        }
    }

    /// The items shown for a selection, in the order the person arranged them. An item that would open an empty
    /// submenu (no favorite apps, no templates, nothing to convert to) is left out.
    func visibleItems(for selection: Selection) -> [Item] {
        items.filter { item in
            guard applies(item, to: selection) else { return false }
            if let children = children(of: item, for: selection) { return !children.isEmpty }
            return true
        }
    }
}

/// The request the extension sends the app, as the address `kriya://finder/run?…`.
struct FinderRequest: Equatable {
    var item: String
    var child: String?
    var token: String
    var paths: [String]
    /// The folder, for a right-click on its empty space.
    var target: String?

    static let scheme = "kriya"
    static let host = "finder"
    static let maxPaths = 5000

    var url: URL? {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        components.path = "/run"
        var query = [URLQueryItem(name: "item", value: item), URLQueryItem(name: "token", value: token)]
        if let child { query.append(URLQueryItem(name: "child", value: child)) }
        if let target { query.append(URLQueryItem(name: "target", value: target)) }
        if let data = try? JSONEncoder().encode(paths) {
            let encoded = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            query.append(URLQueryItem(name: "paths", value: encoded))
        }
        components.queryItems = query
        return components.url
    }

    init(item: String, child: String? = nil, token: String, paths: [String], target: String? = nil) {
        self.item = item
        self.child = child
        self.token = token
        self.paths = paths
        self.target = target
    }

    /// Reads a request address. Returns `nil` for anything that is not a well-formed request.
    init?(url: URL) {
        guard url.scheme == Self.scheme, url.host == Self.host, url.path == "/run",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        func value(_ name: String) -> String? { components.queryItems?.first { $0.name == name }?.value }
        guard let item = value("item"), !item.isEmpty, let token = value("token"), !token.isEmpty else { return nil }
        var paths: [String] = []
        if var encoded = value("paths")?.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") {
            while encoded.count % 4 != 0 { encoded += "=" }
            guard let data = Data(base64Encoded: encoded), let list = try? JSONDecoder().decode([String].self, from: data),
                  list.count <= Self.maxPaths else { return nil }
            paths = list
        }
        self.init(item: item, child: value("child"), token: token, paths: paths, target: value("target"))
    }
}
