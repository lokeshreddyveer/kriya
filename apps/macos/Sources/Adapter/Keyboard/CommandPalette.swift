import AppKit
import SwiftUI

struct PaletteEntry: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let symbol: String
    let run: () -> Void
}

final class PaletteModel: ObservableObject {
    @Published var query = "" { didSet { rank() } }
    @Published private(set) var results: [PaletteEntry] = []
    @Published var selected = 0

    private var all: [PaletteEntry] = []
    private let defaults = UserDefaults.standard

    func load(_ entries: [PaletteEntry]) {
        all = entries
        query = ""
        rank()
    }

    private func rank() {
        let items = all.map { SwitcherItem(id: $0.id, appName: $0.subtitle ?? "", title: $0.title, lastUsed: Int64(defaults.integer(forKey: "paletteUse.\($0.id)"))) }
        let order = windowRankSwitcher(items: items, query: query)
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        results = order.compactMap { byID[$0] }
        selected = 0
    }

    func remember(_ entry: PaletteEntry) { defaults.set(Int(Date().timeIntervalSince1970), forKey: "paletteUse.\(entry.id)") }

    func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selected = (selected + delta + results.count) % results.count
    }

    var current: PaletteEntry? { results.indices.contains(selected) ? results[selected] : nil }
}

/// A search box over everything Kriya can do: insert a snippet, run an action or workflow, move a window, switch a
/// feature on or off, open a settings pane. Reached by one shortcut, driven entirely from the keyboard.
final class CommandPalette: NSObject, NSWindowDelegate {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private let model = PaletteModel()
    private var panel: Panel?
    private var context: ServiceContext?
    private weak var keyboard: KeyboardService?
    private var providers: [() -> [PaletteEntry]] = []

    /// Opens a settings pane, and switches a feature on or off (asking for its permissions). Set by the app.
    var openSettings: (SettingsPane) -> Void = { _ in }
    var toggleFeature: (FeatureId, Bool) -> Void = { _, _ in }

    var isVisible: Bool { panel?.isVisible ?? false }

    func configure(context: ServiceContext, keyboard: KeyboardService) {
        self.context = context
        self.keyboard = keyboard
    }

    /// Other parts of Kriya add their own commands here (workflows do).
    func addProvider(_ provider: @escaping () -> [PaletteEntry]) {
        providers.append(provider)
    }

    func toggle() { isVisible ? close() : show() }

    func show() {
        model.load(entries())
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY + frame.height * 0.14))
        }
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
    }

    func close() { panel?.orderOut(nil) }

    private func choose(_ entry: PaletteEntry) {
        model.remember(entry)
        close()
        // Let the panel go before the command runs, so a paste or a keystroke reaches the app underneath.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { entry.run() }
    }

    // MARK: What it lists

    private func entries() -> [PaletteEntry] {
        guard let context, let keyboard else { return [] }
        var list: [PaletteEntry] = []

        for snippet in keyboard.store.snippets where snippet.enabled {
            list.append(PaletteEntry(id: "snippet:\(snippet.id)", title: "Insert: \(snippet.title)", subtitle: snippet.abbreviation, symbol: snippet.favorite ? "star" : "text.insert") { [weak keyboard] in
                keyboard?.run(.snippet(snippetId: snippet.id))
            })
        }
        for saved in context.library.actions {
            list.append(PaletteEntry(id: "action:\(saved.id)", title: saved.name, subtitle: "Action", symbol: saved.action.symbol) { [weak keyboard] in
                keyboard?.run(.action(actionId: saved.id))
            })
        }
        for layout in windowLayouts() {
            list.append(PaletteEntry(id: layout.command, title: "Window: \(layout.title)", subtitle: "Windows", symbol: "rectangle.split.2x1") { [weak keyboard] in
                keyboard?.run(.command(command: layout.command))
            })
        }
        for extra in windowExtraCommands() {
            list.append(PaletteEntry(id: extra.command, title: "Window: \(extra.title)", subtitle: "Windows", symbol: "macwindow") { [weak keyboard] in
                keyboard?.run(.command(command: extra.command))
            })
        }
        for feature in FeatureId.all {
            let on = context.config.isEnabled(feature)
            list.append(PaletteEntry(id: "feature:\(feature.key)", title: "\(on ? "Turn off" : "Turn on") \(feature.title)", subtitle: "Features", symbol: feature.symbol) { [weak self] in
                self?.toggleFeature(feature, !on)
            })
        }
        for pane in SettingsPane.allCases {
            list.append(PaletteEntry(id: "pane:\(pane.rawValue)", title: "Open Settings: \(pane.title)", subtitle: "Settings", symbol: pane.symbol) { [weak self] in
                self?.openSettings(pane)
            })
        }
        let clipboard = context.clipboard
        list.append(PaletteEntry(id: "clipboard:open", title: "Open clipboard history", subtitle: "Clipboard", symbol: "doc.on.clipboard") { clipboard.quick.show() })
        list.append(PaletteEntry(id: "clipboard:pause", title: clipboard.store.config.paused ? "Resume clipboard recording" : "Pause clipboard recording", subtitle: "Clipboard", symbol: "pause.circle") {
            clipboard.setPaused(!clipboard.store.config.paused)
        })
        list.append(PaletteEntry(id: "clipboard:strip", title: "Remove formatting from the clipboard", subtitle: "Clipboard", symbol: "textformat") { clipboard.paster.removeFormattingFromClipboard() })
        list.append(PaletteEntry(id: "selection:show", title: "Show selection actions", subtitle: "Selection", symbol: "text.cursor") { context.selection.showManually() })
        list.append(PaletteEntry(id: "finder:launcher", title: "Finder actions for the selected files", subtitle: "Finder", symbol: "contextualmenu.and.cursorarrow") { context.finder.launcher.show() })
        for provider in providers { list.append(contentsOf: provider()) }
        return list
    }

    private func makePanel() -> Panel {
        let panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 440), styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: PaletteView(model: model, onChoose: { [weak self] in self?.choose($0) }, onClose: { [weak self] in self?.close() }))
        return panel
    }

    func windowDidResignKey(_ notification: Notification) { close() }
}

private struct PaletteView: View {
    @ObservedObject var model: PaletteModel
    let onChoose: (PaletteEntry) -> Void
    let onClose: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "command").foregroundStyle(Theme.accent)
                TextField("Type a command", text: $model.query)
                    .textFieldStyle(.plain).font(.title3).focused($focused)
                    .onSubmit { if let current = model.current { onChoose(current) } }
            }
            .padding(14)
            Divider()
            ScrollViewReader { proxy in
                List(Array(model.results.enumerated()), id: \.element.id) { index, entry in
                    HStack(spacing: 12) {
                        Image(systemName: entry.symbol).frame(width: 22).foregroundStyle(.secondary)
                        Text(entry.title).lineLimit(1)
                        Spacer()
                        if let subtitle = entry.subtitle { Text(subtitle).font(.caption).foregroundStyle(.tertiary).lineLimit(1) }
                    }
                    .padding(.vertical, 2)
                    .id(entry.id)
                    .listRowSeparator(.hidden)
                    .listRowBackground(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(index == model.selected ? Theme.accent.opacity(0.25) : .clear).padding(.horizontal, 6))
                    .contentShape(Rectangle())
                    .onTapGesture { onChoose(entry) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onChange(of: model.selected) { _, new in
                    if model.results.indices.contains(new) { withAnimation(.smooth(duration: 0.12)) { proxy.scrollTo(model.results[new].id) } }
                }
                .overlay { if model.results.isEmpty { Text("No matching commands").foregroundStyle(.secondary) } }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator))
        .onAppear { focused = true }
        .onKeyPress(.downArrow) { model.move(1); return .handled }
        .onKeyPress(.upArrow) { model.move(-1); return .handled }
        .onKeyPress(.escape) { onClose(); return .handled }
    }
}
