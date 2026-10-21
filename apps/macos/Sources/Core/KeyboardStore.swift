import AppKit
import Combine

extension ExpansionSnippet: Identifiable {}
extension KeyShortcut: Identifiable {}

extension ShortcutScope {
    var title: String {
        switch self {
        case .global: return "Everywhere"
        case .onlyApps(let ids): return "Only in " + ids.map { AppChoice.name(for: $0) }.joined(separator: ", ")
        case .exceptApps(let ids): return "Everywhere except " + ids.map { AppChoice.name(for: $0) }.joined(separator: ", ")
        }
    }
}

extension ExpandOn {
    var title: String {
        switch self {
        case .delimiter: return "After a space or punctuation"
        case .immediately: return "As soon as it is typed"
        }
    }
}

/// The app in front, readable from any thread (the keyboard handlers run off the main thread).
final class FrontAppTracker {
    private let lock = NSLock()
    private var current: String?
    private var observer: NSObjectProtocol?

    func start() {
        guard observer == nil else { return }
        current = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.set(app?.bundleIdentifier)
        }
    }

    func stop() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
    }

    private func set(_ id: String?) {
        lock.lock()
        current = id
        lock.unlock()
    }

    var bundleID: String? {
        lock.lock()
        defer { lock.unlock() }
        return current
    }
}

/// Keyboard shortcuts, text-expansion snippets and their settings.
final class KeyboardStore: ObservableObject {
    @Published private(set) var config = defaultKeyboardConfig()
    @Published private(set) var shortcuts: [KeyShortcut] = []
    @Published private(set) var snippets: [ExpansionSnippet] = []
    @Published private(set) var categories: [String] = []
    @Published var lastError: String?
    /// Warnings from the last save, such as an abbreviation that a shorter one cuts short.
    @Published var lastWarnings: [String] = []

    /// What the rest of Kriya uses, so a shortcut cannot take it. Set once everything exists.
    var reservedProvider: () -> [ReservedKey] = { [] }

    private let core: KriyaCore
    private let lock = NSLock()
    private var snapshot = Snapshot()   // guarded by lock

    private struct Snapshot {
        var shortcuts: [KeyShortcut] = []
        var combos: Set<UInt32> = []
        var config = defaultKeyboardConfig()
    }

    init(core: KriyaCore) {
        self.core = core
        reload()
    }

    func reload() {
        do {
            config = try core.keyboardConfig()
            shortcuts = try core.keyShortcuts()
            snippets = try core.textSnippets()
            categories = try core.textSnippetCategories()
        } catch {
            Log.error("Keyboard", "Could not load keyboard settings: \(error.userMessage)")
        }
        publish()
    }

    private func publish() {
        let enabled = shortcuts.filter(\.enabled)
        lock.lock()
        snapshot = Snapshot(shortcuts: enabled, combos: Set(enabled.map { Self.combo($0.keyCode, $0.modifiers) }), config: config)
        lock.unlock()
    }

    static func combo(_ keyCode: UInt16, _ modifiers: UInt64) -> UInt32 { UInt32(keyCode) << 8 | UInt32(modifiers & 0xFF) }

    // MARK: For the event tap (any thread)

    /// The shortcut for a key press, or `nil`. The quick check first keeps ordinary typing out of the core.
    func shortcut(keyCode: UInt16, modifiers: UInt64, app: String?) -> KeyShortcut? {
        lock.lock()
        let current = snapshot
        lock.unlock()
        guard current.combos.contains(Self.combo(keyCode, modifiers)) else { return nil }
        return keyShortcutFind(list: current.shortcuts, keyCode: keyCode, modifiers: modifiers, appId: app)
    }

    var hasShortcuts: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !snapshot.combos.isEmpty
    }

    var currentConfig: KeyboardConfig {
        lock.lock()
        defer { lock.unlock() }
        return snapshot.config
    }

    // MARK: Shortcuts

    func checkShortcut(_ candidate: KeyShortcut) -> [ShortcutConflict] {
        let others = shortcuts
        return keyShortcutConflicts(candidate: candidate, existing: others, reserved: reservedProvider())
    }

    func saveShortcut(_ shortcut: KeyShortcut) {
        var list = shortcuts
        if let index = list.firstIndex(where: { $0.id == shortcut.id }) { list[index] = shortcut } else { list.append(shortcut) }
        saveShortcuts(list)
    }

    func deleteShortcut(_ id: String) { saveShortcuts(shortcuts.filter { $0.id != id }) }
    func setShortcutEnabled(_ id: String, _ on: Bool) { saveShortcuts(shortcuts.map { var s = $0; if s.id == id { s.enabled = on }; return s }) }

    private func saveShortcuts(_ list: [KeyShortcut]) {
        perform { try core.saveKeyShortcuts(list: list, reserved: reservedProvider()) }
    }

    // MARK: Snippets

    func snippet(_ id: String) -> ExpansionSnippet? { snippets.first { $0.id == id } }

    func newSnippet() -> ExpansionSnippet {
        ExpansionSnippet(
            id: UUID().uuidString, title: "", abbreviation: nil, body: "", category: nil, favorite: false, enabled: true, appIds: [],
            caseSensitive: false, expandOn: config.expansionDefaultExpandOn, useCount: 0, createdAt: 0, updatedAt: 0
        )
    }

    @discardableResult
    func saveSnippet(_ snippet: ExpansionSnippet) -> Bool {
        do {
            let warnings = try core.saveTextSnippet(snippet: snippet, now: SystemInfo.nowSeconds)
            lastWarnings = warnings.map { "“\($0.abbreviation)” (\($0.title)) will expand first and cut this abbreviation short." }
            lastError = nil
            reload()
            return true
        } catch {
            lastError = error.userMessage
            return false
        }
    }

    func deleteSnippet(_ id: String) { perform { try core.deleteTextSnippet(id: id) } }
    func markUsed(_ id: String) { try? core.markTextSnippetUsed(id: id) }

    func toggleFavorite(_ id: String) {
        guard var s = snippet(id) else { return }
        s.favorite.toggle()
        saveSnippet(s)
    }

    func search(_ query: String, category: String? = nil, favoritesOnly: Bool = false, limit: UInt32 = 500) -> [ExpansionSnippet] {
        (try? core.searchTextSnippets(query: query, category: category, favoritesOnly: favoritesOnly, limit: limit)) ?? []
    }

    func exportSnippets(_ ids: [String], to url: URL) throws {
        try core.exportTextSnippets(ids: ids).write(to: url, atomically: true, encoding: .utf8)
    }

    func importSnippets(from url: URL) throws -> TextSnippetImportSummary {
        let data = try Data(contentsOf: url)
        guard let json = String(data: data, encoding: .utf8) else { throw CoreError.Backup(message: "the file is not a Kriya snippet file") }
        let summary = try core.importTextSnippets(json: json, now: SystemInfo.nowSeconds)
        reload()
        return summary
    }

    // MARK: Settings

    func updateConfig(_ change: (inout KeyboardConfig) -> Void) {
        var updated = config
        change(&updated)
        perform { try core.saveKeyboardConfig(config: updated) }
    }

    func restoreDefaults(everything: Bool) { perform { try core.restoreDefaultKeyboardSettings(everything: everything) } }

    private func perform(_ work: () throws -> Void) {
        do {
            try work()
            lastError = nil
        } catch {
            lastError = error.userMessage
        }
        reload()
    }
}
