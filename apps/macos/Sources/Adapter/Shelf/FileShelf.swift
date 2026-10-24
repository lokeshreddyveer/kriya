import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One thing held on the shelf, as the panel shows it.
struct ShelfItem: Identifiable {
    enum Kind {
        case file(URL)
        case text(String)
        case image(NSImage)
    }

    let id: String
    let kind: Kind
    let record: ShelfRecord

    init?(record: ShelfRecord, store: ShelfLibraryStore = .shared) {
        self.record = record
        id = record.id
        switch record.kind {
        case .file: kind = .file(URL(fileURLWithPath: record.value))
        case .text: kind = .text(record.value)
        case .image:
            guard let image = store.image(named: record.value) else { return nil }
            kind = .image(image)
        }
    }

    var title: String { record.title }

    var icon: NSImage {
        switch kind {
        case .file(let url): return NSWorkspace.shared.icon(forFile: url.path)
        case .text: return NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: nil) ?? NSImage()
        case .image(let image): return image
        }
    }

    /// What is handed to another app when the item is dragged out.
    var provider: NSItemProvider {
        switch kind {
        case .file(let url): return NSItemProvider(contentsOf: url) ?? NSItemProvider(object: url as NSURL)
        case .text(let text): return NSItemProvider(object: text as NSString)
        case .image(let image): return NSItemProvider(object: image)
        }
    }
}

/// The panel's view of the saved shelves: what is on the current shelf, and adding to it.
final class ShelfModel: ObservableObject {
    let store = ShelfLibraryStore.shared
    @Published var targeted = false
    @Published var query = ""
    /// Show only this group. New items dropped meanwhile go into it.
    @Published var groupFilter: String?
    /// The item being dragged inside the panel, so dropping it on a group chip moves it there.
    var draggingItemID: String?
    /// The workflows that can be run on the shelf's contents, and how to run one. Set by the app.
    var workflows: () -> [(id: String, name: String)] = { [] }
    var runWorkflow: (String, String) -> Void = { _, _ in }

    var items: [ShelfItem] {
        store.library.current.items.filter { groupFilter == nil || $0.group == groupFilter }.compactMap { ShelfItem(record: $0, store: store) }
    }

    func addFile(_ url: URL, group: String? = nil) { let g = group ?? groupFilter; store.change { _ = $0.add(ShelfRecord(kind: .file, value: url.path, added: Date(), group: g)) } }
    func addText(_ text: String, group: String? = nil) { let g = group ?? groupFilter; store.change { _ = $0.add(ShelfRecord(kind: .text, value: text, added: Date(), group: g)) } }
    func addImage(_ image: NSImage, group: String? = nil) {
        guard let name = store.storeImage(image) else { return }
        let g = group ?? groupFilter
        store.change { _ = $0.add(ShelfRecord(kind: .image, value: name, added: Date(), group: g)) }
    }
}

/// A small panel that holds files, text and images while you move them between apps. Drop things on it, then drag them
/// out into any app or folder. It appears when the pointer is shaken while dragging files, or from a shortcut.
final class FileShelf: NSObject, NSWindowDelegate, ObservableObject {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private let store: ScreenToolsStore
    private let model = ShelfModel()
    private var panel: Panel?
    private var monitors: [Any] = []
    private var hideWork: DispatchWorkItem?

    // Shake and drag watching.
    private var dragStartCount = 0
    private var draggingFiles = false
    private var trail: [(x: CGFloat, time: Date)] = []
    private var lastShown = Date.distantPast

    init(store: ScreenToolsStore) {
        self.store = store
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Starts or stops watching for drags to match the settings.
    func apply() {
        let config = store.current
        if config.shelfEnabled, config.shelfOnShake || config.shelfOnDrag {
            guard monitors.isEmpty else { return }
            if let down = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] _ in self?.mouseDown() }) { monitors.append(down) }
            if let drag = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged], handler: { [weak self] _ in self?.dragged() }) { monitors.append(drag) }
            if let up = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp], handler: { [weak self] _ in self?.released() }) { monitors.append(up) }
        } else {
            for monitor in monitors { NSEvent.removeMonitor(monitor) }
            monitors.removeAll()
        }
        if !config.shelfEnabled { hide() }
    }

    func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        hide()
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    // MARK: Drag watching

    private func mouseDown() {
        dragStartCount = NSPasteboard(name: .drag).changeCount
        draggingFiles = false
        trail.removeAll()
    }

    private func dragged() {
        let config = store.current
        // Files are being dragged once the drag pasteboard has changed and holds file addresses.
        if !draggingFiles {
            let board = NSPasteboard(name: .drag)
            guard board.changeCount != dragStartCount, board.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return }
            if let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, config.shelfExcludedAppIds.contains(id) { return }
            draggingFiles = true
            if config.shelfOnDrag { show() }
        }
        guard config.shelfOnShake, !isVisible else { return }
        let now = Date()
        trail.append((NSEvent.mouseLocation.x, now))
        trail.removeAll { now.timeIntervalSince($0.time) > 0.7 }
        var turns = 0
        var last: CGFloat = 0
        for index in 1..<max(trail.count, 1) {
            let dx = trail[index].x - trail[index - 1].x
            guard abs(dx) > 10 else { continue }
            if last != 0, dx.sign != last.sign { turns += 1 }
            last = dx
        }
        if turns >= 3, now.timeIntervalSince(lastShown) > 1 { show() }
    }

    private func released() {
        draggingFiles = false
        trail.removeAll()
    }

    // MARK: Showing

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        lastShown = Date()
        place(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            panel.animator().alphaValue = 1
        }
        scheduleAutoHide()
    }

    func hide() {
        hideWork?.cancel()
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
    }

    private func place(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        var origin: NSPoint
        switch store.current.shelfEdge {
        case .left: origin = NSPoint(x: frame.minX + 12, y: frame.midY - size.height / 2)
        case .right: origin = NSPoint(x: frame.maxX - size.width - 12, y: frame.midY - size.height / 2)
        case .bottom: origin = NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 12)
        case .pointer: origin = NSPoint(x: mouse.x + 24, y: mouse.y - size.height / 2)
        }
        origin.x = min(max(origin.x, frame.minX + 8), frame.maxX - size.width - 8)
        origin.y = min(max(origin.y, frame.minY + 8), frame.maxY - size.height - 8)
        panel.setFrameOrigin(origin)
    }

    /// Hides the shelf a while after the pointer leaves it, when the person asked for that.
    private func scheduleAutoHide() {
        hideWork?.cancel()
        let seconds = store.current.shelfAutoHideSeconds
        guard seconds > 0 else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.panel, panel.isVisible else { return }
            if panel.frame.insetBy(dx: -20, dy: -20).contains(NSEvent.mouseLocation) || self.draggingFiles {
                self.scheduleAutoHide()
            } else {
                self.hide()
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func makePanel() -> Panel {
        let panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 360), styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: ShelfView(model: model, onClose: { [weak self] in self?.hide() }))
        return panel
    }

    /// Puts a file on the current shelf and shows the shelf.
    func add(file url: URL) {
        model.addFile(url)
        show()
    }

    func add(text: String) {
        model.addText(text)
    }

    /// Workflows for the shelf's "Run Workflow" action. Set by the app.
    var workflows: () -> [(id: String, name: String)] {
        get { model.workflows }
        set { model.workflows = newValue }
    }
    var runWorkflow: (String, String) -> Void {
        get { model.runWorkflow }
        set { model.runWorkflow = newValue }
    }

    /// Dropping on the menu-bar icon: a new shelf holding what was dropped, shown at once.
    @discardableResult
    func createShelf(from board: NSPasteboard) -> Bool {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
        var created = false
        ShelfLibraryStore.shared.change { created = $0.addShelf(named: "Dropped \(stamp)") != nil }
        guard created else { return false }
        model.groupFilter = nil
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            for url in urls { model.addFile(url) }
        } else if let image = NSImage(pasteboard: board) {
            model.addImage(image)
        } else if let text = board.string(forType: .string), !text.isEmpty {
            model.addText(text)
        }
        show()
        return true
    }

    func addClipboard() {
        let board = NSPasteboard.general
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            for url in urls { model.addFile(url) }
        } else if let image = NSImage(pasteboard: board) {
            model.addImage(image)
        } else if let text = board.string(forType: .string), !text.isEmpty {
            model.addText(text)
        }
        show()
    }
}

private struct ShelfView: View {
    @ObservedObject var model: ShelfModel
    @ObservedObject private var store = ShelfLibraryStore.shared
    let onClose: () -> Void
    @State private var hovered: String?
    @State private var searching = false
    @State private var showingHistory = false
    @State private var newName = ""
    @State private var naming: Naming?
    @State private var renamingGroup: String?
    @State private var groupingItem: String?
    @State private var grid = false

    private enum Naming { case new, rename }

    private var library: ShelfLibrary { store.library }

    var body: some View {
        VStack(spacing: 0) {
            header
            if searching { searchField }
            groupBar
            Divider()
            content
            Divider()
            footer
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(model.targeted ? Theme.accent : Color.primary.opacity(0.22), lineWidth: model.targeted ? 2 : 1))
        .animation(.smooth(duration: 0.15), value: model.targeted)
        .animation(.smooth(duration: 0.2), value: library.current.items.count)
        .onDrop(of: [.fileURL, .url, .image, .plainText], isTargeted: $model.targeted) { providers in
            load(providers)
            return true
        }
        .onKeyPress(.escape) {
            if searching { searching = false; model.query = ""; return .handled }
            onClose()
            return .handled
        }
        .alert("New Group", isPresented: Binding(get: { groupingItem != nil }, set: { if !$0 { groupingItem = nil } })) {
            TextField("Name", text: $newName)
            Button("OK") { if let id = groupingItem { let name = newName; store.change { $0.setGroup(name, for: id) } }; groupingItem = nil }
            Button("Cancel", role: .cancel) { groupingItem = nil }
        }
        .alert("Rename Group", isPresented: Binding(get: { renamingGroup != nil }, set: { if !$0 { renamingGroup = nil } })) {
            TextField("Name", text: $newName)
            Button("OK") {
                if let old = renamingGroup {
                    let name = newName
                    store.change { $0.renameGroup(old, to: name) }
                    if model.groupFilter == old { model.groupFilter = name.trimmingCharacters(in: .whitespacesAndNewlines) }
                }
                renamingGroup = nil
            }
            Button("Cancel", role: .cancel) { renamingGroup = nil }
        }
        .alert(naming == .new ? "New Shelf" : "Rename Shelf", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Name", text: $newName)
            Button("OK") {
                let name = newName
                store.change { if naming == .new { _ = $0.addShelf(named: name) } else { $0.rename($0.currentID, to: name) } }
                naming = nil
            }
            Button("Cancel", role: .cancel) { naming = nil }
        }
    }

    // MARK: Header and footer

    private var header: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(library.shelves) { shelf in
                    Button { store.change { $0.select(shelf.id) } } label: {
                        Label("\(shelf.name) (\(shelf.items.count))", systemImage: shelf.id == library.currentID ? "checkmark" : "tray")
                    }
                }
                Divider()
                Button("New Shelf…") { newName = ""; naming = .new }.disabled(library.shelves.count >= ShelfLibrary.maxShelves)
                Button("Rename This Shelf…") { newName = library.current.name; naming = .rename }
                Button("Delete This Shelf", role: .destructive) { store.change { $0.deleteShelf($0.currentID) } }.disabled(library.shelves.count < 2)
                Divider()
                Toggle("Do Not Save This Shelf", isOn: Binding(get: { library.current.temporary == true }, set: { on in store.change { lib in if let i = lib.shelves.firstIndex(where: { $0.id == lib.currentID }) { lib.shelves[i].temporary = on ? true : nil } } }))
                Button("Export This Shelf…") { exportShelf(encrypted: false) }
                Button("Export Encrypted…") { exportShelf(encrypted: true) }
                Button("Import a Shelf…") { importShelf() }.disabled(library.shelves.count >= ShelfLibrary.maxShelves)
            } label: {
                Label(library.current.name, systemImage: "tray").font(.headline)
            }
            .menuStyle(.borderlessButton).fixedSize()
            if library.current.temporary == true { Image(systemName: "eye.slash").foregroundStyle(.secondary).help("This shelf is not saved: it is gone when Kriya quits") }
            Spacer()
            instantMenu
            Button { searching.toggle(); if !searching { model.query = "" } } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless).help("Search every shelf and the history").accessibilityLabel("Search every shelf and the history")
            Button("Add Clipboard") { add(NSPasteboard.general) }.controlSize(.small)
            Button { store.change { $0.clear() } } label: { Image(systemName: "trash") }.accessibilityLabel("Clear this shelf")
                .buttonStyle(.borderless).help("Clear this shelf (it goes to the history)").disabled(library.current.items.isEmpty)
            Button(action: onClose) { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless).foregroundStyle(.secondary).accessibilityLabel("Close the shelf")
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    // MARK: Instant actions

    private var fileURLs: [URL] { model.items.compactMap { if case .file(let url) = $0.kind { return url } else { return nil } } }
    private var textItems: [String] { model.items.compactMap { if case .text(let t) = $0.kind { return t } else { return nil } } }

    private var instantMenu: some View {
        Menu {
            let files = fileURLs
            Menu("Make Pictures Smaller") {
                ForEach([1920, 1280, 800], id: \.self) { edge in Button("\(edge) px") { run { ShelfInstant.resize(files, maxEdge: CGFloat(edge)) } } }
            }.disabled(ShelfInstant.images(files).isEmpty)
            Menu("Change Picture Format To") {
                ForEach([CaptureFormat.png, .jpeg, .heic], id: \.self) { f in Button(f.title) { run { ShelfInstant.convert(files, to: f) } } }
            }.disabled(ShelfInstant.images(files).isEmpty)
            Button("Combine Pictures into a PDF") { run { ShelfInstant.pdf(files) } }.disabled(ShelfInstant.images(files).isEmpty)
            Button("Copy Text from Pictures") { readText(files) }.disabled(ShelfInstant.images(files).isEmpty)
            Divider()
            Button("Copy All Paths") { copy(ShelfInstant.paths(files), "Copied \(files.count) path\(files.count == 1 ? "" : "s")") }.disabled(files.isEmpty)
            Button("Copy Everything as Text") { copy((files.map(\.path) + textItems).joined(separator: "\n"), "Copied") }.disabled(model.items.isEmpty)
            Button("Send Text to Notes") { sendNotes() }.disabled(textItems.isEmpty)
            Button("Compress to ZIP") { zipAll() }.disabled(files.isEmpty)
            if CaptureUploadStore.shared.ready {
                Button("Upload to My Bucket and Copy Links") { uploadFiles(files) }.disabled(files.isEmpty)
            }
            let flows = model.workflows()
            if !flows.isEmpty {
                Divider()
                Menu("Run Workflow on the Shelf") {
                    ForEach(flows, id: \.id) { flow in Button(flow.name) { model.runWorkflow(flow.id, (files.map(\.path) + textItems).joined(separator: "\n")) } }
                }
            }
        } label: { Image(systemName: "bolt.fill") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Instant actions on what is on this shelf")
            .disabled(model.items.isEmpty)
    }

    /// Runs a file action off the main thread, then adds what it made to the shelf and says what happened.
    private func run(_ work: @escaping () -> ShelfInstant.Outcome) {
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = work()
            DispatchQueue.main.async {
                for url in outcome.outputs { model.addFile(url) }
                Toast().show(outcome.message, isError: outcome.isError)
            }
        }
    }

    private func copy(_ text: String, _ done: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        Toast().show(done)
    }

    private func readText(_ files: [URL]) {
        Toast().show("Reading the pictures…")
        DispatchQueue.global(qos: .userInitiated).async {
            let text = ShelfInstant.text(in: files)
            DispatchQueue.main.async {
                guard !text.isEmpty else { Toast().show("No text found in those pictures.", isError: true); return }
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                model.addText(text)
                Toast().show("Copied the text, and kept it on the shelf")
            }
        }
    }

    private func sendNotes() {
        let text = textItems.joined(separator: "\n\n")
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = ShelfInstant.sendToNotes(text)
            DispatchQueue.main.async { Toast().show(ok ? "Made a note" : "Notes would not take it. Allow Kriya to control Notes in System Settings › Privacy › Automation.", isError: !ok) }
        }
    }

    private func uploadFiles(_ files: [URL]) {
        Toast().show("Uploading…")
        ShelfInstant.upload(files) { result in
            switch result {
            case .success(let links): copy(links, "Uploaded. The link\(links.contains("\n") ? "s are" : " is") on the clipboard")
            case .failure(let error): Toast().show(error.localizedDescription, isError: true)
            }
        }
    }

    // MARK: Export and import

    private func exportShelf(encrypted: Bool) {
        guard let data = ShelfExchange.exported(library.current, imageData: { store.imageData(named: $0) }) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(library.current.name).kriyashelf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var out = data
        if encrypted {
            guard let pass = askPassphrase("Passphrase for this shelf file", confirm: true), let sealed = try? BackupCrypto.seal(String(decoding: data, as: UTF8.self), passphrase: pass) else { return }
            out = sealed
        }
        do { try out.write(to: url, options: .atomic); try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path); Toast().show("Saved \(url.lastPathComponent)") }
        catch { Toast().show("The shelf could not be saved.", isError: true) }
    }

    private func importShelf() {
        let panel = NSOpenPanel()
        panel.message = "Choose a Kriya shelf file"
        guard panel.runModal() == .OK, let url = panel.url, var data = try? Data(contentsOf: url) else { return }
        if BackupCrypto.isEncrypted(data) {
            guard let pass = askPassphrase("Passphrase for this shelf file", confirm: false), let text = try? BackupCrypto.open(data, passphrase: pass) else { Toast().show("That passphrase did not open the file.", isError: true); return }
            data = Data(text.utf8)
        }
        guard let parsed = ShelfExchange.imported(data) else { Toast().show("That is not a shelf file this version can read.", isError: true); return }
        var added = 0
        store.change { library in
            guard library.addShelf(named: parsed.name) != nil else { return }
            for item in parsed.items {
                var value = item.value
                if item.kind == .image { guard let png = item.png, let name = store.storeImage(png: png) else { continue }; value = name }
                if library.add(ShelfRecord(kind: item.kind, value: value, added: item.added, group: item.group)) { added += 1 }
            }
        }
        Toast().show("Imported \(added) item\(added == 1 ? "" : "s")\(parsed.skipped > 0 ? ", left out \(parsed.skipped) that were not valid" : "")")
    }

    private func askPassphrase(_ message: String, confirm: Bool) -> String? {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = confirm ? "Anyone with the file needs this to open it. Kriya cannot recover it." : ""
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return nil }
        return field.stringValue
    }

    /// Chips for the groups on every shelf. Click to show only one; drop something on a chip to put it in that group.
    @ViewBuilder
    private var groupBar: some View {
        let names = library.groupNames
        if !names.isEmpty || model.groupFilter != nil {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip("All", selected: model.groupFilter == nil, drop: nil)
                    ForEach(names, id: \.self) { name in
                        chip(name, selected: model.groupFilter == name, drop: name)
                            .contextMenu {
                                Button("Rename Group…") { renamingGroup = name; newName = name }
                                Button("Delete Group (keeps the items)", role: .destructive) {
                                    store.change { $0.deleteGroup(name) }
                                    if model.groupFilter == name { model.groupFilter = nil }
                                }
                            }
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 6)
            }
        }
    }

    private func chip(_ title: String, selected: Bool, drop group: String?) -> some View {
        Button { model.groupFilter = group } label: {
            Text(title).font(.caption).padding(.horizontal, 9).padding(.vertical, 3)
                .background(selected ? Theme.accent.opacity(0.25) : Color.primary.opacity(0.07), in: Capsule())
        }
        .buttonStyle(.plain)
        .onDrop(of: [.fileURL, .url, .image, .plainText], isTargeted: nil) { providers in
            if let id = model.draggingItemID {
                model.draggingItemID = nil
                store.change { $0.setGroup(group, for: id) }
            } else if let group {
                load(providers, group: group)
            }
            return true
        }
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search the shelves", text: $model.query).textFieldStyle(.plain)
            if !model.query.isEmpty { Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Close").buttonStyle(.borderless).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 12).padding(.bottom, 8)
    }

    private var footer: some View {
        HStack {
            Text("\(library.current.items.count) item\(library.current.items.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
            if store.expiringCount > 0 { Label("\(store.expiringCount) expiring", systemImage: "clock.badge.exclamationmark").font(.caption).foregroundStyle(Theme.warn) }
            Button(showingHistory ? "Hide History" : "History (\(library.history.count))") { showingHistory.toggle() }.controlSize(.small).disabled(library.history.isEmpty && !showingHistory)
            Spacer()
            Button { withAnimation(.smooth(duration: 0.2)) { grid.toggle() } } label: { Image(systemName: grid ? "list.bullet" : "square.grid.2x2") }.buttonStyle(.borderless).help(grid ? "Show as a list" : "Show as larger pictures").accessibilityLabel(grid ? "List" : "Grid")
            Button("Zip All") { zipAll() }.controlSize(.small).disabled(!hasFiles)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
    }

    // MARK: The list

    @ViewBuilder
    private var content: some View {
        if searching, !model.query.trimmingCharacters(in: .whitespaces).isEmpty {
            let hits = library.search(model.query)
            if hits.isEmpty {
                placeholder("Nothing matches", "Search covers every shelf and the history.")
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(hits, id: \.record.id) { hit in
                            if let item = ShelfItem(record: hit.record, store: store) { row(item, note: hit.shelf ?? "History", fromHistory: hit.shelf == nil) }
                        }
                    }.padding(6)
                }
            }
        } else if showingHistory {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(library.history) { record in
                        if let item = ShelfItem(record: record, store: store) { row(item, note: record.removed.map { RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date()) }, fromHistory: true) }
                    }
                    if !library.history.isEmpty {
                        Button("Clear the History", role: .destructive) { store.change { $0.clearHistory() } }.controlSize(.small).padding(.top, 6)
                    }
                }.padding(6)
            }
        } else if model.items.isEmpty {
            placeholder("Drop files, text or images here", "Then drag them out into any app.")
        } else {
            ScrollView {
                if grid {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 130), spacing: 8)], spacing: 8) { ForEach(model.items) { item in tile(item) } }.padding(8)
                } else {
                    VStack(spacing: 2) { ForEach(model.items) { item in row(item, note: detail(item), fromHistory: false) } }.padding(6)
                }
            }
        }
    }

    /// A larger picture with its name, for the grid view.
    private func tile(_ item: ShelfItem) -> some View {
        VStack(spacing: 4) {
            Group {
                if case .text(let t) = item.kind {
                    Text(String(t.prefix(120))).font(.system(size: 9)).foregroundStyle(.secondary).padding(6).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    Image(nsImage: item.icon).resizable().scaledToFit().padding(4)
                }
            }
            .frame(width: 96, height: 76)
            .background(Color.primary.opacity(hovered == item.id ? 0.1 : 0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(item.title).font(.system(size: 10)).lineLimit(1).truncationMode(.middle).frame(width: 96)
        }
        .onHover { hovered = $0 ? item.id : nil }
        .onDrag { model.draggingItemID = item.id; return item.provider }
        .contextMenu { Button("Remove") { remove(item) } }
    }

    /// Size, kind and age of an item, so a list tells more than a name does.
    private func detail(_ item: ShelfItem) -> String? {
        var parts: [String] = []
        switch item.kind {
        case .file(let url):
            if let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]) {
                if v.isDirectory == true { parts.append("Folder") } else if let size = v.fileSize { parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) }
            } else { parts.append("Missing") }
            if !url.pathExtension.isEmpty { parts.append(url.pathExtension.uppercased()) }
        case .text(let t): parts.append("\(t.count) characters")
        case .image(let image): parts.append("\(Int(image.size.width)) × \(Int(image.size.height))")
        }
        parts.append(RelativeDateTimeFormatter().localizedString(for: item.record.added, relativeTo: Date()))
        return parts.joined(separator: " · ")
    }

    private func placeholder(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "square.and.arrow.down").font(.system(size: 26)).foregroundStyle(.secondary)
            Text(title).foregroundStyle(.secondary)
            Text(detail).font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var hasFiles: Bool {
        model.items.contains { if case .file = $0.kind { return true } else { return false } }
    }

    private func row(_ item: ShelfItem, note: String?, fromHistory: Bool) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: item.icon).resizable().scaledToFit().frame(width: 30, height: 30).clipShape(RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 0) {
                Text(item.title).lineLimit(1).truncationMode(.middle)
                if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 4)
            if hovered == item.id {
                if fromHistory { Button { store.change { _ = $0.restore(item.id) } } label: { Image(systemName: "arrow.uturn.backward") }.buttonStyle(.borderless).help("Put back on this shelf").accessibilityLabel("Put back on this shelf") }
                else { Button { remove(item) } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Remove from the shelf").accessibilityLabel("Remove from the shelf") }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(hovered == item.id ? Color.primary.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? item.id : nil }
        .onDrag { model.draggingItemID = item.id; return item.provider }
        .contextMenu {
            if case .file(let url) = item.kind {
                Button("Quick Look") { quickLook(url) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([url as NSURL]) }
            } else if case .text(let text) = item.kind {
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
            }
            Menu("Group") {
                ForEach(library.groupNames, id: \.self) { name in Button(name) { store.change { $0.setGroup(name, for: item.id) } } }
                Button("New Group…") { groupingItem = item.id; newName = "" }
                if item.id.isEmpty == false, library.current.items.first(where: { $0.id == item.id })?.group != nil {
                    Divider()
                    Button("Take Out of Its Group") { store.change { $0.setGroup(nil, for: item.id) } }
                }
            }
            Divider()
            Button("AirDrop…") { NSSharingService(named: .sendViaAirDrop)?.perform(withItems: shareable(item)) }
            Button("Mail…") { NSSharingService(named: .composeEmail)?.perform(withItems: shareable(item)) }
            Divider()
            if fromHistory { Button("Put Back") { store.change { _ = $0.restore(item.id) } } } else {
                Menu("Move to Another Shelf") {
                    ForEach(library.shelves.filter { $0.id != library.currentID }) { shelf in
                        Button(shelf.name) { move(item, to: shelf.id) }
                    }
                }
                Button("Remove") { remove(item) }
            }
        }
    }

    /// What the sharing services take for an item: the file, its text, or the image.
    private func shareable(_ item: ShelfItem) -> [Any] {
        switch item.kind {
        case .file(let url): return [url]
        case .text(let text): return [text]
        case .image(let image): return [image]
        }
    }

    private func remove(_ item: ShelfItem) { store.change { $0.remove(item.id) } }

    private func move(_ item: ShelfItem, to shelfID: String) {
        store.change { library in
            guard let from = library.shelves.firstIndex(where: { $0.items.contains { $0.id == item.id } }),
                  let index = library.shelves[from].items.firstIndex(where: { $0.id == item.id }) else { return }
            let record = library.shelves[from].items[index]
            if library.add(record, to: shelfID) { library.shelves[from].items.remove(at: index) }
        }
    }

    private func quickLook(_ url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        process.arguments = ["-p", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    private func add(_ board: NSPasteboard) {
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            for url in urls { model.addFile(url) }
        } else if let text = board.string(forType: .string), !text.isEmpty {
            model.addText(text)
        }
    }

    private func load(_ providers: [NSItemProvider], group: String? = nil) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let url = (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) } ?? (item as? URL)
                    if let url { DispatchQueue.main.async { model.addFile(url, group: group) } }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                    if let image = object as? NSImage { DispatchQueue.main.async { model.addImage(image, group: group) } }
                }
            } else if provider.canLoadObject(ofClass: NSString.self) {
                _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                    if let text = object as? String { DispatchQueue.main.async { model.addText(text, group: group) } }
                }
            }
        }
    }

    /// Makes one zip of every file on the shelf, on the Desktop, and shows it.
    private func zipAll() {
        let files: [URL] = model.items.compactMap { if case .file(let url) = $0.kind { return url } else { return nil } }
        guard !files.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser
            let name = finderUniqueName(candidate: "Shelf.zip", existing: (try? FileManager.default.contentsOfDirectory(atPath: desktop.path)) ?? [])
            let target = desktop.appendingPathComponent(name)
            if (try? ToolRunner.run("/usr/bin/zip", ["-j", "-r", "-q", target.path] + files.map(\.path))) != nil {
                DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([target]) }
            }
        }
    }
}
