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
    static var all: [PathStyle] { [.full, .name, .nameWithoutExtension, .parent, .shellEscaped, .fileUrl, .hfs, .markdownLink, .htmlLink, .jsonArray, .csvList] }

    var title: String {
        switch self {
        case .full: return "Full path"
        case .name: return "File name"
        case .nameWithoutExtension: return "Name without extension"
        case .parent: return "Parent folder path"
        case .shellEscaped: return "Shell-escaped path"
        case .fileUrl: return "file:// URL"
        case .hfs: return "HFS path"
        case .markdownLink: return "Markdown link"
        case .htmlLink: return "HTML link"
        case .jsonArray: return "JSON array"
        case .csvList: return "CSV list"
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
        case .editTags: return "Add Finder tags to the items"
        case .editComment: return "Write a Finder comment on the items"
        case .share: return "Open the share menu for the items"
        case .copyPathAs: return "A submenu of path formats: URL, Markdown link, JSON and more"
        case .openInIde: return "A submenu of the code editors and terminals on this Mac"
        case .toFolderSet(let copy): return copy ? "A submenu of your saved folder sets to copy into" : "A submenu of your saved folder sets to move into"
        case .quickTag: return "A submenu of one-click tag and comment presets"
        case .inspect: return "A submenu of read-only looks: permissions, signature, quarantine, size"
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
        case .editTags: return "tag"
        case .editComment: return "text.bubble"
        case .share: return "square.and.arrow.up"
        case .copyPathAs: return "link"
        case .openInIde: return "chevron.left.forwardslash.chevron.right"
        case .toFolderSet: return "folder.badge.plus"
        case .quickTag: return "tag"
        case .inspect: return "info.circle"
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
    /// Saved destination groups, one-click tag presets and where each action shows. Kept in preferences, written to the menu file.
    @Published var tagPresets: [FinderTagPreset] { didSet { save(tagPresets, "finderTagPresets.v1"); publish() } }
    @Published var profiles: [FinderMenuFile.Profile] { didSet { save(profiles, "finderProfiles.v1"); publish() } }

    private let core: KriyaCore
    let menuFile: URL
    private let defaults: UserDefaults
    private var active = false

    init(core: KriyaCore, menuFile: URL, defaults: UserDefaults = .standard) {
        self.core = core
        self.menuFile = menuFile
        self.defaults = defaults
        func load<T: Decodable>(_ key: String, _ fallback: T) -> T { defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) } ?? fallback }
        tagPresets = load("finderTagPresets.v1", FinderPresets.defaultTagPresets)
        profiles = load("finderProfiles.v1", [FinderMenuFile.Profile]())
        reload()
        // The folder sets are the same ones the Finder windows and the launcher use; a change shows in Finder's menu at once.
        FolderSetStore.shared.$sets.dropFirst().sink { [weak self] _ in self?.publish() }.store(in: &bag)
    }

    private var bag = Set<AnyCancellable>()

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    /// Adds the starter file types (JSON, CSV, Python, Swift…) that are not in the template list yet. Returns how many were added.
    @discardableResult
    func addStarterTemplates() -> Int {
        let fresh = FinderPresets.missingStarters(existing: fileTemplates.map(\.id))
        for template in fresh { saveTemplate(template) }
        return fresh.count
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
        let fresh = PrivateFile.randomHex() ?? (0..<2).map { _ in UUID().uuidString }.joined().replacingOccurrences(of: "-", with: "")
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
            conversions: Converter.menuMap(),
            extras: FinderMenuFile.Extras(
                pathFormats: FinderPresets.pathFormats.map { FinderMenuFile.Named(id: $0.word, title: $0.title) },
                ides: FinderPresets.ideCatalog.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.id) != nil }.map { FinderMenuFile.Named(id: $0.id, title: $0.name) },
                folderSets: FinderPresets.destinationChoices(FolderSetStore.shared.sets),
                quickTags: tagPresets.map { FinderMenuFile.Named(id: $0.id, title: $0.title) },
                inspections: FinderPresets.inspections.map { FinderMenuFile.Named(id: $0.id, title: $0.title) }
            ),
            profiles: profiles.isEmpty ? nil : profiles
        )
    }

    static func submenu(of kind: FinderActionKind) -> FinderMenuFile.Submenu? {
        switch kind {
        case .newFromTemplate(let id) where id == nil: return .templates
        case .newFolderFromTemplate(let id) where id == nil: return .folderTemplates
        case .openWith(let id) where id == nil: return .favoriteApps
        case .convert(let target) where target == nil: return .conversions
        case .copyPathAs: return .pathFormats
        case .openInIde: return .ides
        case .toFolderSet(let copy): return copy ? .folderSetsCopy : .folderSetsMove
        case .quickTag: return .quickTags
        case .inspect: return .inspect
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
