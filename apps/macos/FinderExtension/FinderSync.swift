import Cocoa
import FinderSync

/// Adds Kriya's actions to Finder's right-click menu and toolbar button.
///
/// The extension runs in its own sandbox, so it does no file work itself. It reads the menu the app wrote, builds the
/// menu for the selection, and when an item is chosen it sends the app a request (`kriya://finder/run?…`) carrying the
/// item's id, the selected paths and a secret from the menu file.
final class FinderSync: FIFinderSync {
    private var cached: (modified: Date, file: FinderMenuFile)?

    override init() {
        super.init()
        // Watching the whole disk is what lets the menu appear for any folder.
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    // MARK: Toolbar

    override var toolbarItemName: String { "Kriya" }
    override var toolbarItemToolTip: String { "Kriya actions for the current folder" }
    override var toolbarItemImage: NSImage { NSImage(systemSymbolName: "cursorarrow.click.2", accessibilityDescription: "Kriya") ?? NSImage() }

    // MARK: The menu

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let menu = NSMenu(title: "")
        guard menuKind != .contextualMenuForSidebar, let file = loadFile() else { return menu }

        let controller = FIFinderSyncController.default()
        let background = menuKind == .contextualMenuForContainer || menuKind == .toolbarItemMenu
        let urls = background ? [] : (controller.selectedItemURLs() ?? [])
        let selection = FinderMenuFile.Selection(
            count: background ? 1 : urls.count,
            folders: background ? 1 : urls.filter { $0.hasDirectoryPath }.count,
            extensions: urls.map { $0.hasDirectoryPath ? "" : $0.pathExtension.lowercased() },
            isBackground: background
        )
        let items = file.visibleItems(for: selection)
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
        menuItem.representedObject = ["item": item, "child": child ?? ""]
        return menuItem
    }

    // MARK: Choosing

    @objc private func choose(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String], let item = info["item"],
              let file = loadFile() else { return }
        let controller = FIFinderSyncController.default()
        let selected = (controller.selectedItemURLs() ?? []).map(\.path)
        let target = controller.targetedURL()?.path
        let request = FinderRequest(
            item: item,
            child: info["child"].flatMap { $0.isEmpty ? nil : $0 },
            token: file.token,
            // With nothing selected the action is for the folder itself.
            paths: selected,
            target: selected.isEmpty ? target : nil
        )
        guard let url = request.url else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open(url, configuration: configuration)
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
