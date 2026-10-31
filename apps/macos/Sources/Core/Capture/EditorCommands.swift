import Foundation

/// The commands of the annotate editor. They belong to the editor window only: they are not global shortcuts and never take over keys
/// anywhere else. Each has a name that never changes.
enum EditorCommand: String, CaseIterable, Identifiable, Codable {
    case save, saveAs, upload, print, copy, duplicate, addFile, addClipboardImage, undo, redo, restoreDefaults

    var id: String { rawValue }

    var title: String {
        switch self {
        case .save: return "Save"
        case .saveAs: return "Save As…"
        case .upload: return "Upload"
        case .print: return "Print…"
        case .copy: return "Copy the Picture"
        case .duplicate: return "Duplicate the Last Mark"
        case .addFile: return "Add a Picture From a File…"
        case .addClipboardImage: return "Add the Picture on the Clipboard"
        case .undo: return "Undo"
        case .redo: return "Redo"
        case .restoreDefaults: return "Restore Shortcut Defaults"
        }
    }

    /// A command a text field already understands. While a note is being typed these are left to the text, not taken by the editor.
    var isStandardTextCommand: Bool { self == .copy || self == .undo || self == .redo }
}

/// One key and the modifiers it is pressed with.
struct EditorKey: Codable, Equatable, Hashable {
    enum Modifier: String, Codable, CaseIterable { case command, shift, option, control }

    var key: String
    var modifiers: [Modifier]

    init(_ key: String, _ modifiers: [Modifier]) {
        self.key = key.lowercased()
        self.modifiers = Modifier.allCases.filter { modifiers.contains($0) }
    }

    /// ⇧⌘C
    var display: String {
        let marks: [Modifier: String] = [.control: "⌃", .option: "⌥", .shift: "⇧", .command: "⌘"]
        let order: [Modifier] = [.control, .option, .shift, .command]
        return order.filter { modifiers.contains($0) }.compactMap { marks[$0] }.joined() + key.uppercased()
    }

    /// Plain letters would take over typing; a key needs ⌘, ⌃ or ⌥.
    var isUsable: Bool { key.count == 1 && (modifiers.contains(.command) || modifiers.contains(.control) || modifiers.contains(.option)) }
}

/// What happens when an editor shortcut is pressed.
enum EditorCommandOutcome: Equatable {
    /// The editor does it.
    case run
    /// A note is being typed and this is not a text command: nothing happens.
    case disabled
    /// A note is being typed and this is a text command: the text field handles it, not the editor.
    case leaveToText
    /// The command cannot be done now (nothing to undo, no mark to duplicate); the reason says why.
    case unavailable(String)
}

/// The editor's own commands and their keys: the defaults, what the person changed, and what each does at the moment.
struct EditorCommandRegistry: Equatable {
    /// The keys each command has until changed.
    static let defaults: [EditorCommand: EditorKey] = [
        .save: EditorKey("s", [.command]),
        .saveAs: EditorKey("s", [.command, .shift]),
        .upload: EditorKey("u", [.command]),
        .print: EditorKey("p", [.command]),
        .copy: EditorKey("c", [.command, .shift]),
        .duplicate: EditorKey("d", [.command]),
        .addFile: EditorKey("i", [.command]),
        .addClipboardImage: EditorKey("v", [.command, .shift]),
        .undo: EditorKey("z", [.command]),
        .redo: EditorKey("z", [.command, .shift]),
    ]

    /// What the person changed: only the differences from the defaults. "Restore Defaults" has no key of its own.
    private(set) var overrides: [EditorCommand: EditorKey] = [:]

    init(overrides: [EditorCommand: EditorKey] = [:]) {
        self.overrides = overrides.filter { $0.key != .restoreDefaults && $0.value.isUsable }
    }

    /// The key a command uses now, or nil for one without a key.
    func key(for command: EditorCommand) -> EditorKey? { overrides[command] ?? Self.defaults[command] }

    /// The command that uses this key now, if any.
    func command(for key: EditorKey) -> EditorCommand? { EditorCommand.allCases.first { self.key(for: $0) == key } }

    enum Problem: Equatable { case notUsable, takenBy(EditorCommand), noKeyForThis }

    /// Whether `key` can be given to `command`, or why not.
    func problem(giving key: EditorKey, to command: EditorCommand) -> Problem? {
        guard command != .restoreDefaults else { return .noKeyForThis }
        guard key.isUsable else { return .notUsable }
        if let other = self.command(for: key), other != command { return .takenBy(other) }
        return nil
    }

    /// Gives a command another key. Returns the reason when that cannot be done, and nothing changes.
    @discardableResult
    mutating func set(_ key: EditorKey, for command: EditorCommand) -> Problem? {
        if let problem = problem(giving: key, to: command) { return problem }
        if Self.defaults[command] == key { overrides[command] = nil } else { overrides[command] = key }
        return nil
    }

    /// Restore Defaults: every command has its own default key again.
    mutating func restoreDefaults() { overrides = [:] }

    /// Pairs of commands that ended up on the same key (a damaged or hand-edited file), so they can be told apart.
    var clashes: [[EditorCommand]] {
        let grouped = Dictionary(grouping: EditorCommand.allCases.filter { key(for: $0) != nil }) { key(for: $0)! }
        return grouped.values.filter { $0.count > 1 }.map { $0.sorted { $0.rawValue < $1.rawValue } }.sorted { $0[0].rawValue < $1[0].rawValue }
    }

    /// What a press does now. `editingText` is true while a note is being typed or edited.
    func outcome(_ command: EditorCommand, editingText: Bool, canUndo: Bool, canRedo: Bool, hasMarks: Bool) -> EditorCommandOutcome {
        if editingText { return command.isStandardTextCommand ? .leaveToText : .disabled }
        switch command {
        case .undo: return canUndo ? .run : .unavailable("There is nothing to undo.")
        case .redo: return canRedo ? .run : .unavailable("There is nothing to redo.")
        case .duplicate: return hasMarks ? .run : .unavailable("There is no mark to duplicate.")
        default: return .run
        }
    }
}

/// The editor's shortcuts, kept as the person's own preference.
extension EditorPreferences {
    var commandRegistry: EditorCommandRegistry {
        get { EditorCommandRegistry(overrides: shortcutOverrides) }
        set { shortcutOverrides = newValue.overrides }
    }
}
