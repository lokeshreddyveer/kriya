import AppKit
import Combine
import SwiftUI

/// Something else you can do with a result, shown with ⌘K.
struct PaletteAction: Identifiable {
    let id = UUID()
    let title: String
    let symbol: String
    /// Shown at the right of the menu row, such as "⌘↩".
    var hint: String?
    /// Shown in red: it removes something.
    var destructive = false
    /// Leaves the launcher open afterwards (pinning, hiding) instead of closing it.
    var keepsOpen = false
    let run: () -> Void

    init(title: String, symbol: String, hint: String? = nil, destructive: Bool = false, keepsOpen: Bool = false, run: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.hint = hint
        self.destructive = destructive
        self.keepsOpen = keepsOpen
        self.run = run
    }
}

/// What typing a keyword and a space turns into: a chip in the search bar, and everything after it is that command's argument.
struct ArgumentToken: Equatable {
    let keyword: String
    let title: String
    let symbol: String
    let placeholder: String
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
    /// A colour shown in place of the icon, as `#RRGGBB`.
    var swatchHex: String?
    /// What the result stands for on disk, for the file actions and the file buffer.
    var fileURL: URL?
    var isDirectory = false
    /// Offered when nothing else matched ("Search the web for …"), and listed apart.
    var isFallback = false
    /// The app this result stands for, for hiding, quitting and uninstalling.
    var appBundleID: String?
    let run: () -> Void

    var candidate: LauncherCandidate {
        LauncherCandidate(id: id, title: title, subtitle: subtitle ?? "", keywords: keywords, category: category, queryScore: queryScore, rememberable: rememberable)
    }
}

final class PaletteModel: ObservableObject {
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            historyIndex = nil
            if token == nil, query.hasSuffix(" "), let word = Self.singleWord(query), let found = tokenProvider(word) {
                // "gh " becomes a chip, and what is typed after it is the argument.
                token = found
                query = ""
                return
            }
            rank(resetSelection: true)
        }
    }
    @Published private(set) var token: ArgumentToken?
    @Published private(set) var results: [PaletteEntry] = []
    @Published var selected = 0
    /// Counts up each time the launcher opens, so the window can play its opening animation.
    @Published var openTick = 0
    @Published var showingActions = false
    @Published var actionIndex = 0
    /// The heading each row sits under, for the section titles. Same length as `results`.
    @Published private(set) var sections: [String] = []
    /// Text that was selected in another app: the launcher then offers things to do with it.
    @Published private(set) var selectionText: String?

    let prefs: LauncherPrefs
    private var all: [PaletteEntry] = []
    /// Results that depend on what was typed: a sum, a timer, files, clipboard items.
    var queryProviders: [(String) -> [PaletteEntry]] = []
    /// A name for each provider above, in the same order, for the speed readout in Settings.
    var queryProviderNames: [String] = []
    /// What a keyword (followed by a space) turns into, if it names a command that takes an argument.
    var tokenProvider: (String) -> ArgumentToken? = { _ in nil }
    /// Extra rows for the opening list, with the heading each sits under: today's events, recent files.
    var startProvider: () -> [(entry: PaletteEntry, section: String)] = { [] }
    /// Things to do with the selected text.
    var selectionProvider: (String) -> [PaletteEntry] = { _ in [] }
    /// Set by the window: how many things ⌘K offers for the current result.
    var actionCount = 0

    init(prefs: LauncherPrefs) { self.prefs = prefs }

    /// The single word that makes up `text` (without its trailing space), or nil when there is more than one.
    static func singleWord(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && !trimmed.contains(" ") ? trimmed.lowercased() : nil
    }

    /// Where ⌥↑ and ⌥↓ have stepped to in the past searches (nil is what was typed), and what was typed before stepping.
    var historyIndex: Int?
    var historyDraft = ""

    /// What the providers see: the chip's keyword and what was typed after it.
    var effectiveQuery: String {
        guard let token else { return query }
        return query.isEmpty ? token.keyword : "\(token.keyword) \(query)"
    }

    func load(_ entries: [PaletteEntry], selection: String? = nil) {
        all = entries
        selectionText = selection
        token = nil
        showingActions = false
        if query.isEmpty { rank(resetSelection: true) } else { query = "" }
    }

    /// Takes the chip back off: the keyword returns to the text, so it can be edited.
    func clearToken() {
        guard let token else { return }
        self.token = nil
        query = token.keyword
    }

    /// Ranks again, keeping the selection where it was (more results arrived, or a choice changed).
    func refresh() { rank(resetSelection: false) }

    /// Replaces what can be found (open windows were gathered after the window opened) and ranks again in place.
    func reloadEntries(_ entries: [PaletteEntry]) {
        all = entries
        rank(resetSelection: false)
    }

    private func rank(resetSelection: Bool) {
        FeatureTimings.shared.measure("Launcher search") { rankNow(resetSelection: resetSelection) }
    }

    private func rankNow(resetSelection: Bool) {
        let full = effectiveQuery.trimmingCharacters(in: .whitespaces)
        // "apps: saf" limits the results to apps; "apps:" alone lists them.
        let parsed = token == nil ? LauncherFilter.parse(full) : nil
        let text = parsed?.rest ?? full
        let filter = parsed?.category
        if let filter, text.isEmpty {
            let items = all.filter { $0.category == filter }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }.prefix(60)
            results = Array(items)
            sections = items.map { _ in filter.title }
            if resetSelection { selected = 0; showingActions = false } else { selected = min(selected, max(items.count - 1, 0)) }
            return
        }
        var heldBack: [PaletteEntry] = []
        var dynamic: [PaletteEntry] = text.isEmpty ? [] : queryProviders.enumerated().flatMap { index, provider -> [PaletteEntry] in
            let start = DispatchTime.now()
            let found = provider(text)
            let ms = Int(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
            LauncherLatencyStore.shared.record(index < queryProviderNames.count ? queryProviderNames[index] : "Source \(index + 1)", milliseconds: ms)
            return found
        }
        // A chip has already chosen what the words are for, so nothing else is offered them.
        if token != nil { dynamic.removeAll { $0.isFallback } }
        if let selectionText {
            // Selected text: its actions come first, and typing narrows them.
            let actions = selectionProvider(selectionText)
            if text.isEmpty {
                heldBack = actions
            } else {
                // Typing narrows them by their names, so they are ranked like anything else, not by the order they were made in.
                dynamic += actions.map { entry in var narrowed = entry; narrowed.queryScore = nil; return narrowed }
            }
        }
        let combined = all + dynamic + heldBack
        let typed = !text.isEmpty
        // With nothing typed the open apps are suggested, so the list is never bare for someone who has not used it yet.
        let running = !typed ? all.filter { $0.category == .app && $0.subtitle == "Running" }.map(\.id) : []
        let useful = !typed ? all.filter { ["clipboard:open", "finder:launcher"].contains($0.id) }.map(\.id) : []
        let held = Set(heldBack.map(\.id))
        let order: [String]
        if !typed, !held.isEmpty {
            order = heldBack.map(\.id)
        } else {
            order = LauncherEngine.rank(combined.map(\.candidate), query: text, prefs: prefs.data, suggestions: Array(running.prefix(5)) + useful)
            LauncherWhy.shared.note(query: text, items: combined.map(\.candidate), prefs: prefs.data)
        }
        let byID = Dictionary(combined.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var list = order.compactMap { byID[$0] }
        if let filter { list = list.filter { $0.category == filter } }
        if typed, token == nil {
            // "Search with" rows rank low by design, which left them below a long list or cut off altogether. They are always
            // present, a few rows down, so the web search is where you can see it.
            let hidden = Set(prefs.data.hidden)
            let shown = Set(list.map(\.id))
            let missing = dynamic.filter { $0.isFallback && !shown.contains($0.id) && prefs.data.isEnabled($0.category) && !hidden.contains($0.id) }
            let fallbacks = list.filter(\.isFallback) + missing
            if !fallbacks.isEmpty {
                var rest = list.filter { !$0.isFallback }
                rest.insert(contentsOf: fallbacks, at: min(rest.count, 4))
                list = rest
            }
        }
        var headings: [String] = []

        if !typed, held.isEmpty {
            headings = list.map { LauncherEngine.startSection(for: $0.id, prefs: prefs.data) }
            for extra in startProvider() where !list.contains(where: { $0.id == extra.entry.id }) {
                list.append(extra.entry)
                headings.append(extra.section)
            }
        } else if !typed {
            headings = list.map { _ in "Selected text" }
        } else {
            headings = list.enumerated().map { index, entry in
                if entry.isFallback { return "Search with" }
                if entry.category == .web { return "Web" }
                return index == 0 ? "Top hit" : "Results"
            }
        }
        // A chip with nothing after it yet: say what to type.
        if let token, query.isEmpty {
            list.insert(PaletteEntry(id: "token:hint", title: token.placeholder, subtitle: token.title, symbol: token.symbol, rememberable: false, run: {}), at: 0)
            headings.insert("Top hit", at: 0)
        }
        results = list
        sections = headings
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

    #if DEBUG
    /// For the screenshot harness: the launcher's own window.
    var debugWindow: NSWindow? { panel }
    #endif

    func configure(context: ServiceContext, keyboard: KeyboardService) {
        self.context = context
        self.keyboard = keyboard
    }

    /// Other parts of Kriya add their own commands here (workflows do).
    func addProvider(_ provider: @escaping () -> [PaletteEntry]) {
        providers.append(provider)
    }

    /// Results that depend on what was typed.
    func addQueryProvider(name: String? = nil, _ provider: @escaping (String) -> [PaletteEntry]) {
        model.queryProviderNames.append(name ?? "Source \(model.queryProviders.count + 1)")
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

    /// Opens the launcher with text selected in another app: what can be done with it comes first.
    func show(selection text: String) {
        show(selection: text as String?)
    }

    func show() { show(selection: nil) }

    /// Runs the result with this id from anywhere (a hotkey set on it). The launcher does not open.
    func runResult(withID id: String) {
        guard let entry = entries().first(where: { $0.id == id }) else { return }
        if entry.rememberable { prefs.record(entry.id) }
        entry.run()
    }

    /// Reads what is selected in the front app and opens the launcher with things to do with it. With nothing selected, it
    /// offers the clipboard's text instead, and says so.
    func showForSelection() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let selected = SelectionReader.read()?.text
            DispatchQueue.main.async {
                guard let self else { return }
                if let selected, !selected.isEmpty {
                    self.show(selection: String(selected.prefix(2000)))
                } else if let board = NSPasteboard.general.string(forType: .string), !board.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.show(selection: String(board.prefix(2000)))
                } else {
                    self.show()
                }
            }
        }
    }

    private func show(selection text: String?) {
        willShow()
        cached = nil
        model.load(entries(), selection: text)
        model.openTick += 1
        let panel = self.panel ?? makePanel()
        self.panel = panel
        switch LauncherTheme.current.appearance {
        case .system: panel.appearance = nil
        case .dark: panel.appearance = NSAppearance(named: .darkAqua)
        case .light: panel.appearance = NSAppearance(named: .aqua)
        }
        let mouse = NSEvent.mouseLocation
        let placement = PaletteLayout.Placement.current
        var screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        // Where the person left it can be on another display than the pointer.
        if placement == .remembered, let saved = PaletteLayout.Remembered.saved, let home = NSScreen.screens.first(where: { $0.frame.contains(saved) }) { screen = home }
        visible = screen?.visibleFrame ?? .zero
        placing = true
        var target = CGRect.zero
        if !visible.isEmpty {
            target = PaletteLayout.frame(height: wantedHeight(), in: visible, placement: placement, pointer: mouse, saved: PaletteLayout.Remembered.saved)
            // It starts a little off its edge and settles into place as it fades in: from above, or from below when it grows up.
            panel.setFrame(reduceMotion ? target : target.offsetBy(dx: 0, dy: placement.growsUp ? -10 : 10), display: false)
        }
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = reduceMotion ? 0 : 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            if !target.isEmpty { panel.animator().setFrame(target, display: true) }
        }, completionHandler: { [weak self] in self?.placing = false })
    }

    /// The person asked macOS for less motion (System Settings › Accessibility › Display), so the window appears without moving.
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private var visible = CGRect.zero
    /// True while Kriya itself places the window, so that is not taken for the person dragging it.
    private var placing = false
    private var sizeWatcher: AnyCancellable?

    private func wantedHeight() -> CGFloat {
        PaletteLayout.height(sections: model.sections, typed: !model.query.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    /// Grows or shrinks the window as results come and go, keeping its top where it is (its bottom, for the bottom placements).
    private func resize(animated: Bool = true) {
        guard let panel, panel.isVisible, !visible.isEmpty else { return }
        let target = PaletteLayout.resized(panel.frame, toHeight: wantedHeight(), in: visible, growsUp: PaletteLayout.Placement.current.growsUp)
        guard abs(target.height - panel.frame.height) > 0.5 else { return }
        placing = true
        if animated && !reduceMotion {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.14
                context.allowsImplicitAnimation = true
                panel.animator().setFrame(target, display: true)
            }, completionHandler: { [weak self] in self?.placing = false })
        } else {
            panel.setFrame(target, display: true)
            placing = false
        }
    }

    func close() { panel?.orderOut(nil) }

    fileprivate func run(_ entry: PaletteEntry, action: PaletteAction? = nil) {
        // A past search is put back in the box to be edited or run, not run itself.
        if entry.id.hasPrefix("history:"), action == nil {
            model.query = entry.title
            return
        }
        // The words typed are remembered if the person keeps a search history. Never for clipboard items.
        if entry.category != .clipboard { SearchHistoryStore.shared.record(model.effectiveQuery) }
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

    // MARK: Folders

    /// Tab on a folder goes into it.
    fileprivate func folderIn() -> Bool {
        guard let entry = model.current, entry.isDirectory, let url = entry.fileURL else { return false }
        model.query = FileNavigation.enter(url)
        return true
    }

    /// Shift-Tab goes up a folder while a path is being typed.
    fileprivate func folderUp() -> Bool {
        guard model.token == nil, let up = FileNavigation.up(from: model.query) else { return false }
        model.query = up
        return true
    }

    /// Extra things to do with a result, by what it is (a file, an app, an event). Set by whoever knows.
    var extraActions: (PaletteEntry) -> [PaletteAction] = { _ in [] }
    /// Shortcuts for results. Set by the app.
    var hotkeys: LauncherHotkeys?

    /// What ⌘K offers for a result: what it brought, what its kind allows, then favorites, a short name, a key and hiding.
    fileprivate func actions(for entry: PaletteEntry) -> [PaletteAction] {
        var list = entry.actions + extraActions(entry)
        guard entry.rememberable else { return list }
        let favorite = prefs.isPinned(entry.id)
        list.append(PaletteAction(title: favorite ? "Remove from Favorites" : "Add to Favorites", symbol: favorite ? "star.slash" : "star", hint: "⌘P", keepsOpen: true) { [weak self] in
            self?.prefs.togglePin(entry.id, title: entry.title)
        })
        let alias = prefs.alias(for: entry.id)
        list.append(PaletteAction(title: alias == nil ? "Set Alias…" : "Change Alias (\(alias ?? ""))…", symbol: "character.cursor.ibeam") { [weak self] in
            self?.askForAlias(entry)
        })
        let key = prefs.hotkey(for: entry.id)
        list.append(PaletteAction(title: key == nil ? "Set Hotkey…" : "Change Hotkey (\(KeyNames.describe(keyCode: key!.keyCode, modifiers: key!.modifiers)))…", symbol: "keyboard") { [weak self] in
            self?.askForHotkey(entry)
        })
        if prefs.data.usage[entry.id] != nil {
            list.append(PaletteAction(title: "Reset Ranking", symbol: "arrow.counterclockwise", keepsOpen: true) { [weak self] in
                self?.prefs.resetRanking(entry.id)
            })
        }
        list.append(PaletteAction(title: "Hide from the Launcher", symbol: "eye.slash", destructive: true, keepsOpen: true) { [weak self] in
            self?.prefs.hide(entry.id)
        })
        return list
    }

    private func askForHotkey(_ entry: PaletteEntry) {
        guard let hotkeys else { return }
        let alert = NSAlert()
        alert.messageText = "Hotkey for “\(entry.title)”"
        alert.informativeText = "Press the keys. The result then runs from anywhere. Clear removes the hotkey."
        let recorder = LauncherHotkeyRecorder(initial: prefs.hotkey(for: entry.id))
        alert.accessoryView = recorder.view
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            guard let key = recorder.value else { return }
            if let problem = hotkeys.set(key, for: entry.id, title: entry.title) {
                let note = NSAlert()
                note.messageText = "That hotkey cannot be used"
                note.informativeText = problem
                note.runModal()
            }
        case .alertSecondButtonReturn:
            _ = hotkeys.set(nil, for: entry.id, title: entry.title)
        default:
            break
        }
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
        list.append(PaletteEntry(id: "selection:paste", title: "Show paste actions here", subtitle: "Selection · when nothing is selected", symbol: "doc.on.clipboard", keywords: ["paste", "empty", "blank"]) { context.selection.showPasteBar() })
        list.append(PaletteEntry(id: "finder:launcher", title: "Finder actions for the selected files", subtitle: "Finder", symbol: "contextualmenu.and.cursorarrow") { context.finder.launcher.show() })
        for provider in providers { list.append(contentsOf: provider()) }
        return list
    }

    private func makePanel() -> Panel {
        sizeWatcher = model.$sections.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.resize() }
        let panel = Panel(contentRect: NSRect(x: 0, y: 0, width: PaletteLayout.width + PaletteLayout.shadowInset * 2, height: PaletteLayout.emptyHeight), styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false   // the glass draws its own, softer shadows
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: PaletteView(palette: self, model: model))
        return panel
    }

    func windowDidResignKey(_ notification: Notification) { close() }

    /// Dragging the window moves it, and it opens there next time.
    func windowDidMove(_ notification: Notification) {
        guard !placing, let frame = panel?.frame, panel?.isVisible == true else { return }
        PaletteLayout.Remembered.saved = CGPoint(x: frame.midX, y: frame.maxY)
        if PaletteLayout.Placement.current != .remembered { PaletteLayout.Placement.current = .remembered }
        visible = (NSScreen.screens.first { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) } ?? NSScreen.main)?.visibleFrame ?? visible
    }
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

    @State private var pop = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("launcherTheme") private var themeRaw = LauncherTheme.glass.rawValue
    @AppStorage("launcherAccent") private var accentRaw = LauncherAccent.neutral.rawValue
    @AppStorage(PaletteLayout.Placement.key) private var placementRaw = PaletteLayout.Placement.top.rawValue

    /// At the bottom of the screen the results sit above the search bar and the window grows upward.
    private var growsUp: Bool { PaletteLayout.Placement(rawValue: placementRaw)?.growsUp ?? false }

    private var theme: LauncherTheme { LauncherTheme(rawValue: themeRaw) ?? .glass }
    private var accentColor: Color? { LauncherAccent(rawValue: accentRaw)?.rgb.map { Color(red: $0.r, green: $0.g, blue: $0.b) } }
    /// The colour that lifts a highlight off the background: white on dark, black on light.
    private var lift: Color { scheme == .dark ? Color.white : Color.black }

    /// Each time the launcher opens it rises into place with a small spring.
    private func settle() {
        pop = false
        if reduceMotion { pop = true } else { withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { pop = true } }
    }

    private var actions: [PaletteAction] { model.current.map { palette.actions(for: $0) } ?? [] }
    private var typed: Bool { !model.query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: PaletteLayout.gap) {
            if !growsUp { searchPill }
            if !model.results.isEmpty {
                resultsPanel
            } else {
                emptyPanel
            }
            if growsUp { searchPill }
        }
        .padding(PaletteLayout.shadowInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: growsUp ? .bottom : .top)
        .scaleEffect(pop ? 1 : 0.96, anchor: growsUp ? .bottom : .top)
        .opacity(pop ? 1 : 0)
        .onAppear { focused = true; settle() }
        .onChange(of: model.openTick) { _, _ in settle() }
        .onChange(of: model.showingActions) { _, on in
            if on { model.actionCount = actions.count; model.actionIndex = 0 }
        }
        .onKeyPress(phases: [.down, .repeat]) { press in handle(press) }
        .animation(.smooth(duration: 0.16), value: model.showingActions)
        .animation(.smooth(duration: 0.16), value: model.token)
    }

    // MARK: Glass

    /// A piece of clear glass: the material, a bloom of light from the top left, a darker foot for depth, a bright rim along the
    /// top edge with a faint one inside it, and a tight shadow under a wide soft one.
    private func glass<S: InsettableShape>(_ shape: S) -> some View {
        ZStack {
            if case .solid(let r, let g, let b) = theme.background {
                shape.fill(Color(red: r, green: g, blue: b))
            } else {
                shape.fill(.ultraThinMaterial)
            }
            shape.fill(scheme == .dark ? Color.black.opacity(0.12) : Color.white.opacity(0.30)).opacity(theme.background == .glass ? 1 : 0)
            shape.fill(RadialGradient(colors: [Color.white.opacity(scheme == .dark ? 0.17 : 0.45), Color.clear], center: .topLeading, startRadius: 0, endRadius: 380))
            shape.fill(LinearGradient(colors: [Color.clear, Color.black.opacity(scheme == .dark ? 0.12 : 0.04)], startPoint: .center, endPoint: .bottom))
        }
        .overlay(shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.75), Color.white.opacity(0.14), Color.white.opacity(0.06), Color.white.opacity(0.30)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
        .overlay(shape.inset(by: 1).strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.22), radius: 5, y: 2)
        .shadow(color: Color.black.opacity(0.32), radius: 30, y: 16)
    }

    // MARK: The search pill

    private var searchPill: some View {
        HStack(spacing: 12) {
            if let token = model.token {
                HStack(spacing: 6) {
                    Image(systemName: token.symbol).font(.system(size: 12, weight: .semibold))
                    Text(token.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                }
                .padding(.horizontal, 11).padding(.vertical, 5)
                .background(Color.white.opacity(0.16), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.28), lineWidth: 0.75))
                .transition(.scale.combined(with: .opacity))
            }
            TextField(model.token?.placeholder ?? (model.selectionText == nil ? "Spotlight Search" : "Do something with the selected text"), text: $model.query)
                .textFieldStyle(.plain).font(.system(size: 20, weight: .regular)).focused($focused)
                .onSubmit { submit() }
                .onKeyPress(phases: [.down, .repeat]) { press in fieldKey(press) }
            if !model.query.isEmpty {
                Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 15)).foregroundStyle(.tertiary) }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 26)
        .frame(height: PaletteLayout.searchHeight)
        .background(glass(Capsule(style: .continuous)))
    }

    // MARK: The results panel

    private var resultsPanel: some View {
        VStack(spacing: 0) {
            chips
            ZStack(alignment: .bottomTrailing) {
                list
                if model.showingActions, let entry = model.current { actionMenu(for: entry) }
            }
        }
        .padding(.bottom, PaletteLayout.panelPadding)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(glass(RoundedRectangle(cornerRadius: 28, style: .continuous)))
    }

    /// The kinds of thing found, as small pills. The one the highlighted result belongs to is lit; click one to jump to it.
    private var chips: some View {
        let kinds = model.results.map(\.category).reduce(into: [LauncherCategory]()) { if !$0.contains($1) { $0.append($1) } }
        let active = model.current?.category
        return HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(kinds, id: \.self) { kind in
                        Button {
                            if let index = model.results.firstIndex(where: { $0.category == kind }) { model.selected = index }
                        } label: {
                            Text(kind.label).font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(kind == active ? Color.primary : Color.primary.opacity(0.70))
                                .padding(.horizontal, 12).padding(.vertical, 5)
                                .background(Capsule().fill(kind == active
                                    ? (accentColor.map { AnyShapeStyle($0.opacity(0.55)) } ?? AnyShapeStyle(LinearGradient(colors: [lift.opacity(scheme == .dark ? 0.28 : 0.14), lift.opacity(scheme == .dark ? 0.12 : 0.06)], startPoint: .top, endPoint: .bottom)))
                                    : AnyShapeStyle(lift.opacity(scheme == .dark ? 0.07 : 0.05))))
                                .overlay(Capsule().strokeBorder(lift.opacity(kind == active ? (scheme == .dark ? 0.38 : 0.22) : 0.12), lineWidth: 0.8))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
            Text("⌘K").font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .frame(height: PaletteLayout.chipsHeight)
        .animation(.smooth(duration: 0.14), value: active)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { index, entry in
                        if !typed, index == 0 || model.sections.indices.contains(index) && model.sections[index] != model.sections[index - 1] {
                            header(model.sections.indices.contains(index) ? model.sections[index] : "")
                        }
                        row(entry, index: index)
                            .id(entry.id)
                            .onTapGesture { palette.run(entry) }
                    }
                }
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.hidden)
            .onChange(of: model.selected) { _, new in
                if model.results.indices.contains(new) { withAnimation(.smooth(duration: 0.12)) { proxy.scrollTo(model.results[new].id) } }
            }
        }
    }

    private func header(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            .frame(height: PaletteLayout.headerHeight, alignment: .bottom).padding(.horizontal, 12).padding(.bottom, 4)
    }

    @ViewBuilder
    private var emptyPanel: some View {
        VStack(spacing: 5) {
            if typed {
                Text("No results").font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
            } else {
                Text("Search apps, files, windows and the web").font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
                Text("Try a sum like 12*8, “timer 5m”, “note buy milk”, or “yt cats” to search YouTube.")
                    .font(.system(size: 12)).foregroundStyle(.tertiary).multilineTextAlignment(.center).frame(maxWidth: 460)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(glass(RoundedRectangle(cornerRadius: 28, style: .continuous)))
    }

    private func row(_ entry: PaletteEntry, index: Int) -> some View {
        let on = index == model.selected
        let pinned = prefs.isPinned(entry.id)
        let alias = prefs.alias(for: entry.id)
        return HStack(spacing: 14) {
            icon(entry)
            VStack(alignment: .leading, spacing: 2) {
                title(for: entry).foregroundStyle(Color.primary).lineLimit(1)
                if let detail = FileDetail.text(for: entry) ?? entry.subtitle, !detail.isEmpty {
                    Text(detail).font(.system(size: 12.5)).foregroundStyle(Color.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if pinned { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(Theme.warn) }
            if let alias {
                Text(alias).font(.system(size: 10, design: .rounded)).padding(.horizontal, 6).padding(.vertical, 1.5)
                    .background(Color.primary.opacity(0.1), in: Capsule())
            }
            if on { Text("↩").font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(.tertiary).transition(.opacity) }
        }
        .padding(.horizontal, 12)
        .frame(height: PaletteLayout.rowHeight)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(accentColor.map { AnyShapeStyle(LinearGradient(colors: [$0.opacity(0.62), $0.opacity(0.40)], startPoint: .top, endPoint: .bottom)) }
                      ?? AnyShapeStyle(LinearGradient(colors: [lift.opacity(scheme == .dark ? 0.22 : 0.12), lift.opacity(scheme == .dark ? 0.10 : 0.06)], startPoint: .top, endPoint: .bottom)))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [(accentColor ?? lift).opacity(scheme == .dark ? 0.42 : 0.25), (accentColor ?? lift).opacity(0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 0.9))
                .shadow(color: (accentColor ?? Color.black).opacity(accentColor == nil ? 0.20 : 0.30), radius: 7, y: 3)
                .opacity(on ? 1 : 0)
        }
        .contentShape(Rectangle())
        .animation(.smooth(duration: 0.14), value: on)
    }

    /// The title, with the letters you typed in bold so you can see why it was found.
    private func title(for entry: PaletteEntry) -> Text {
        let plain = Text(entry.title).font(.system(size: 15, weight: .medium))
        let words = model.effectiveQuery.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard entry.queryScore == nil, !words.isEmpty else { return plain }
        var attributed = AttributedString(entry.title)
        attributed.font = .system(size: 15, weight: .medium)
        var marked = false
        for word in words {
            var from = entry.title.startIndex
            while from < entry.title.endIndex, let found = entry.title.range(of: word, options: [.caseInsensitive, .diacriticInsensitive], range: from..<entry.title.endIndex) {
                if let lo = AttributedString.Index(found.lowerBound, within: attributed), let hi = AttributedString.Index(found.upperBound, within: attributed) {
                    attributed[lo..<hi].font = .system(size: 15, weight: .bold)
                    marked = true
                }
                from = found.upperBound
            }
        }
        return marked ? Text(attributed) : plain
    }

    @ViewBuilder
    private func icon(_ entry: PaletteEntry) -> some View {
        if let hex = entry.swatchHex {
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.fromHex(hex)).frame(width: 36, height: 36)
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.3), lineWidth: 1))
        } else if let path = entry.iconPath {
            Image(nsImage: PaletteIcons.icon(at: path)).resizable().frame(width: 36, height: 36)
        } else {
            Image(systemName: entry.symbol).font(.system(size: 17, weight: .regular))
                .frame(width: 36, height: 36)
                .foregroundStyle(Color.primary.opacity(0.85))
                .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }

    // MARK: Actions menu

    private func actionMenu(for entry: PaletteEntry) -> some View {
        let items = actions
        return VStack(alignment: .leading, spacing: 2) {
            Text(entry.title).font(.caption).foregroundStyle(.secondary).lineLimit(1).padding(.horizontal, 8).padding(.top, 4)
            ForEach(Array(items.enumerated()), id: \.element.id) { index, action in
                HStack(spacing: 8) {
                    Image(systemName: action.symbol).frame(width: 16)
                    Text(action.title)
                    Spacer(minLength: 0)
                    if let hint = action.hint { Text(hint).font(.caption).foregroundStyle(.tertiary) }
                }
                .font(.callout)
                .foregroundStyle(action.destructive ? Color.red : Color.primary)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(index == model.actionIndex ? Color.white.opacity(0.14) : Color.clear))
                .contentShape(Rectangle())
                .onTapGesture { runAction(action, for: entry) }
            }
            if items.isEmpty { Text("Nothing else to do with this.").font(.callout).foregroundStyle(.secondary).padding(8) }
        }
        .padding(6).frame(width: 340)
        .background(glass(RoundedRectangle(cornerRadius: 14, style: .continuous)))
        .padding(10)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
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

    private func stepHistory(older: Bool) {
        let store = SearchHistoryStore.shared
        guard store.isEnabled else { return }
        let recent = store.history.recent(30)
        if model.historyIndex == nil { model.historyDraft = model.query }
        let next = older ? SearchHistory.older(model.historyIndex, count: recent.count) : SearchHistory.newer(model.historyIndex)
        model.historyIndex = next
        model.query = next.flatMap { recent.indices.contains($0) ? recent[$0].text : nil } ?? model.historyDraft
        // Setting the box would otherwise count as typing and end the stepping.
        model.historyIndex = next
    }

    private func runAction(_ action: PaletteAction, for entry: PaletteEntry) {
        model.showingActions = false
        // Favorites and hiding change the list in place; everything else acts on the result and closes the window.
        if action.keepsOpen {
            action.run()
            model.refresh()
        } else {
            palette.run(entry, action: action)
        }
    }

    /// Keys the search box would otherwise take: Backspace on an empty box takes the chip off, Tab goes into a folder and Shift-Tab
    /// up, and ⌘Return does the first thing in the ⌘K menu.
    private func fieldKey(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .delete:
            if model.query.isEmpty, model.token != nil { model.clearToken(); return .handled }
            return .ignored
        case .tab:
            if press.modifiers.contains(.shift) { return palette.folderUp() ? .handled : .ignored }
            return palette.folderIn() ? .handled : .ignored
        case .return:
            guard press.modifiers.contains(.command), let entry = model.current, let first = palette.actions(for: entry).first else { return .ignored }
            palette.run(entry, action: first)
            return .handled
        default:
            return .ignored
        }
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        // ⌥↑ and ⌥↓ step back and forward through past searches, like the arrow keys in a shell.
        if press.modifiers.contains(.option), press.key == .upArrow || press.key == .downArrow {
            stepHistory(older: press.key == .upArrow)
            return .handled
        }
        switch press.key {
        case .downArrow: model.move(1); return .handled
        case .upArrow: model.move(-1); return .handled
        case .escape:
            if model.showingActions {
                model.showingActions = false
            } else if !model.query.isEmpty {
                model.query = ""
            } else if model.token != nil {
                model.clearToken()
                model.query = ""
            } else {
                palette.close()
            }
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


private extension LauncherCategory {
    /// The colour of this kind of result's icon.
    var tint: Color {
        switch self {
        case .app: return Color(red: 0.25, green: 0.52, blue: 0.96)
        case .window: return Color(red: 0.18, green: 0.68, blue: 0.54)
        case .clipboard: return Color(red: 0.95, green: 0.60, blue: 0.20)
        case .file: return Color(red: 0.42, green: 0.55, blue: 0.72)
        case .web: return Color(red: 0.16, green: 0.66, blue: 0.82)
        case .system: return Color(red: 0.52, green: 0.54, blue: 0.60)
        case .emoji: return Color(red: 0.96, green: 0.72, blue: 0.16)
        case .intelligence: return Color(red: 0.72, green: 0.38, blue: 0.92)
        case .tools, .calculator, .utility: return Color(red: 0.52, green: 0.40, blue: 0.90)
        case .snippet, .action, .workflow: return Color(red: 0.90, green: 0.42, blue: 0.54)
        case .layout, .feature, .setting, .command: return Theme.accent
        }
    }
}


/// "PDF document · 120 KB · Yesterday, 6:27 PM · Downloads": what the system's own search shows under a file.
private enum FileDetail {
    private static var cache: [URL: String] = [:]

    static func text(for entry: PaletteEntry) -> String? {
        guard let url = entry.fileURL else { return nil }
        if let hit = cache[url] { return hit }
        let keys: Set<URLResourceKey> = [.localizedTypeDescriptionKey, .fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        var parts: [String] = []
        if let kind = values.localizedTypeDescription { parts.append(kind) }
        if values.isDirectory != true, let size = values.fileSize { parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) }
        if let date = values.contentModificationDate { parts.append(date.formatted(.relative(presentation: .named))) }
        parts.append(url.deletingLastPathComponent().lastPathComponent)
        let text = parts.joined(separator: " · ")
        if cache.count > 500 { cache.removeAll() }
        cache[url] = text
        return text
    }
}


/// How long each launcher source took, kept in memory only.
final class LauncherLatencyStore: ObservableObject {
    static let shared = LauncherLatencyStore()
    private let lock = NSLock()
    private var latency = SourceLatency()

    func record(_ source: String, milliseconds: Int) {
        lock.lock(); latency.record(source, milliseconds: milliseconds); lock.unlock()
    }

    var snapshot: SourceLatency {
        lock.lock(); defer { lock.unlock() }
        return latency
    }
}
