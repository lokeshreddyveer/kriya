import AppKit
import Combine
import FinderSync

/// Everything behind the right-click menu: publishing the menu to the Finder extension, answering its requests, the
/// Services menu entries and the launcher shortcut.
final class FinderService: ObservableObject {
    let store: FinderStore
    let runner: FileActionRunner
    let launcher: FileLauncher
    let services: FinderServicesProvider

    @Published private(set) var isActive = false
    /// Whether the person has switched the Finder extension on in System Settings.
    @Published private(set) var extensionEnabled = false
    @Published private(set) var lastRequestProblem: String?

    private let batchWindow = BatchRenameWindow()
    private let toast = Toast()
    private var hotkeys: HotkeyCenter?
    private var cancellables = Set<AnyCancellable>()

    let destinations: FolderDestinations

    init(store: FinderStore, history: FileOperationHistory = FileOperationHistory(), destinations: FolderDestinations = .shared) {
        self.store = store
        self.destinations = destinations
        runner = FileActionRunner(store: store, history: history, destinations: destinations)
        launcher = FileLauncher(store: store, runner: runner)
        services = FinderServicesProvider()
        services.owner = self
        runner.presentBatchRename = { [batchWindow] names, others, rule, apply in
            batchWindow.present(names: names, others: others, rule: rule, apply: apply)
        }
        launcher.onProblem = { [toast] in toast.show($0, isError: true) }
        refreshExtensionStatus()
    }

    // MARK: Turning on and off

    func activate() {
        guard !isActive else { return }
        isActive = true
        store.setActive(true)
        hotkeys = HotkeyCenter(owner: "Right-click menu") { [weak self] _ in self?.launcher.show() }
        store.$config
            .receive(on: DispatchQueue.main)
            .sink { [weak self] config in self?.updateLauncherShortcut(config) }
            .store(in: &cancellables)
        refreshExtensionStatus()
        Log.info("Finder", "Right-click menu on")
    }

    func deactivate() {
        guard isActive else { return }
        isActive = false
        cancellables.removeAll()
        hotkeys?.unregisterAll()
        hotkeys = nil
        launcher.close()
        store.setActive(false)
        Log.info("Finder", "Right-click menu off")
    }

    private func updateLauncherShortcut(_ config: FinderConfig) {
        guard let key = config.launcherKeyCode, config.launcherModifiers != 0 else {
            hotkeys?.update([])
            return
        }
        hotkeys?.update([ShortcutBinding(command: "finder.launcher", keyCode: key, modifiers: config.launcherModifiers)])
    }

    func refreshExtensionStatus() {
        extensionEnabled = FIFinderSyncController.isExtensionEnabled
    }

    func openExtensionSettings() {
        FIFinderSyncController.showExtensionManagementInterface()
    }

    // MARK: Requests from the Finder extension

    /// Handles a `kriya://finder/run` address. Anything without the right secret, for an action that is not there, or with
    /// paths that do not exist is ignored, so a link on a web page cannot make Kriya touch files.
    @discardableResult
    func handle(url: URL) -> Bool {
        guard let request = FinderRequest(url: url) else { return false }
        guard request.token == store.token else {
            Log.warning("Finder", "Ignored a request with the wrong token")
            return false
        }
        guard isActive else {
            toast.show("Turn on Right-Click Menu in Kriya to use this.", isError: true)
            return true
        }
        guard let item = store.item(request.item), item.enabled else {
            toast.show("That action is no longer available.", isError: true)
            return true
        }
        let paths = request.paths.filter { $0.hasPrefix("/") && !$0.contains("\0") }.map { ($0 as NSString).standardizingPath }.filter(Self.isAllowedItem)
        // The folder to act in gets the same care as the selected items: a real folder, and not a system one.
        var target: String?
        if let asked = request.target {
            guard let safe = Self.safeTarget(asked) else {
                Log.warning("Finder", "Ignored a request for a folder that is not allowed")
                return true
            }
            target = safe
        }
        DispatchQueue.main.async { [runner] in
            runner.run(item, paths: paths, target: target, child: request.child)
        }
        return true
    }

    /// A selected item a request may act on: not a system location, even when reached through a link that points there.
    static func isAllowedItem(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains("\0") else { return false }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        for candidate in [path, resolved] {
            if candidate == "/" { return false }
            for blocked in ["/System", "/usr", "/bin", "/sbin", "/private/etc", "/private/var/db"] where candidate == blocked || candidate.hasPrefix(blocked + "/") { return false }
        }
        return true
    }

    /// A folder path a request may act in: absolute, standardized, an existing folder, and outside the system's own.
    static func safeTarget(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.contains("\0") else { return nil }
        let clean = (path as NSString).standardizingPath
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: clean, isDirectory: &isFolder), isFolder.boolValue else { return nil }
        return isAllowedItem(clean) ? clean : nil
    }

    // MARK: The Services menu

    /// Runs one of the shipped actions on the files a Services request carries.
    func runService(itemID: String, pasteboard: NSPasteboard) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        // The same rule as for requests from the Finder extension: nothing in a system folder, even through a link.
        let all = urls.map { ($0.path as NSString).standardizingPath }
        let paths = all.filter(Self.isAllowedItem)
        guard isActive else {
            toast.show("Turn on Right-Click Menu in Kriya to use this.", isError: true)
            return
        }
        guard !paths.isEmpty else {
            if !all.isEmpty { toast.show("Items in system folders are left alone.", isError: true) }
            return
        }
        if itemID == "launcher" {
            DispatchQueue.main.async { [launcher] in launcher.show(selection: FinderSelection(paths: paths, folder: nil)) }
            return
        }
        // A person may have deleted the shipped action; the service still has a meaning, so fall back to the original.
        guard let item = store.item(itemID) ?? finderDefaultItems().first(where: { $0.id == itemID }) else { return }
        DispatchQueue.main.async { [runner] in runner.run(item, paths: paths, target: nil, child: nil) }
    }
}

/// The entries in the Services menu (Finder › Services, and the right-click Services submenu). They must be declared in
/// the app's Info.plist; each message below matches one declared there.
final class FinderServicesProvider: NSObject {
    weak var owner: FinderService?

    private func run(_ id: String, _ pasteboard: NSPasteboard) { owner?.runService(itemID: id, pasteboard: pasteboard) }

    @objc func copyFullPath(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) { run("copy-path", pasteboard) }
    @objc func copyFileName(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) { run("copy-name", pasteboard) }
    @objc func copyParentPath(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) { run("copy-parent", pasteboard) }
    @objc func copyShellPath(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) { run("copy-shell-path", pasteboard) }
    @objc func openInTerminal(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) { run("open-terminal", pasteboard) }
    @objc func compressItems(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) { run("compress", pasteboard) }
    @objc func duplicateItems(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) { run("duplicate", pasteboard) }
    @objc func showActions(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) { run("launcher", pasteboard) }
}

/// The right-click menu as a switchable feature.
final class FinderFeature: FeatureModule {
    let feature = FeatureId.contextMenu
    private var context: ServiceContext?

    func start(context: ServiceContext) throws {
        self.context = context
        context.finder.activate()
    }

    func stop() {
        context?.finder.deactivate()
        context = nil
    }
}
