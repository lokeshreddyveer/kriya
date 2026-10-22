import AppKit
import SwiftUI

enum ClipChip: String, CaseIterable, Identifiable {
    case all = "All", text = "Text", links = "Links", images = "Images", files = "Files", pinned = "Pinned", snippets = "Snippets"
    var id: String { rawValue }

    func filter(collection: String?) -> ClipFilter {
        var kinds: [ClipKind] = []
        switch self {
        case .text: kinds = [.text, .richText]
        case .links: kinds = [.url]
        case .images: kinds = [.image]
        case .files: kinds = [.files]
        default: break
        }
        return ClipFilter(kinds: kinds, pinnedOnly: self == .pinned, favoritesOnly: self == .snippets, collectionId: collection, tag: nil)
    }
}

final class QuickClipModel: ObservableObject {
    @Published var query = "" { didSet { reload() } }
    @Published var chip: ClipChip = .all { didSet { reload() } }
    @Published var collection: String? { didSet { reload() } }
    @Published private(set) var results: [ClipItem] = []
    @Published var selected = 0
    @Published private(set) var blob: ClipBlob?

    private let store: ClipboardStore
    init(store: ClipboardStore) { self.store = store }

    func open() {
        query = ""
        chip = .all
        collection = nil
        reload()
    }

    func reload() {
        results = store.search(query, filter: chip.filter(collection: collection), limit: 200)
        selected = 0
        loadPreview()
    }

    func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selected = (selected + delta + results.count) % results.count
        loadPreview()
    }

    func select(_ index: Int) {
        guard results.indices.contains(index) else { return }
        selected = index
        loadPreview()
    }

    var current: ClipItem? { results.indices.contains(selected) ? results[selected] : nil }

    private func loadPreview() {
        blob = current.flatMap { store.blob($0.id) }
    }

    func togglePin() {
        guard let item = current else { return }
        store.setPinned(item.id, !item.pinned)
        reloadKeepingSelection(item.id)
    }

    /// Pins or unpins one item (a right-click on any row, not only the selected one).
    func togglePin(_ item: ClipItem) {
        store.setPinned(item.id, !item.pinned)
        reloadKeepingSelection(current?.id ?? item.id)
    }

    /// Makes an item a snippet, or takes it back to an ordinary item. Its name is kept either way.
    func toggleSnippet(_ item: ClipItem) {
        store.setFavorite(item.id, !item.favorite, title: item.title)
        reloadKeepingSelection(current?.id ?? item.id)
    }

    /// Removes one item, leaving the selection where it was.
    func remove(_ item: ClipItem) {
        let keep = selected
        let keepID = current?.id
        store.delete(item.id)
        results = store.search(query, filter: chip.filter(collection: collection), limit: 200)
        selected = keepID.flatMap { id in results.firstIndex { $0.id == id } } ?? min(keep, max(0, results.count - 1))
        loadPreview()
    }

    func deleteCurrent() {
        guard let item = current else { return }
        let keep = selected
        store.delete(item.id)
        reload()
        selected = min(keep, max(0, results.count - 1))
        loadPreview()
    }

    private func reloadKeepingSelection(_ id: String) {
        results = store.search(query, filter: chip.filter(collection: collection), limit: 200)
        selected = results.firstIndex { $0.id == id } ?? 0
        loadPreview()
    }
}

/// A search box over the clipboard history. Choose an item to paste it; hold ⌘ to paste it as plain text.
final class QuickAccessPanel: NSObject, NSWindowDelegate {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private let store: ClipboardStore
    private let paster: ClipboardPaster
    private let model: QuickClipModel
    private var panel: Panel?
    private let toast = Toast()
    /// True while Kriya itself places the window, so that is not taken for the person moving it.
    private var placing = false

    /// More right-click items for an item, such as Apple Intelligence. Set by the app.
    var extraMenuActions: (ClipItem) -> [QuickMenuAction] = { _ in [] }

    init(store: ClipboardStore, paster: ClipboardPaster) {
        self.store = store
        self.paster = paster
        model = QuickClipModel(store: store)
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() { isVisible ? close() : show() }

    func show() {
        ClipboardLock.shared.ensureUnlocked(reason: "Open your clipboard history") { [weak self] ok in
            if ok { self?.present() }
        }
    }

    private func present() {
        model.open()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        placing = true
        let size = panel.frame.size
        let screens = NSScreen.screens.map(\.visibleFrame)
        if QuickPanelPlacement.current == .remembered, let saved = QuickPanelPosition.usable(QuickPanelPosition.saved, size: size, screens: screens) {
            // Where the person left it last time.
            panel.setFrameOrigin(saved)
        } else {
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
            if let frame = screen?.visibleFrame {
                // Right at the pointer, kept fully on the screen.
                let x = min(max(mouse.x - 20, frame.minX + 8), frame.maxX - size.width - 8)
                let y = min(max(mouse.y - size.height + 20, frame.minY + 8), frame.maxY - size.height - 8)
                panel.setFrameOrigin(NSPoint(x: x, y: y))
            }
        }
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        DispatchQueue.main.async { [weak self] in self?.placing = false }
    }

    func close() { panel?.orderOut(nil) }

    private func choose(_ item: ClipItem, plain: Bool) {
        close()
        // The panel does not take focus from the app underneath, so the paste lands there.
        paster.choose(item, plain: plain)
    }

    private func makePanel() -> Panel {
        let panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 500), styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        // Drag it by any part that is not a control, or by the grip at the top.
        panel.isMovableByWindowBackground = true
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: QuickAccessView(
            model: model, store: store,
            onChoose: { [weak self] in self?.choose($0, plain: $1) },
            onClose: { [weak self] in self?.close() },
            onCopy: { [weak self] in self?.copy($0) },
            menuActions: { [weak self] in self?.menuActions(for: $0) ?? [] }
        ))
        return panel
    }

    func windowDidResignKey(_ notification: Notification) { close() }

    /// Remembers where the person put the window, when they asked for that.
    func windowDidMove(_ notification: Notification) {
        guard !placing, QuickPanelPlacement.current == .remembered, let origin = panel?.frame.origin else { return }
        QuickPanelPosition.save(origin)
    }

    // MARK: Right-click

    /// Copies an item without pasting it, and keeps the window open.
    private func copy(_ item: ClipItem) {
        if paster.put(item, plain: false) {
            store.markUsed(item.id)
            toast.show("Copied")
        } else {
            toast.show("That item could not be copied.", isError: true)
        }
    }

    /// What a right-click offers for an item beyond the usual: reveal files, open links, and whatever the app adds.
    private func menuActions(for item: ClipItem) -> [QuickMenuAction] {
        var list: [QuickMenuAction] = []
        switch item.kind {
        case .files:
            let urls = item.files.map { URL(fileURLWithPath: $0) }
            list.append(QuickMenuAction(title: "Show in Finder", symbol: "folder") { NSWorkspace.shared.activateFileViewerSelecting(urls) })
            list.append(QuickMenuAction(title: "Copy Path", symbol: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.files.joined(separator: "\n"), forType: .string)
            })
        case .url:
            if let url = URL(string: item.preview), ["http", "https"].contains(url.scheme?.lowercased()) {
                list.append(QuickMenuAction(title: "Open Link", symbol: "safari") { NSWorkspace.shared.open(url) })
            }
        default:
            break
        }
        list.append(contentsOf: extraMenuActions(item))
        return list
    }
}

/// One line in a list of clipboard items.
struct ClipRow: View {
    let item: ClipItem
    var number: Int?
    /// The pin mark is for the full history; the quick paste panel leaves it out.
    var showsPin = true

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.kind.symbol).frame(width: 20).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.sensitive ? "•••••••• Sensitive" : (item.title ?? item.preview)).lineLimit(2).font(.callout)
                HStack(spacing: 6) {
                    if item.sensitive { Image(systemName: "lock.fill") }
                    if let app = item.sourceApp { Text(AppChoice.name(for: app)) }
                    Text(Date(timeIntervalSince1970: TimeInterval(item.lastUsedAt)), style: .relative)
                    ForEach(item.tags.prefix(3), id: \.self) { Text("#\($0)").foregroundStyle(Theme.accent) }
                }
                .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if item.favorite { Image(systemName: "star.fill").foregroundStyle(Theme.warn).font(.caption) }
            if showsPin, item.pinned { Image(systemName: "pin.fill").foregroundStyle(Theme.warn).font(.caption) }
            if let number { Text("⌘\(number)").font(.caption2).foregroundStyle(.tertiary) }
        }
        .padding(.vertical, 2)
    }
}

/// A larger look at the selected item: all of its text, the image, or the files.
struct ClipPreview: View {
    let item: ClipItem?
    let blob: ClipBlob?
    /// A sensitive item stays hidden until the person asks to see it.
    @State private var revealed: String?

    var body: some View {
        Group {
            if let item {
                VStack(alignment: .leading, spacing: 8) {
                    content(item)
                    Spacer(minLength: 0)
                    Text(details(item)).font(.caption).foregroundStyle(.secondary)
                }
                .padding(14)
                .transition(.opacity)
            } else {
                Text("Select an item to preview it").foregroundStyle(.secondary)
            }
        }
        .animation(.smooth(duration: 0.15), value: item?.id)
    }

    @ViewBuilder
    private func content(_ item: ClipItem) -> some View {
        switch item.kind {
        case .image:
            if let data = blob?.image, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { Text("Image").foregroundStyle(.secondary) }
        case .files:
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(item.files, id: \.self) { path in
                        HStack(spacing: 6) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 18, height: 18)
                            Text((path as NSString).lastPathComponent).lineLimit(1)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        default:
            if item.sensitive, revealed != item.id {
                VStack(spacing: 10) {
                    Image(systemName: "lock.fill").font(.system(size: 26, weight: .light)).foregroundStyle(.secondary)
                    Text("This looks like a password, key or card number, so it is hidden.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Show It") { withAnimation(.smooth(duration: 0.15)) { revealed = item.id } }.controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Text(String((blob?.plain ?? item.preview).prefix(6000)))
                        .font(.system(.callout, design: item.kind == .url ? .default : .default))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func details(_ item: ClipItem) -> String {
        var parts = [item.kind.title, ByteCountFormatter.string(fromByteCount: Int64(item.byteSize), countStyle: .file)]
        if let w = item.imageWidth, let h = item.imageHeight { parts.append("\(w) × \(h)") }
        if item.useCount > 1 { parts.append("used \(item.useCount) times") }
        return parts.joined(separator: " · ")
    }
}
