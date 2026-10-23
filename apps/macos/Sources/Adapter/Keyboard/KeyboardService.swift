import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Combine

/// Runs keyboard shortcuts. A shortcut is taken (the app never sees the key) only when one is defined for the app in
/// front; every other key passes through untouched.
final class ShortcutEngine {
    private let store: KeyboardStore
    private let events: EventMonitor
    private let front: FrontAppTracker
    private let run: (ShortcutTarget) -> Void
    private var token: EventMonitor.Token?

    init(store: KeyboardStore, events: EventMonitor, front: FrontAppTracker, run: @escaping (ShortcutTarget) -> Void) {
        self.store = store
        self.events = events
        self.front = front
        self.run = run
    }

    /// Watches keys only while at least one shortcut exists.
    func update() {
        if store.hasShortcuts {
            guard token == nil else { return }
            token = events.subscribe(owner: "keyboard.shortcuts", events: [.keyDown], mode: .active) { [weak self] _, event in self?.handle(event) ?? .passThrough }
        } else if let token {
            events.unsubscribe(token)
            self.token = nil
        }
    }

    func stop() {
        if let token { events.unsubscribe(token) }
        token = nil
    }

    private func handle(_ event: CGEvent) -> EventDisposition {
        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let modifiers = KeyModifiers.bits(from: event.flags) & ~KeyModifiers.function
        guard let shortcut = store.shortcut(keyCode: keyCode, modifiers: modifiers, app: front.bundleID) else { return .passThrough }
        // Holding the keys down repeats the key press; the shortcut runs once.
        if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            let target = shortcut.target
            DispatchQueue.main.async { [run] in run(target) }
        }
        return .drop
    }
}

/// Watches typing for abbreviations and replaces them. It sees only the last few characters, forgets them on any
/// interruption, does nothing in password fields or while macOS protects keyboard input, and never in excluded apps.
final class ExpansionEngine {
    private let store: KeyboardStore
    private let events: EventMonitor
    private let front: FrontAppTracker
    private let inserter: SnippetInserter
    private let matcher = ExpansionMatcher()
    private var token: EventMonitor.Token?
    private var mouseToken: EventMonitor.Token?
    private var resetObserver: NSObjectProtocol?

    init(store: KeyboardStore, events: EventMonitor, front: FrontAppTracker, inserter: SnippetInserter) {
        self.store = store
        self.events = events
        self.front = front
        self.inserter = inserter
    }

    func start() {
        guard token == nil else { return }
        matcher.setSnippets(snippets: store.snippets)
        token = events.subscribe(owner: "keyboard.expansion", events: [.keyDown], mode: .listenOnly) { [weak self] _, event in
            self?.key(event)
            return .passThrough
        }
        mouseToken = events.subscribe(owner: "keyboard.expansion.mouse", events: [.leftMouseDown, .rightMouseDown, .otherMouseDown], mode: .listenOnly) { [weak self] _, _ in
            self?.matcher.reset()
            return .passThrough
        }
        resetObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.matcher.reset()
        }
    }

    func stop() {
        if let token { events.unsubscribe(token) }
        if let mouseToken { events.unsubscribe(mouseToken) }
        token = nil
        mouseToken = nil
        if let resetObserver { NSWorkspace.shared.notificationCenter.removeObserver(resetObserver) }
        resetObserver = nil
        matcher.reset()
    }

    /// Tells the matcher about the current snippets. Only snippets with an abbreviation matter.
    func snippetsChanged() {
        matcher.setSnippets(snippets: store.snippets)
    }

    private func key(_ event: CGEvent) {
        let flags = event.flags
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        // Shortcuts and navigation are not typing.
        if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) { matcher.reset(); return }
        switch keyCode {
        case 51: matcher.backspace(); return
        case 123...126, 115, 119, 116, 121, 53: matcher.reset(); return
        default: break
        }
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &buffer)
        guard length > 0 else { matcher.reset(); return }
        var text = String(utf16CodeUnits: buffer, count: length)
        if keyCode == 36 || keyCode == 76 { text = "\n" } else if keyCode == 48 { text = "\t" }
        guard let hit = matcher.feed(character: text, appId: front.bundleID) else { return }
        guard isSafe() else { matcher.reset(); return }
        DispatchQueue.main.async { [store, inserter] in
            guard let snippet = store.snippet(hit.snippetId) else { return }
            inserter.insert(snippet, deleting: Int(hit.deleteCount), trailing: hit.trailing)
        }
    }

    /// No expansion where typing may be a secret: protected input, password fields, excluded apps.
    private func isSafe() -> Bool {
        if IsSecureEventInputEnabled() { return false }
        if store.currentConfig.expansionExcludedAppIds.contains(front.bundleID ?? "") { return false }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.1)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let raw = focused, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return true }
        let element = unsafeBitCast(raw, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.1)
        func string(_ attribute: String) -> String? {
            var out: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, attribute as CFString, &out) == .success ? out as? String : nil
        }
        if string(kAXRoleAttribute) == "AXSecureTextField" || string(kAXSubroleAttribute) == "AXSecureTextField" { return false }
        let hints = [string(kAXDescriptionAttribute), string(kAXTitleAttribute), string(kAXPlaceholderValueAttribute), string(kAXHelpAttribute)].compactMap { $0?.lowercased() }
        return !hints.contains { $0.contains("password") || $0.contains("passcode") || $0.contains("passphrase") }
    }
}

/// Everything behind keyboard shortcuts, text expansion and the command launcher.
final class KeyboardService: ObservableObject {
    let store: KeyboardStore
    let front = FrontAppTracker()
    let injector: TextInjector
    let inserter: SnippetInserter
    let palette: CommandPalette

    @Published private(set) var isRunning = false

    private let toast = Toast()
    private var shortcuts: ShortcutEngine?
    private var expansion: ExpansionEngine?
    private var hotkeys: HotkeyCenter?
    private var cancellables = Set<AnyCancellable>()
    private weak var executor: ActionExecutor?
    private weak var library: ActionLibrary?

    init(store: KeyboardStore, clipboard: ClipboardService) {
        self.store = store
        injector = TextInjector(clipboard: clipboard, store: store)
        inserter = SnippetInserter(store: store, injector: injector)
        SnippetInserter.lookup = { [weak store] name in
            let wanted = name.lowercased()
            return store?.snippets.first { $0.enabled && ($0.abbreviation?.lowercased() == wanted || $0.title.lowercased() == wanted) }?.body
        }
        palette = CommandPalette()
    }

    func start(context: ServiceContext) {
        guard !isRunning else { return }
        isRunning = true
        executor = context.executor
        library = context.library
        front.start()
        let shortcuts = ShortcutEngine(store: store, events: context.events, front: front) { [weak self] target in self?.run(target) }
        let expansion = ExpansionEngine(store: store, events: context.events, front: front, inserter: inserter)
        self.shortcuts = shortcuts
        self.expansion = expansion
        shortcuts.update()
        expansion.start()
        hotkeys = HotkeyCenter(owner: "Keyboard") { [weak self] _ in self?.palette.toggle() }

        store.$shortcuts.combineLatest(store.$snippets, store.$config)
            .debounce(for: .milliseconds(60), scheduler: DispatchQueue.main)
            .sink { [weak self] shortcuts, _, config in
                self?.listShortcuts(shortcuts)
                self?.shortcuts?.update()
                self?.expansion?.snippetsChanged()
                if let key = config.paletteKey, config.paletteModifiers != 0 {
                    self?.hotkeys?.update([ShortcutBinding(command: "palette.open", keyCode: key, modifiers: config.paletteModifiers)])
                } else {
                    self?.hotkeys?.update([])
                }
            }
            .store(in: &cancellables)

        // Commands other parts of Kriya offer, so a shortcut or a workflow can run them by name.
        let clipboard = context.clipboard, selection = context.selection, finder = context.finder
        context.executor.registerCommand("palette.open") { [weak self] in self?.palette.toggle() }
        context.executor.registerCommand("clipboard.quick") { clipboard.quick.toggle() }
        context.executor.registerCommand("clipboard.plain") { clipboard.paster.pasteCurrentAsPlainText() }
        context.executor.registerCommand("clipboard.strip") { clipboard.paster.removeFormattingFromClipboard() }
        context.executor.registerCommand("clipboard.pause") { clipboard.setPaused(!clipboard.store.config.paused) }
        context.executor.registerCommand("selection.manual") { selection.showManually() }
        context.executor.registerCommand("finder.launcher") { finder.launcher.show() }
        palette.configure(context: context, keyboard: self)
        Log.info("Keyboard", "Keyboard shortcuts and text expansion started")
    }

    func stop(context: ServiceContext?) {
        guard isRunning else { return }
        isRunning = false
        cancellables.removeAll()
        shortcuts?.stop()
        expansion?.stop()
        shortcuts = nil
        expansion = nil
        hotkeys?.unregisterAll()
        hotkeys = nil
        front.stop()
        for command in ["palette.open", "clipboard.quick", "clipboard.plain", "clipboard.strip", "clipboard.pause", "selection.manual", "finder.launcher"] {
            context?.executor.unregisterCommand(command)
        }
        palette.close()
    }

    /// Tells the shared shortcut list about the shortcuts Kriya finds by watching key presses, so they are checked for clashes too.
    private func listShortcuts(_ list: [KeyShortcut]) {
        let entries = list.filter(\.enabled).map { shortcut -> ShortcutEntry in
            var apps: [String] = []
            if case .onlyApps(let ids) = shortcut.scope { apps = ids }
            return ShortcutEntry(owner: "Keyboard shortcuts", command: shortcut.id, title: shortcut.name, keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, apps: apps)
        }
        ShortcutRegistry.shared.setPassive(owner: "Keyboard shortcuts", entries: entries)
    }

    /// Carries out what a shortcut is set to do.
    func run(_ target: ShortcutTarget) {
        switch target {
        case .snippet(let id):
            guard let snippet = store.snippet(id) else { toast.show("That snippet no longer exists.", isError: true); return }
            inserter.insert(snippet)
        case .action(let id):
            guard let executor, let saved = library?.actions.first(where: { $0.id == id }) else { toast.show("That action no longer exists.", isError: true); return }
            Task { if case .failure(let message) = await executor.perform(saved.action) { toast.show(message, isError: true) } }
        case .command(let command):
            guard let executor else { return }
            Task { if case .failure(let message) = await executor.perform(.builtin(command: command)) { toast.show(message, isError: true) } }
        }
    }
}

/// The keyboard feature as a switchable module.
final class KeyboardFeature: FeatureModule {
    let feature = FeatureId.keyboard
    private var context: ServiceContext?

    func start(context: ServiceContext) throws {
        self.context = context
        context.keyboard.start(context: context)
    }

    func stop() {
        context?.keyboard.stop(context: context)
        context = nil
    }
}
