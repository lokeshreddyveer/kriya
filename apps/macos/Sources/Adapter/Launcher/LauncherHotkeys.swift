import AppKit
import SwiftUI

/// Keys for launcher results ("open Safari", "run this workflow") and for the selected-text actions, from anywhere.
final class LauncherHotkeys {
    static let selectionID = "@selection"

    private let prefs: LauncherPrefs
    private lazy var center = HotkeyCenter(owner: "Launcher results", title: { [weak self] command in self?.title(for: command) ?? command }) { [weak self] command in self?.fire(command) }
    /// Command name → result id, since a command name must be tidy and a result id may not be.
    private var commands: [String: String] = [:]
    private var titles: [String: String] = [:]

    /// Runs the result with this id (set by the palette), and opens the selection actions.
    var runResult: (String) -> Void = { _ in }
    var showSelection: () -> Void = {}

    init(prefs: LauncherPrefs) { self.prefs = prefs }

    func start() { apply() }
    func stop() { center.unregisterAll() }

    /// Sets or clears a key. Returns why it could not be used, or nil.
    @discardableResult
    func set(_ key: LauncherHotkey?, for id: String, title: String) -> String? {
        let before = prefs.hotkey(for: id)
        prefs.setHotkey(key, for: id)
        if let key { titles[id] = title; _ = key }
        let failed = apply()
        if let key, failed.contains(where: { commands[$0] == id }) {
            prefs.setHotkey(before, for: id)
            apply()
            return "“\(KeyNames.describe(keyCode: key.keyCode, modifiers: key.modifiers))” is already used by another shortcut or by macOS."
        }
        return nil
    }

    @discardableResult
    private func apply() -> [String] {
        commands = [:]
        var bindings: [ShortcutBinding] = []
        for (index, item) in prefs.data.hotkeys.sorted(by: { $0.key < $1.key }).enumerated() {
            let command = "launcher.result.\(index)"
            commands[command] = item.key
            bindings.append(ShortcutBinding(command: command, keyCode: item.value.keyCode, modifiers: item.value.modifiers))
        }
        return center.update(bindings)
    }

    private func title(for command: String) -> String {
        guard let id = commands[command] else { return "Launcher result" }
        if id == Self.selectionID { return "Launcher: actions for selected text" }
        return "Launcher: " + (titles[id] ?? prefs.data.titles[id] ?? id)
    }

    private func fire(_ command: String) {
        guard let id = commands[command] else { return }
        DispatchQueue.main.async { id == Self.selectionID ? self.showSelection() : self.runResult(id) }
    }
}

/// A small key recorder for an alert's accessory view.
final class LauncherHotkeyRecorder: ObservableObject {
    @Published var shortcut: RecordedShortcut?

    var value: LauncherHotkey? { shortcut.map { LauncherHotkey(keyCode: $0.keyCode, modifiers: $0.modifiers) } }

    init(initial: LauncherHotkey?) {
        shortcut = initial.map { RecordedShortcut(keyCode: $0.keyCode, modifiers: $0.modifiers) }
    }

    /// The recorder as a view an alert can hold.
    var view: NSView {
        let host = NSHostingView(rootView: Field(model: self))
        host.frame = NSRect(x: 0, y: 0, width: 220, height: 30)
        return host
    }

    private struct Field: View {
        @ObservedObject var model: LauncherHotkeyRecorder
        var body: some View { ShortcutRecorder(shortcut: $model.shortcut).frame(width: 220, height: 28) }
    }
}
