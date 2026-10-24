import Cocoa
import FinderSync
import os

/// Adds Kriya's actions to Finder's right-click menu and toolbar button.
///
/// The extension runs in its own sandbox, so it does no file work itself. It reads the menu the app wrote, builds the
/// menu for the selection, and when an item is chosen it sends the app a request (`kriya://finder/run?…`) carrying the
/// item's id, the selected paths and a secret from the menu file.
final class FinderSync: FIFinderSync {
    private var cached: (modified: Date, file: FinderMenuFile)?
    /// What each menu item stands for, by its tag. Finder carries the menu to its own process and back, and drops anything
    /// attached to an item except its tag and title, so the item is looked up here when it is chosen.
    private var choices: [Int: (item: String, child: String?)] = [:]
    private var nextTag = 1
    /// What the extension did, readable with `log stream --predicate 'subsystem == "app.kriya.finder"'`. It never records
    /// file names, only what happened and how many.
    private let log = Logger(subsystem: "app.kriya.finder", category: "extension")

    override init() {
        super.init()
        // Watching the whole disk is what lets the menu appear for any folder (Apple's Finder Sync only adds a menu inside watched
        // folders, and a nil list adds it nowhere). This costs nothing extra: the extension implements no folder-observing or badge
        // callbacks, so Finder has nothing to call it about on large, network or cloud folders except to build the menu on a right-click.
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    // MARK: Toolbar

    override var toolbarItemName: String { "Kriya" }
    override var toolbarItemToolTip: String { "Kriya actions for the current folder" }
    override var toolbarItemImage: NSImage { NSImage(systemSymbolName: "cursorarrow.click.2", accessibilityDescription: "Kriya") ?? NSImage() }

    // MARK: The menu

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let menu = NSMenu(title: "")
        // Menus built before may still be on screen, so their tags stay valid; only a long list is cleared.
        if choices.count > 400 { choices.removeAll(); nextTag = 1 }
        guard menuKind != .contextualMenuForSidebar else { return menu }
        guard let file = loadFile() else {
            log.error("menu: the menu file could not be read")
            return menu
        }

        let controller = FIFinderSyncController.default()
        let background = menuKind == .contextualMenuForContainer || menuKind == .toolbarItemMenu
        let urls = background ? [] : (controller.selectedItemURLs() ?? [])
        // The folder being looked at, so a profile can limit an action to some places: the folder itself, or the one holding the selection.
        let place = controller.targetedURL()?.path ?? urls.first?.deletingLastPathComponent().path
        let selection = FinderMenuFile.Selection(
            count: background ? 1 : urls.count,
            folders: background ? 1 : urls.filter { $0.hasDirectoryPath }.count,
            extensions: urls.map { $0.hasDirectoryPath ? "" : $0.pathExtension.lowercased() },
            isBackground: background,
            folder: place
        )
        let items = file.visibleItems(for: selection)
        log.info("menu: kind \(menuKind.rawValue), \(selection.count) selected, \(items.count) actions")
        guard !items.isEmpty else { return menu }

        let container: NSMenu
        if file.flat {
            container = menu
        } else {
            container = NSMenu(title: file.title)
            let parent = NSMenuItem(title: file.title, action: nil, keyEquivalent: "")
            parent.submenu = container
            menu.addItem(parent)
        }
        for item in items {
            if let children = file.children(of: item, for: selection) {
                let parent = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
                let sub = NSMenu(title: item.title)
                for child in children { sub.addItem(entry(child.title, item: item.id, child: child.id)) }
                parent.submenu = sub
                container.addItem(parent)
            } else {
                container.addItem(entry(item.title, item: item.id, child: nil))
            }
        }
        return menu
    }

    private func entry(_ title: String, item: String, child: String?) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: #selector(choose(_:)), keyEquivalent: "")
        menuItem.target = self
        let tag = nextTag
        nextTag += 1
        choices[tag] = (item, child)
        menuItem.tag = tag
        return menuItem
    }

    // MARK: Choosing

    @objc private func choose(_ sender: NSMenuItem) {
        log.info("choose: a menu item was clicked")
        guard let chosen = choices[sender.tag] else {
            log.error("choose: the clicked item is not one this extension made (tag \(sender.tag))")
            return
        }
        let item = chosen.item
        guard let file = loadFile() else {
            log.error("choose: the menu file could not be read")
            return
        }
        let controller = FIFinderSyncController.default()
        let selected = (controller.selectedItemURLs() ?? []).map(\.path)
        let target = controller.targetedURL()?.path
        let request = FinderRequest(
            item: item,
            child: chosen.child,
            token: file.token,
            // With nothing selected the action is for the folder itself.
            paths: selected,
            target: selected.isEmpty ? target : nil
        )
        guard let url = request.url else {
            log.error("choose: the request address could not be made")
            return
        }
        log.info("choose: sending a request for \(item, privacy: .public), \(selected.count) selected, address \(url.absoluteString.count) characters")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        // Sent to the app this extension lives in (…/Kriya.app/Contents/PlugIns/KriyaFinder.appex), never to whichever copy of
        // Kriya macOS happens to have registered for the address: old build folders and mounted disk images do too.
        let host = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let log = self.log
        if host.pathExtension == "app" {
            NSWorkspace.shared.open([url], withApplicationAt: host, configuration: configuration) { _, error in
                if let error { log.error("choose: could not hand the request to the app: \((error as NSError).domain, privacy: .public) \((error as NSError).code)") } else { log.info("choose: the app accepted the request") }
            }
        } else {
            log.error("choose: the extension is not inside an app, sending to whichever is registered")
            NSWorkspace.shared.open(url, configuration: configuration)
        }
    }

    // MARK: The menu file

    /// `~/Library/Application Support/Kriya/finder-menu.json` in the real home folder, not the extension's container.
    private var menuFileURL: URL? {
        guard let home = getpwuid(getuid())?.pointee.pw_dir else { return nil }
        return URL(fileURLWithPath: String(cString: home)).appendingPathComponent("Library/Application Support/Kriya/finder-menu.json")
    }

    private func loadFile() -> FinderMenuFile? {
        guard let url = menuFileURL,
              let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return nil }
        if let cached, cached.modified == modified { return cached.file }
        guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(FinderMenuFile.self, from: data),
              file.version == 1 else { return nil }
        cached = (modified, file)
        return file
    }
}
