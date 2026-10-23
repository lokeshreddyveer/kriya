import Combine
import Foundation

extension SavedLayout: Identifiable {}
extension PlacementRule: Identifiable {}
extension CustomSize: Identifiable {}
extension WindowLayout: Identifiable {
    public var id: String { windowLayoutCommand(layout: self) }
    var title: String { windowLayoutTitle(layout: self) }
    var command: String { windowLayoutCommand(layout: self) }
}

/// Window management settings: options, shortcuts, custom sizes, saved layouts and placement rules.
final class WindowStore: ObservableObject {
    @Published private(set) var config = defaultWindowConfig()
    @Published private(set) var shortcuts: [ShortcutBinding] = []
    @Published private(set) var sizes: [CustomSize] = []
    @Published private(set) var layouts: [SavedLayout] = []
    @Published private(set) var rules: [PlacementRule] = []
    @Published var lastError: String?

    private let core: KriyaCore
    private let lock = NSLock()
    private var configSnapshot = defaultWindowConfig()   // guarded by lock, for other threads
    private var pendingConfigSave: DispatchWorkItem?

    init(core: KriyaCore) {
        self.core = core
        reload()
    }

    func reload() {
        do {
            config = try core.windowConfig()
            shortcuts = try core.windowShortcuts()
            sizes = try core.customSizes()
            layouts = try core.savedLayouts(includeAuto: false)
            rules = try core.windowRules()
        } catch {
            Log.error("Windows", "Could not load window settings: \(error.userMessage)")
        }
        publishSnapshot()
    }

    /// The options, readable from any thread.
    var currentConfig: WindowConfig {
        lock.lock()
        defer { lock.unlock() }
        return configSnapshot
    }

    private func publishSnapshot() {
        lock.lock()
        configSnapshot = config
        lock.unlock()
    }

    // MARK: Options

    /// Changes show at once and are saved a moment later, so a slider does not write on every step.
    func updateConfig(_ change: (inout WindowConfig) -> Void) {
        change(&config)
        publishSnapshot()
        pendingConfigSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.writeConfig() }
        pendingConfigSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func writeConfig() {
        pendingConfigSave = nil
        do {
            try core.saveWindowConfig(config: config)
            lastError = nil
        } catch {
            lastError = error.userMessage
        }
    }

    func flushPendingSaves() {
        guard let work = pendingConfigSave else { return }
        work.cancel()
        writeConfig()
    }

    // MARK: Shortcuts

    func shortcut(for command: String) -> ShortcutBinding? {
        shortcuts.first { $0.command == command }
    }

    /// Sets or clears the shortcut for a command. Refused, with the reason, if another command already uses the keys.
    func setShortcut(_ command: String, keyCode: UInt16?, modifiers: UInt64) {
        var list = shortcuts.filter { $0.command != command }
        if let keyCode { list.append(ShortcutBinding(command: command, keyCode: keyCode, modifiers: modifiers)) }
        saveShortcuts(list)
    }

    func resetShortcuts() {
        saveShortcuts(defaultWindowShortcuts())
    }

    private func saveShortcuts(_ list: [ShortcutBinding]) {
        do {
            try core.saveWindowShortcuts(list: list)
            lastError = nil
        } catch {
            lastError = error.userMessage
        }
        reload()
    }

    // MARK: Sizes, layouts, rules

    func saveSize(_ size: CustomSize) {
        perform { try core.saveCustomSize(size: size) }
    }

    func deleteSize(_ id: String) {
        perform { try core.deleteCustomSize(id: id) }
    }

    func saveLayout(_ layout: SavedLayout) {
        perform { try core.saveLayout(layout: layout) }
    }

    func layoutVersions(of id: String) -> [LayoutVersion] { (try? core.layoutVersions(id: id)) ?? [] }
    func restoreLayoutVersion(_ id: String, seq: UInt32) { perform { _ = try core.restoreLayoutVersion(id: id, seq: seq) } }
    func deleteLayoutVersion(_ id: String, seq: UInt32) { perform { try core.deleteLayoutVersion(id: id, seq: seq) } }
    func nameLayoutVersion(_ id: String, seq: UInt32, label: String) { perform { try core.nameLayoutVersion(id: id, seq: seq, label: label) } }

    func exportLayouts(to url: URL) throws {
        try core.exportLayouts(ids: []).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Adds the layouts in a file under new ids. Returns how many were added.
    func importLayouts(from url: URL) throws -> Int {
        guard let json = String(data: try Data(contentsOf: url), encoding: .utf8) else { throw CoreError.Backup(message: "the file is not a Kriya layout file") }
        let added = try core.importLayouts(json: json, now: SystemInfo.nowSeconds)
        reload()
        return added.count
    }

    func deleteLayout(_ id: String) {
        perform { try core.deleteLayout(id: id) }
    }

    func saveRule(_ rule: PlacementRule) {
        perform { try core.saveWindowRule(rule: rule) }
    }

    func deleteRule(_ id: String) {
        perform { try core.deleteWindowRule(id: id) }
    }

    func restoreDefaults(everything: Bool) {
        pendingConfigSave?.cancel()
        pendingConfigSave = nil
        perform { try core.restoreDefaultWindowSettings(everything: everything) }
    }

    private func perform(_ work: () throws -> Void) {
        do {
            try work()
            lastError = nil
        } catch {
            lastError = error.userMessage
        }
        reload()
    }

    // MARK: Names

    /// Every command a shortcut can run, with a title, for the shortcuts list.
    func title(forCommand command: String) -> String {
        if let layout = windowLayoutFromCommand(command: command) { return layout.title }
        if let extra = windowExtraCommands().first(where: { $0.command == command }) { return extra.title }
        if command.hasPrefix("window.size."), let size = sizes.first(where: { "window.size.\($0.id.lowercased())" == command }) {
            return "Size: \(size.name)"
        }
        if command.hasPrefix("window.layout."), let layout = layouts.first(where: { "window.layout.\($0.id.lowercased())" == command }) {
            return layout.isGroup ? "Group: \(layout.name)" : "Layout: \(layout.name)"
        }
        return command
    }

    func sizeCommand(_ size: CustomSize) -> String { "window.size.\(size.id.lowercased())" }
    func layoutCommand(_ layout: SavedLayout) -> String { "window.layout.\(layout.id.lowercased())" }
}
