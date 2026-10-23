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

    var items: [ShelfItem] { store.library.current.items.compactMap { ShelfItem(record: $0, store: store) } }

    func addFile(_ url: URL) { store.change { _ = $0.add(ShelfRecord(kind: .file, value: url.path, added: Date())) } }
    func addText(_ text: String) { store.change { _ = $0.add(ShelfRecord(kind: .text, value: text, added: Date())) } }
    func addImage(_ image: NSImage) {
        guard let name = store.storeImage(image) else { return }
        store.change { _ = $0.add(ShelfRecord(kind: .image, value: name, added: Date())) }
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

    private enum Naming { case new, rename }

    private var library: ShelfLibrary { store.library }

    var body: some View {
        VStack(spacing: 0) {
            header
            if searching { searchField }
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
            } label: {
                Label(library.current.name, systemImage: "tray").font(.headline)
            }
            .menuStyle(.borderlessButton).fixedSize()
            Spacer()
            Button { searching.toggle(); if !searching { model.query = "" } } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless).help("Search every shelf and the history").accessibilityLabel("Search every shelf and the history")
            Button("Add Clipboard") { add(NSPasteboard.general) }.controlSize(.small)
            Button { store.change { $0.clear() } } label: { Image(systemName: "trash") }.accessibilityLabel("Delete")
                .buttonStyle(.borderless).help("Clear this shelf (it goes to the history)").disabled(library.current.items.isEmpty)
            Button(action: onClose) { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
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
            Button(showingHistory ? "Hide History" : "History (\(library.history.count))") { showingHistory.toggle() }.controlSize(.small).disabled(library.history.isEmpty && !showingHistory)
            Spacer()
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
                VStack(spacing: 2) { ForEach(model.items) { item in row(item, note: nil, fromHistory: false) } }.padding(6)
            }
        }
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
        .onDrag { item.provider }
        .contextMenu {
            if case .file(let url) = item.kind {
                Button("Quick Look") { quickLook(url) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([url as NSURL]) }
            } else if case .text(let text) = item.kind {
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
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

    private func load(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let url = (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) } ?? (item as? URL)
                    if let url { DispatchQueue.main.async { model.addFile(url) } }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                    if let image = object as? NSImage { DispatchQueue.main.async { model.addImage(image) } }
                }
            } else if provider.canLoadObject(ofClass: NSString.self) {
                _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                    if let text = object as? String { DispatchQueue.main.async { model.addText(text) } }
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
