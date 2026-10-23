import AppKit
import Combine
import SwiftUI

/// Something else you can do with a result, shown with ⌘K.
struct PaletteAction: Identifiable {
    let id = UUID()
    let title: String
    let symbol: String
    let run: () -> Void
}

struct PaletteEntry: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let symbol: String
    var category: LauncherCategory = .command
    /// Other words that should find it.
    var keywords: [String] = []
    /// A file whose icon stands for the result (apps, files).
    var iconPath: String?
    /// Whether choosing it is remembered, so it rises with use. Clipboard items and sums are not.
    var rememberable = true
    /// Set for results that came from what was typed; they skip the fuzzy match and rank by this.
    var queryScore: Int?
    var actions: [PaletteAction] = []
    let run: () -> Void

    var candidate: LauncherCandidate {
        LauncherCandidate(id: id, title: title, subtitle: subtitle ?? "", keywords: keywords, category: category, queryScore: queryScore, rememberable: rememberable)
    }
}

final class PaletteModel: ObservableObject {
    @Published var query = "" { didSet { rank(resetSelection: true) } }
    @Published private(set) var results: [PaletteEntry] = []
    @Published var selected = 0
    @Published var showingActions = false
    @Published var actionIndex = 0
    /// The heading each row sits under, for the section titles. Same length as `results`.
    @Published private(set) var sections: [String] = []

    let prefs: LauncherPrefs
    private var all: [PaletteEntry] = []
    /// Results that depend on what was typed: a sum, a timer, files, clipboard items.
    var queryProviders: [(String) -> [PaletteEntry]] = []
    /// Set by the window: how many things ⌘K offers for the current result.
    var actionCount = 0

    init(prefs: LauncherPrefs) { self.prefs = prefs }

    func load(_ entries: [PaletteEntry]) {
        all = entries
        showingActions = false
        if query.isEmpty { rank(resetSelection: true) } else { query = "" }
    }

    /// Ranks again, keeping the selection where it was (more results arrived, or a choice changed).
    func refresh() { rank(resetSelection: false) }

    /// Replaces what can be found (open windows were gathered after the window opened) and ranks again in place.
    func reloadEntries(_ entries: [PaletteEntry]) {
        all = entries
        rank(resetSelection: false)
    }

    private func rank(resetSelection: Bool) {
        let text = query.trimmingCharacters(in: .whitespaces)
        let dynamic = text.isEmpty ? [] : queryProviders.flatMap { $0(text) }
        let combined = all + dynamic
        // With nothing typed the open apps are suggested, so the list is never bare for someone who has not used it yet.
        let running = text.isEmpty ? all.filter { $0.category == .app && $0.subtitle == "Running" }.map(\.id) : []
        let useful = text.isEmpty ? all.filter { ["clipboard:open", "finder:launcher"].contains($0.id) }.map(\.id) : []
        let order = LauncherEngine.rank(combined.map(\.candidate), query: query, prefs: prefs.data, suggestions: Array(running.prefix(5)) + useful)
        let byID = Dictionary(combined.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        results = order.compactMap { byID[$0] }
        sections = results.enumerated().map { index, entry in
            if text.isEmpty { return LauncherEngine.startSection(for: entry.id, prefs: prefs.data) }
            if entry.category == .web { return "Search the web" }
            return index == 0 ? "Top hit" : "Results"
        }
        if resetSelection {
            selected = 0
            showingActions = false
        } else {
            selected = min(selected, max(results.count - 1, 0))
        }
    }

    /// Ranks `entries` for a search made elsewhere (the menu-bar window), without touching what is open here.
    func search(_ text: String, in entries: [PaletteEntry], limit: Int) -> [PaletteEntry] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let combined = entries + queryProviders.flatMap { $0(trimmed) }
        let order = LauncherEngine.rank(combined.map(\.candidate), query: trimmed, prefs: prefs.data, limit: limit)
        let byID = Dictionary(combined.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return order.compactMap { byID[$0] }
    }

    func move(_ delta: Int) {
        if showingActions {
            guard actionCount > 0 else { return }
            actionIndex = (actionIndex + delta + actionCount) % actionCount
            return
        }
        guard !results.isEmpty else { return }
        selected = (selected + delta + results.count) % results.count
    }

    var current: PaletteEntry? { results.indices.contains(selected) ? results[selected] : nil }
}

/// A search box over everything: apps, windows, files, clipboard history, settings, commands, saved actions, workflows, a
/// calculator, timers and emoji. One shortcut opens it and the keyboard drives it. What it finds is ranked by how well it
/// matches, what you pinned, a short name you gave it, and what you use most.
final class CommandPalette: NSObject, NSWindowDelegate {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    let prefs: LauncherPrefs
    let model: PaletteModel
    private var panel: Panel?
    private var context: ServiceContext?
    private weak var keyboard: KeyboardService?
    private var providers: [() -> [PaletteEntry]] = []
    private var cached: (entries: [PaletteEntry], at: Date)?

    /// Opens a settings pane, and switches a feature on or off (asking for its permissions). Set by the app.
    var openSettings: (SettingsPane) -> Void = { _ in }
    var toggleFeature: (FeatureId, Bool) -> Void = { _, _ in }
    /// Called each time the palette opens, so things that take a moment to gather (open windows) can be fetched ahead.
    var willShow: () -> Void = {}

    init(prefs: LauncherPrefs = LauncherPrefs()) {
        self.prefs = prefs
        model = PaletteModel(prefs: prefs)
        super.init()
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func configure(context: ServiceContext, keyboard: KeyboardService) {
        self.context = context
        self.keyboard = keyboard
    }

    /// Other parts of Kriya add their own commands here (workflows do).
    func addProvider(_ provider: @escaping () -> [PaletteEntry]) {
        providers.append(provider)
    }

    /// Results that depend on what was typed.
    func addQueryProvider(_ provider: @escaping (String) -> [PaletteEntry]) {
        model.queryProviders.append(provider)
    }

    func toggle() { isVisible ? close() : show() }

    /// Something that was still being gathered is ready: show it without moving the selection.
    func entriesChanged() {
        guard isVisible else { return }
        cached = nil
        model.reloadEntries(entries())
    }

    /// Opens the launcher with some text already typed (from the command line or the Shortcuts app).
    func show(prefill text: String?) {
        show()
        if let text, !text.isEmpty { model.query = text }
    }

    func show() {
        willShow()
        cached = nil
        model.load(entries())
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        visible = screen?.visibleFrame ?? .zero
        if !visible.isEmpty { panel.setFrame(PaletteLayout.frame(height: wantedHeight(), in: visible), display: false) }
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
    }

    private var visible = CGRect.zero
    private var sizeWatcher: AnyCancellable?

    private func wantedHeight() -> CGFloat {
        PaletteLayout.height(sections: model.sections, typed: !model.query.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    /// Grows or shrinks the window as results come and go, keeping its top where it is.
    private func resize(animated: Bool = true) {
        guard let panel, panel.isVisible, !visible.isEmpty else { return }
        let target = PaletteLayout.resized(panel.frame, toHeight: wantedHeight(), in: visible)
        guard abs(target.height - panel.frame.height) > 0.5 else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                context.allowsImplicitAnimation = true
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
    }

    func close() { panel?.orderOut(nil) }

    fileprivate func run(_ entry: PaletteEntry, action: PaletteAction? = nil) {
        if entry.rememberable { prefs.record(entry.id) }
        close()
        // Let the panel go before the command runs, so a paste or a keystroke reaches the app underneath.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { (action?.run ?? entry.run)() }
    }

    /// Searches for the menu-bar window. The list is reused for a short while, since building it reads apps and settings.
    func search(_ text: String, limit: Int = 9) -> [PaletteEntry] {
        model.search(text, in: cachedEntries(), limit: limit)
    }

    /// Chooses a result found by `search`, as if it had been chosen here.
    func choose(_ entry: PaletteEntry) {
        if entry.rememberable { prefs.record(entry.id) }
        entry.run()
    }

    private func cachedEntries() -> [PaletteEntry] {
        if let cached, Date().timeIntervalSince(cached.at) < 20 { return cached.entries }
        let fresh = entries()
        cached = (fresh, Date())
        return fresh
    }

    // MARK: Things to do with a result

    /// What ⌘K offers for a result: what it brought, then pinning and a short name.
    fileprivate func actions(for entry: PaletteEntry) -> [PaletteAction] {
        var list = entry.actions
        guard entry.rememberable else { return list }
        let pinned = prefs.isPinned(entry.id)
        list.append(PaletteAction(title: pinned ? "Unpin from the Top" : "Pin to the Top", symbol: pinned ? "pin.slash" : "pin") { [weak self] in
            self?.prefs.togglePin(entry.id, title: entry.title)
        })
        let alias = prefs.alias(for: entry.id)
        list.append(PaletteAction(title: alias == nil ? "Give It a Short Name…" : "Change Its Short Name (\(alias ?? ""))…", symbol: "character.cursor.ibeam") { [weak self] in
            self?.askForAlias(entry)
        })
        return list
    }

    fileprivate func togglePin(_ entry: PaletteEntry) {
        guard entry.rememberable else { return }
        prefs.togglePin(entry.id, title: entry.title)
        model.refresh()
    }

    private func askForAlias(_ entry: PaletteEntry) {
        let alert = NSAlert()
        alert.messageText = "Short name for “\(entry.title)”"
        alert.informativeText = "Type this in the launcher and it comes first. Leave it empty to remove the name."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = prefs.alias(for: entry.id) ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if !prefs.setAlias(field.stringValue, for: entry.id, title: entry.title) {
            let tooLong = NSAlert()
            tooLong.messageText = "That name is too long"
            tooLong.informativeText = "Use up to 20 characters."
            tooLong.runModal()
        }
    }

    // MARK: What it lists

    private func entries() -> [PaletteEntry] {
        guard let context, let keyboard else { return [] }
        var list: [PaletteEntry] = []

        for snippet in keyboard.store.snippets where snippet.enabled {
            list.append(PaletteEntry(id: "snippet:\(snippet.id)", title: "Insert: \(snippet.title)", subtitle: snippet.abbreviation, symbol: snippet.favorite ? "star" : "text.insert", category: .snippet) { [weak keyboard] in
                keyboard?.run(.snippet(snippetId: snippet.id))
            })
        }
        for saved in context.library.actions {
            list.append(PaletteEntry(id: "action:\(saved.id)", title: saved.name, subtitle: "Action", symbol: saved.action.symbol, category: .action) { [weak keyboard] in
                keyboard?.run(.action(actionId: saved.id))
            })
        }
        for layout in windowLayouts() {
            list.append(PaletteEntry(id: layout.command, title: "Window: \(layout.title)", subtitle: "Windows", symbol: "rectangle.split.2x1", category: .layout) { [weak keyboard] in
                keyboard?.run(.command(command: layout.command))
            })
        }
        for extra in windowExtraCommands() {
            list.append(PaletteEntry(id: extra.command, title: "Window: \(extra.title)", subtitle: "Windows", symbol: "macwindow", category: .layout) { [weak keyboard] in
                keyboard?.run(.command(command: extra.command))
            })
        }
        for feature in FeatureId.all {
            let on = context.config.isEnabled(feature)
            list.append(PaletteEntry(id: "feature:\(feature.key)", title: "\(on ? "Turn off" : "Turn on") \(feature.title)", subtitle: "Features", symbol: feature.symbol, category: .feature) { [weak self] in
                self?.toggleFeature(feature, !on)
            })
        }
        for pane in SettingsPane.allCases {
            list.append(PaletteEntry(id: "pane:\(pane.rawValue)", title: "Open Settings: \(pane.title)", subtitle: "Settings", symbol: pane.symbol, category: .setting) { [weak self] in
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
        sizeWatcher = model.$sections.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.resize() }
        let panel = Panel(contentRect: NSRect(x: 0, y: 0, width: PaletteLayout.width, height: PaletteLayout.emptyHeight), styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: PaletteView(palette: self, model: model))
        return panel
    }

    func windowDidResignKey(_ notification: Notification) { close() }
}

// MARK: - The window

private enum PaletteIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(at path: String) -> NSImage {
        if let hit = cache[path] { return hit }
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 28, height: 28)
        if cache.count > 400 { cache.removeAll() }
        cache[path] = image
        return image
    }
}

private struct PaletteView: View {
    let palette: CommandPalette
    @ObservedObject var model: PaletteModel
    @ObservedObject private var prefs: LauncherPrefs
    @FocusState private var focused: Bool

    init(palette: CommandPalette, model: PaletteModel) {
        self.palette = palette
        self.model = model
        _prefs = ObservedObject(wrappedValue: palette.prefs)
    }

    private var actions: [PaletteAction] { model.current.map { palette.actions(for: $0) } ?? [] }
    private var typed: Bool { !model.query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            if !model.results.isEmpty {
                Divider().opacity(0.5)
                ZStack(alignment: .bottomTrailing) {
                    list
                    if model.showingActions, let entry = model.current { actionMenu(for: entry) }
                }
                Divider().opacity(0.5)
                footer
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.primary.opacity(0.2), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onAppear { focused = true }
        .onChange(of: model.showingActions) { _, on in
            if on { model.actionCount = actions.count; model.actionIndex = 0 }
        }
        .onKeyPress(phases: [.down, .repeat]) { press in handle(press) }
        .animation(.smooth(duration: 0.16), value: model.showingActions)
    }

    // MARK: The search bar

    private var searchBar: some View {
        HStack(spacing: 14) {
            Image(systemName: "magnifyingglass").font(.system(size: 22, weight: .regular)).foregroundStyle(.secondary)
            TextField("Search apps, files, windows or the web", text: $model.query)
                .textFieldStyle(.plain).font(.system(size: 24, weight: .light)).focused($focused)
                .onSubmit { submit() }
            if !model.query.isEmpty {
                Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(.tertiary) }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 22)
        .frame(height: PaletteLayout.searchHeight)
    }

    // MARK: Results

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { index, entry in
                        if index == 0 || model.sections.indices.contains(index) && model.sections[index] != model.sections[index - 1] {
                            header(model.sections.indices.contains(index) ? model.sections[index] : "")
                        }
                        row(entry, index: index)
                            .id(entry.id)
                            .onTapGesture { palette.run(entry) }
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, PaletteLayout.listPadding)
            }
            .scrollIndicators(.hidden)
            .onChange(of: model.selected) { _, new in
                if model.results.indices.contains(new) { withAnimation(.smooth(duration: 0.12)) { proxy.scrollTo(model.results[new].id) } }
            }
        }
    }

    private func header(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .frame(height: PaletteLayout.headerHeight, alignment: .bottom).padding(.horizontal, 12).padding(.bottom, 4)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 6) {
            if typed {
                Text("Nothing matches").foregroundStyle(.secondary)
            } else {
                Text("Type to search").foregroundStyle(.secondary)
                Text("Apps, windows, files, clipboard and settings. Try a sum like 12*8, “timer 5m”, an address, or “yt cats” to search YouTube.")
                    .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center).frame(maxWidth: 460)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) { Divider().opacity(0.5) }
    }

    private func row(_ entry: PaletteEntry, index: Int) -> some View {
        let on = index == model.selected
        let pinned = prefs.isPinned(entry.id)
        let alias = prefs.alias(for: entry.id)
        return HStack(spacing: 14) {
            icon(entry)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).font(.system(size: 15, weight: .medium)).lineLimit(1)
                if let subtitle = entry.subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if pinned { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(Theme.warn) }
            if let alias {
                Text(alias).font(.system(size: 10, design: .rounded)).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.primary.opacity(0.08), in: Capsule())
            }
            if on {
                HStack(spacing: 5) {
                    Text(entry.category.verb).font(.system(size: 12)).foregroundStyle(.secondary)
                    Text("↩").font(.system(size: 12, design: .rounded)).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
            } else {
                Text(entry.category.label).font(.system(size: 11)).foregroundStyle(.tertiary)
                if index < 9 { Text("⌘\(index + 1)").font(.system(size: 11, design: .rounded)).foregroundStyle(.tertiary) }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: PaletteLayout.rowHeight)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(on ? Theme.accent.opacity(0.24) : Color.clear))
        .contentShape(Rectangle())
        .animation(.smooth(duration: 0.12), value: on)
    }

    @ViewBuilder
    private func icon(_ entry: PaletteEntry) -> some View {
        if let path = entry.iconPath {
            Image(nsImage: PaletteIcons.icon(at: path)).resizable().frame(width: 32, height: 32)
        } else {
            Image(systemName: entry.symbol).font(.system(size: 16))
                .frame(width: 32, height: 32)
                .foregroundStyle(Theme.accent)
                .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    // MARK: Actions menu and footer

    private func actionMenu(for entry: PaletteEntry) -> some View {
        let items = actions
        return VStack(alignment: .leading, spacing: 2) {
            Text(entry.title).font(.caption).foregroundStyle(.secondary).lineLimit(1).padding(.horizontal, 8).padding(.top, 4)
            ForEach(Array(items.enumerated()), id: \.element.id) { index, action in
                HStack(spacing: 8) {
                    Image(systemName: action.symbol).frame(width: 16)
                    Text(action.title)
                    Spacer(minLength: 0)
                }
                .font(.callout)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(index == model.actionIndex ? Theme.accent.opacity(0.25) : Color.clear))
                .contentShape(Rectangle())
                .onTapGesture { runAction(action, for: entry) }
            }
            if items.isEmpty { Text("Nothing else to do with this.").font(.callout).foregroundStyle(.secondary).padding(8) }
        }
        .padding(6).frame(width: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.2), lineWidth: 1))
        .shadow(radius: 8, y: 2)
        .padding(10)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private var footer: some View {
        HStack(spacing: 14) {
            hint("↩", model.current?.category.verb ?? "Open")
            hint("⌘K", "More")
            hint("⌘P", "Pin")
            hint("⎋", "Close")
            Spacer(minLength: 4)
            if typed { Text("\(model.results.count) result\(model.results.count == 1 ? "" : "s")").font(.caption2).foregroundStyle(.tertiary) }
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .frame(height: PaletteLayout.footerHeight)
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.system(size: 10, design: .rounded)).padding(.horizontal, 4).padding(.vertical, 1)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(text)
        }
    }

    // MARK: Keys

    private func submit() {
        guard let entry = model.current else { return }
        if model.showingActions {
            let items = actions
            if items.indices.contains(model.actionIndex) { runAction(items[model.actionIndex], for: entry) }
        } else {
            palette.run(entry)
        }
    }

    private func runAction(_ action: PaletteAction, for entry: PaletteEntry) {
        model.showingActions = false
        // Pinning changes the list in place; everything else acts on the result and closes the window.
        if action.title.contains("Pin") {
            action.run()
            model.refresh()
        } else {
            palette.run(entry, action: action)
        }
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .downArrow: model.move(1); return .handled
        case .upArrow: model.move(-1); return .handled
        case .escape:
            if model.showingActions { model.showingActions = false } else { palette.close() }
            return .handled
        default:
            guard press.modifiers.contains(.command) else { return .ignored }
            let key = press.characters.lowercased()
            if key == "k" {
                model.showingActions.toggle()
                return .handled
            }
            if key == "p" {
                if let entry = model.current { palette.togglePin(entry) }
                return .handled
            }
            if let digit = Int(key), (1...9).contains(digit) {
                if model.results.indices.contains(digit - 1) { palette.run(model.results[digit - 1]) }
                return .handled
            }
            return .ignored
        }
    }
}
