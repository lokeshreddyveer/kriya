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

    init(store: ClipboardStore, paster: ClipboardPaster) {
        self.store = store
        self.paster = paster
        model = QuickClipModel(store: store)
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() { isVisible ? close() : show() }

    func show() {
        model.open()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            // Right at the pointer, kept fully on the screen.
            let size = panel.frame.size
            let x = min(max(mouse.x - 20, frame.minX + 8), frame.maxX - size.width - 8)
            let y = min(max(mouse.y - size.height + 20, frame.minY + 8), frame.maxY - size.height - 8)
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
    }

    func close() { panel?.orderOut(nil) }

    private func choose(_ item: ClipItem, plain: Bool) {
        close()
        // The panel does not take focus from the app underneath, so the paste lands there.
        paster.choose(item, plain: plain)
    }

    private func makePanel() -> Panel {
        let panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 460), styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: QuickAccessView(model: model, store: store, onChoose: { [weak self] in self?.choose($0, plain: $1) }, onClose: { [weak self] in self?.close() }))
        return panel
    }

    func windowDidResignKey(_ notification: Notification) { close() }
}

struct QuickAccessView: View {
    @ObservedObject var model: QuickClipModel
    @ObservedObject var store: ClipboardStore
    let onChoose: (ClipItem, Bool) -> Void
    let onClose: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $model.query)
                    .textFieldStyle(.plain).font(.body).focused($focused)
                    .onSubmit { if let item = model.current { onChoose(item, false) } }
                if store.currentConfig.paused { Label("Paused", systemImage: "pause.circle.fill").font(.caption).foregroundStyle(Theme.warn) }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.14), lineWidth: 1))
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)
            chips
            Divider()
            list
            Divider()
            HStack(spacing: 14) {
                hint("↩", "Paste"); hint("⌘↩", "Plain"); hint("⎋", "Close")
                Spacer()
            }
            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 7)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.22), lineWidth: 1))
        .onAppear { focused = true }
        .onKeyPress(phases: [.down, .repeat]) { press in handle(press) }
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 4) { Text(key).font(.caption.monospaced()).padding(.horizontal, 4).background(.quaternary, in: RoundedRectangle(cornerRadius: 4)); Text(text) }
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        let command = press.modifiers.contains(.command)
        switch press.key {
        case .downArrow: model.move(1); return .handled
        case .upArrow: model.move(-1); return .handled
        case .escape: onClose(); return .handled
        case .return:
            if command, let item = model.current { onChoose(item, true); return .handled }
            return .ignored
        case .delete where command: model.deleteCurrent(); return .handled
        default:
            if command, let digit = Int(press.characters), (1...9).contains(digit), model.results.indices.contains(digit - 1) {
                onChoose(model.results[digit - 1], false)
                return .handled
            }
            return .ignored
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(ClipChip.allCases) { chip in
                    Button { withAnimation(.smooth(duration: 0.15)) { model.chip = chip } } label: {
                        Text(chip.rawValue).font(.callout).padding(.horizontal, 10).padding(.vertical, 3)
                            .background(model.chip == chip ? Theme.accent.opacity(0.25) : Color.clear, in: Capsule())
                            .overlay(Capsule().strokeBorder(model.chip == chip ? Theme.accent : Color.secondary.opacity(0.3)))
                    }
                    .buttonStyle(.plain)
                }
                if !store.collections.isEmpty {
                    Menu {
                        Button("All collections") { model.collection = nil }
                        Divider()
                        ForEach(store.collections) { c in Button(c.name) { model.collection = c.id } }
                    } label: { Label(store.collections.first { $0.id == model.collection }?.name ?? "Collections", systemImage: "folder") }
                        .menuStyle(.borderlessButton).fixedSize()
                }
            }
            .padding(.horizontal, 14).padding(.bottom, 8)
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            List(Array(model.results.enumerated()), id: \.element.id) { index, item in
                ClipRow(item: item, number: index < 9 ? index + 1 : nil, showsPin: false)
                    .id(item.id)
                    .listRowSeparator(.hidden)
                    .listRowBackground(
                        ZStack {
                            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(index == model.selected ? Theme.accent.opacity(0.24) : .clear)
                            RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(index == model.selected ? Theme.accent.opacity(0.55) : .clear, lineWidth: 1)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 1)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { onChoose(item, NSEvent.modifierFlags.contains(.command)) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onChange(of: model.selected) { _, new in
                if model.results.indices.contains(new) { withAnimation(.smooth(duration: 0.12)) { proxy.scrollTo(model.results[new].id) } }
            }
            .overlay { if model.results.isEmpty { Text(store.isEmpty ? "Nothing copied yet" : "No matching items").foregroundStyle(.secondary) } }
        }
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
                Text(item.title ?? item.preview).lineLimit(2).font(.callout)
                HStack(spacing: 6) {
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
            ScrollView {
                Text(String((blob?.plain ?? item.preview).prefix(6000)))
                    .font(.system(.callout, design: item.kind == .url ? .default : .default))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
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
