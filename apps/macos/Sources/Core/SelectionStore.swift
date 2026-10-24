import AppKit
import Combine

extension SelectionAction: Identifiable {}

extension TextOp {
    /// One of each step, with sensible starting values, for the "add a step" menu.
    static var catalog: [TextOp] {
        [
            .uppercase, .lowercase, .titleCase, .sentenceCase, .camelCase, .snakeCase, .kebabCase,
            .trim, .trimLines, .collapseSpaces, .removeBlankLines, .removeDuplicateLines,
            .sortLines(descending: false, caseSensitive: false, numeric: false), .reverseLines,
            .prefixLines(text: "- "), .suffixLines(text: ""), .urlEncode, .urlDecode, .htmlEscape, .htmlUnescape,
            .jsonFormat, .jsonMinify, .findReplace(find: "", replace: ""),
            .regexReplace(pattern: "", replacement: "", caseInsensitive: false), .wrap(before: "", after: ""),
            .commaToLines, .linesToComma, .shuffleLines, .numberLines, .slugify, .stripUrlTracking, .extractUrls, .extractEmails,
            .unixTimeToDate, .dateToUnixTime,
        ]
    }

    var title: String { textOpTitle(op: self) }
}

extension SelectionTarget {
    static var all: [SelectionTarget] { [.anything, .editableOnly, .readOnlyOnly, .containsUrl, .multipleLines, .looksLikeJson, .looksLikePath, .containsEmail] }

    var title: String {
        switch self {
        case .anything: return "Any selection"
        case .editableOnly: return "Only where text can be edited"
        case .readOnlyOnly: return "Only where text cannot be edited"
        case .containsUrl: return "Only when it has a link"
        case .multipleLines: return "Only several lines"
        case .looksLikeJson: return "Only when it looks like JSON"
        case .looksLikePath: return "Only when it is a file path"
        case .containsEmail: return "Only when it has an email address"
        }
    }
}

extension TranslateProvider {
    static var all: [TranslateProvider] { [.google, .deepL, .bing] }

    var title: String {
        switch self {
        case .google: return "Google Translate"
        case .deepL: return "DeepL"
        case .bing: return "Bing Translator"
        }
    }
}

extension SelectionActionKind {
    var summary: String {
        switch self {
        case .copy: return "Copy the selection"
        case .cut: return "Cut the selection"
        case .paste: return "Paste over the selection"
        case .pastePlain: return "Paste without formatting"
        case .copyPlain: return "Copy the selection without formatting"
        case .copyMarkdown: return "Copy the selection as Markdown"
        case .count: return "Count the words, characters and lines"
        case .share: return "Share the text"
        case .pressKeys(let keyCode, let modifiers): return "Press \(KeyNames.describe(keyCode: keyCode, modifiers: modifiers))"
        case .openInApp(let appID): return "Open the text in \(AppChoice.name(for: appID))"
        case .uuid: return "Insert a new UUID"
        case .transform(let ops, let copyOnly): return (copyOnly ? "Copy: " : "Change text: ") + ops.map(\.title).joined(separator: " → ")
        case .urlTemplate(let template): return "Open \(template)"
        case .openUrls: return "Open the links in the selection"
        case .dictionary: return "Look it up in the dictionary"
        case .spelling: return "Suggest spellings"
        case .translate(let target, let provider): return "Translate to \(target) with \(provider.title)"
        case .script(let language, _, let replace): return (language == .shell ? "Shell script" : "AppleScript") + (replace ? " that replaces the selection" : "")
        case .shortcut(let name, _): return "Shortcut “\(name)”"
        case .workflow: return "Run a workflow"
        case .intelligence(let task): return "Apple Intelligence: " + intelligenceTitle(task: task).lowercased()
        case .copyHtml: return "Copy the selection as HTML"
        case .revealPath: return "Show the selected path in Finder"
        case .openInTerminal: return "Open a terminal in the selected folder"
        case .sendToShelf: return "Put the text on the file shelf"
        }
    }
}

/// Scripts the person has approved. A script runs only if this exact text was approved, so an edited, imported or
/// restored script asks again.
final class ScriptApprovals: ObservableObject {
    @Published private(set) var approved: [ApprovedScript] = []
    private let core: KriyaCore

    init(core: KriyaCore) {
        self.core = core
        reload()
    }

    func reload() {
        approved = (try? core.approvedScripts()) ?? []
    }

    func isApproved(language: String, source: String) -> Bool {
        (try? core.isScriptApproved(fingerprint: scriptFingerprint(language: language, source: source))) ?? false
    }

    func revoke(_ fingerprint: String) {
        try? core.revokeScript(fingerprint: fingerprint)
        reload()
    }

    /// Asks before a script runs for the first time, showing exactly what it is. Returns whether it may run.
    @discardableResult
    func ensureApproved(language: String, source: String, title: String) -> Bool {
        if isApproved(language: language, source: source) { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Allow “\(title)” to run?"
        alert.informativeText = "This \(language) script can do anything you can do on this Mac. Read it first. Kriya will run it again without asking until it changes."
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 460, height: 190))
        text.string = source
        text.isEditable = false
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let scroll = NSScrollView(frame: text.frame)
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Approve and Run")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        try? core.approveScript(fingerprint: scriptFingerprint(language: language, source: source), label: title, now: SystemInfo.nowSeconds)
        reload()
        Log.info("Scripts", "A script was approved")
        return true
    }
}

/// The selection bar's actions and settings.
final class SelectionStore: ObservableObject {
    @Published private(set) var actions: [SelectionAction] = []
    @Published private(set) var config = defaultSelectionConfig()
    @Published var lastError: String?

    private let core: KriyaCore
    private let lock = NSLock()
    private var snapshot: (actions: [SelectionAction], config: SelectionConfig) = ([], defaultSelectionConfig())   // guarded by lock
    private var pendingSave: DispatchWorkItem?

    init(core: KriyaCore) {
        self.core = core
        reload()
    }

    func reload() {
        do {
            actions = try core.selectionActions()
            config = try core.selectionConfig()
        } catch {
            Log.error("Selection", "Could not load selection settings: \(error.userMessage)")
        }
        publish()
    }

    private func publish() {
        lock.lock()
        snapshot = (actions, config)
        lock.unlock()
    }

    /// Readable from any thread.
    var current: (actions: [SelectionAction], config: SelectionConfig) {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    func action(_ id: String) -> SelectionAction? { actions.first { $0.id == id } }

    // MARK: Settings

    func updateConfig(_ change: (inout SelectionConfig) -> Void) {
        change(&config)
        publish()
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.writeConfig() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func writeConfig() {
        pendingSave = nil
        do {
            try core.saveSelectionConfig(config: config)
            lastError = nil
        } catch {
            lastError = error.userMessage
            reload()
        }
    }

    func flushPendingSaves() {
        guard let work = pendingSave else { return }
        work.cancel()
        writeConfig()
    }

    // MARK: Actions

    func setActions(_ list: [SelectionAction]) { perform { try core.saveSelectionActions(list: list) } }
    func setEnabled(_ id: String, _ on: Bool) { setActions(actions.map { var a = $0; if a.id == id { a.enabled = on }; return a }) }
    func move(from source: IndexSet, to destination: Int) {
        var list = actions
        list.move(fromOffsets: source, toOffset: destination)
        setActions(list)
    }

    func upsert(_ action: SelectionAction) {
        var list = actions
        if let index = list.firstIndex(where: { $0.id == action.id }) { list[index] = action } else { list.append(action) }
        setActions(list)
    }

    func delete(_ id: String) { setActions(actions.filter { $0.id != id }) }

    /// Adds the ready-made actions (Markdown helpers, encodings, searches, share, create a note or reminder) that are not
    /// in the list yet. Returns how many were added.
    @discardableResult
    func addSuggested() -> Int {
        let have = Set(actions.map(\.id))
        let fresh = selectionSuggestedActions().filter { !have.contains($0.id) }
        guard !fresh.isEmpty else { return 0 }
        setActions(actions + fresh)
        return fresh.count
    }

    func restoreDefaults(everything: Bool) {
        pendingSave?.cancel()
        pendingSave = nil
        perform { try core.restoreDefaultSelectionSettings(everything: everything) }
    }

    // MARK: Sharing

    func exportActions(_ ids: [String], name: String, to url: URL) throws {
        let json = try core.exportSelectionActions(ids: ids, name: name)
        try json.write(to: url, atomically: true, encoding: .utf8)
    }

    @discardableResult
    func importActions(from url: URL) throws -> [SelectionAction] {
        let data = try Data(contentsOf: url)
        guard let json = String(data: data, encoding: .utf8) else { throw CoreError.Backup(message: "the file is not a Kriya action package") }
        let added = try core.importSelectionActions(json: json, now: SystemInfo.nowSeconds)
        reload()
        return added
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
}
