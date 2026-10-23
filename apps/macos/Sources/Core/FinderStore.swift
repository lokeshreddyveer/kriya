import AppKit
import UniformTypeIdentifiers
import Combine

extension FinderItem: Identifiable {}
extension FileTemplate: Identifiable {}
extension FolderTemplate: Identifiable {}

extension Applies {
    static var all: [Applies] { [.anything, .files, .folders, .singleItem, .multipleItems, .archives, .folderBackground] }

    var title: String {
        switch self {
        case .anything: return "Anything"
        case .files: return "Files only"
        case .folders: return "Folders only"
        case .singleItem: return "One item"
        case .multipleItems: return "Several items"
        case .archives: return "Archives"
        case .folderBackground: return "Empty space in a folder"
        }
    }

    /// The word the Finder extension's menu file uses.
    var menuWord: String {
        switch self {
        case .anything: return "anything"
        case .files: return "files"
        case .folders: return "folders"
        case .singleItem: return "single_item"
        case .multipleItems: return "multiple_items"
        case .archives: return "archives"
        case .folderBackground: return "folder_background"
        }
    }
}

extension PathStyle {
    static var all: [PathStyle] { [.full, .name, .nameWithoutExtension, .parent, .shellEscaped] }

    var title: String {
        switch self {
        case .full: return "Full path"
        case .name: return "File name"
        case .nameWithoutExtension: return "Name without extension"
        case .parent: return "Parent folder path"
        case .shellEscaped: return "Shell-escaped path"
        }
    }
}

extension FinderActionKind {
    /// A short description for the actions list.
    var summary: String {
        switch self {
        case .newFile(let name): return "Create “\(name)”"
        case .newFromTemplate(let id): return id == nil ? "Create a file from a template" : "Create a file from a chosen template"
        case .newFolder(let name): return "Create the folder “\(name)”"
        case .newFolderFromTemplate: return "Create a folder from a template"
        case .copyPath(let style): return "Copy: \(style.title.lowercased())"
        case .openInTerminal: return "Open the folder in a terminal"
        case .openWith(let id): return id == nil ? "Open with one of your favorite apps" : "Open with \(AppChoice.name(for: id ?? ""))"
        case .duplicate: return "Make a copy beside the original"
        case .rename: return "Rename the item"
        case .batchRename: return "Rename several items with rules"
        case .moveTo(let folder): return folder.map { "Move to \(($0 as NSString).lastPathComponent)" } ?? "Move to a folder you choose"
        case .copyTo(let folder): return folder.map { "Copy to \(($0 as NSString).lastPathComponent)" } ?? "Copy to a folder you choose"
        case .compress: return "Make a zip archive"
        case .extract: return "Unpack the archive beside it"
        case .convert: return "Change the file's format"
        case .copyMetadata: return "Copy size, dates and other details"
        case .runScript(let language, _): return language == .shell ? "Run your shell script" : "Run your AppleScript"
        case .runShortcut(let name): return "Run the Shortcut “\(name)”"
        case .runWorkflow: return "Run a workflow on the selected items"
        case .showHiddenFiles: return "Show or hide hidden files in Finder"
        case .openParentFolder: return "Open the folder that holds the item"
        case .newFolders: return "Create several folders at once"
        case .findLargeFiles(let mb): return "List files of \(mb) MB or more in the folder"
        case .cleanupFolder: return "Sort loose files into folders by kind"
        case .undoLast: return "Put back what the last tidy-up moved"
        case .copyChecksum: return "Copy the file's SHA-256 checksum"
        case .removeQuarantine: return "Remove the download warning macOS puts on files"
        case .makeAlias: return "Make an alias beside the item"
        }
    }

    var symbol: String {
        switch self {
        case .newFile, .newFromTemplate: return "doc.badge.plus"
        case .newFolder, .newFolderFromTemplate: return "folder.badge.plus"
        case .copyPath, .copyMetadata: return "doc.on.clipboard"
        case .openInTerminal: return "terminal"
        case .openWith: return "arrow.up.forward.app"
        case .duplicate: return "plus.square.on.square"
        case .rename, .batchRename: return "pencil"
        case .moveTo: return "folder"
        case .copyTo: return "folder.badge.gearshape"
        case .compress: return "archivebox"
        case .extract: return "shippingbox"
        case .convert: return "arrow.triangle.2.circlepath"
        case .runScript: return "applescript"
        case .runShortcut: return "square.2.layers.3d"
        case .runWorkflow: return "gearshape.2"
        case .showHiddenFiles: return "eye"
        case .openParentFolder: return "arrow.turn.left.up"
        case .newFolders: return "folder.badge.plus"
        case .findLargeFiles: return "magnifyingglass"
        case .cleanupFolder: return "sparkles"
        case .undoLast: return "arrow.uturn.backward"
        case .copyChecksum: return "number.circle"
        case .removeQuarantine: return "checkmark.shield"
        case .makeAlias: return "arrow.turn.up.right"
        }
    }
}

/// The Finder and right-click actions, templates and settings. Every change is also written to the file the Finder
/// extension reads, so the menu in Finder always matches what is shown here.
final class FinderStore: ObservableObject {
    @Published private(set) var items: [FinderItem] = []
    @Published private(set) var config = defaultFinderConfig()
    @Published private(set) var fileTemplates: [FileTemplate] = []
    @Published private(set) var folderTemplates: [FolderTemplate] = []
    @Published var lastError: String?

    private let core: KriyaCore
    let menuFile: URL
    private let defaults: UserDefaults
    private var active = false

    init(core: KriyaCore, menuFile: URL, defaults: UserDefaults = .standard) {
        self.core = core
        self.menuFile = menuFile
        self.defaults = defaults
        reload()
    }

    func reload() {
        do {
            items = try core.finderItems()
            config = try core.finderConfig()
            fileTemplates = try core.fileTemplates()
            folderTemplates = try core.folderTemplates()
        } catch {
            Log.error("Finder", "Could not load Finder actions: \(error.userMessage)")
        }
        publish()
    }

    // MARK: The secret shared with the extension

    /// Created once and kept. The extension sends it with every request; anything without it is ignored.
    var token: String {
        if let saved = defaults.string(forKey: "finderRequestToken"), saved.count >= 32 { return saved }
        let fresh = (0..<2).map { _ in UUID().uuidString }.joined().replacingOccurrences(of: "-", with: "")
        defaults.set(fresh, forKey: "finderRequestToken")
        return fresh
    }

    func rotateToken() {
        defaults.removeObject(forKey: "finderRequestToken")
        publish()
    }

    // MARK: Editing

    func item(_ id: String) -> FinderItem? { items.first { $0.id == id } }

    func setItems(_ list: [FinderItem]) {
        perform { try core.saveFinderItems(items: list) }
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        setItems(items.map { var i = $0; if i.id == id { i.enabled = enabled }; return i })
    }

    func move(from source: IndexSet, to destination: Int) {
        var list = items
        list.move(fromOffsets: source, toOffset: destination)
        setItems(list)
    }

    func upsert(_ item: FinderItem) {
        var list = items
        if let index = list.firstIndex(where: { $0.id == item.id }) { list[index] = item } else { list.append(item) }
        setItems(list)
    }

    func delete(_ id: String) {
        setItems(items.filter { $0.id != id })
    }

    func updateConfig(_ change: (inout FinderConfig) -> Void) {
        var updated = config
        change(&updated)
        perform { try core.saveFinderConfig(config: updated) }
    }

    func saveTemplate(_ template: FileTemplate) { perform { try core.saveFileTemplate(template: template) } }
    func deleteTemplate(_ id: String) { perform { try core.deleteFileTemplate(id: id) } }
    func saveFolderTemplate(_ template: FolderTemplate) { perform { try core.saveFolderTemplate(template: template) } }
    func deleteFolderTemplate(_ id: String) { perform { try core.deleteFolderTemplate(id: id) } }

    /// Adds the ready-made actions (an editor, hidden files, the parent folder) that are not in the list yet. An app
    /// that is not installed is left out. Returns how many were added.
    @discardableResult
    func addSuggested() -> Int {
        let have = Set(items.map(\.id))
        let fresh = finderSuggestedItems().filter { item in
            guard !have.contains(item.id) else { return false }
            if case .openWith(let appID) = item.kind, let appID { return NSWorkspace.shared.urlForApplication(withBundleIdentifier: appID) != nil }
            return true
        }
        guard !fresh.isEmpty else { return 0 }
        setItems(items + fresh)
        return fresh.count
    }

    /// Asks macOS to open each listed kind of file with its app. macOS may ask the person to confirm. Returns what went wrong.
    func applyDefaultApps() async -> [String] {
        var problems: [String] = []
        for entry in config.defaultApps {
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.appId),
                  let type = UTType(filenameExtension: entry.extension) else {
                problems.append(".\(entry.extension): the app or the file type was not found")
                continue
            }
            do {
                try await NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: type)
            } catch {
                problems.append(".\(entry.extension): \(error.localizedDescription)")
            }
        }
        return problems
    }

    func restoreDefaults(everything: Bool) {
        perform { try core.restoreDefaultFinderSettings(everything: everything) }
    }

    private func perform(_ work: () throws -> Void) {
        do {
            try work()
            lastError = nil
        } catch {
            lastError = error.userMessage
        }
        reload()
    }

    // MARK: The menu file

    /// Starts or stops offering the menu in Finder. While inactive the file holds no actions, so Finder's menu is empty.
    func setActive(_ on: Bool) {
        active = on
        publish()
    }

    /// The menu as the extension sees it. `forceActive` is for the launcher, which lists actions even while the Finder menu is off.
    func menuFileContents(forceActive: Bool = false) -> FinderMenuFile {
        let enabled = active || forceActive ? items.filter(\.enabled) : []
        let apps = config.favoriteApps.compactMap { id -> FinderMenuFile.Named? in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) == nil ? nil : FinderMenuFile.Named(id: id, title: AppChoice.name(for: id))
        }
        return FinderMenuFile(
            token: token,
            title: config.menuTitle,
            flat: config.menuStyle == .flat,
            items: enabled.map { item in
                FinderMenuFile.Item(id: item.id, title: item.title, applies: item.applies.menuWord, extensions: item.extensions, submenu: Self.submenu(of: item.kind))
            },
            templates: fileTemplates.map { FinderMenuFile.Named(id: $0.id, title: $0.name) },
            folderTemplates: folderTemplates.map { FinderMenuFile.Named(id: $0.id, title: $0.name) },
            favoriteApps: apps,
            conversions: Converter.menuMap()
        )
    }

    static func submenu(of kind: FinderActionKind) -> FinderMenuFile.Submenu? {
        switch kind {
        case .newFromTemplate(let id) where id == nil: return .templates
        case .newFolderFromTemplate(let id) where id == nil: return .folderTemplates
        case .openWith(let id) where id == nil: return .favoriteApps
        case .convert(let target) where target == nil: return .conversions
        default: return nil
        }
    }

    private func publish() {
        do {
            let data = try JSONEncoder().encode(menuFileContents())
            try FileManager.default.createDirectory(at: menuFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: menuFile, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: menuFile.path)
        } catch {
            Log.warning("Finder", "Could not write the Finder menu file")
        }
    }
}
