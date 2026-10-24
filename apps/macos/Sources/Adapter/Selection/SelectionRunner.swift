import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Selected text and where it is.
struct SelectionSnapshot {
    var text: String
    var editable: Bool
    var element: AXUIElement?
    /// Where the selection is on screen, with a top-left origin, if the app says.
    var bounds: CGRect?
    var appID: String?
    var pid: pid_t
}

enum SelectionReader {
    /// Reads the selection through Accessibility. Returns `nil` when nothing is selected, when the app does not say, and
    /// always for password fields.
    static func read() -> SelectionSnapshot? {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.15)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let raw = focused, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeBitCast(raw, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.15)

        if isSecure(element) { return nil }
        guard let text = string(element, kAXSelectedTextAttribute), !text.isEmpty else { return nil }

        var settable: DarwinBoolean = false
        let editable = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success && settable.boolValue
        return SelectionSnapshot(text: text, editable: editable, element: element, bounds: bounds(of: element), appID: app.bundleIdentifier, pid: app.processIdentifier)
    }

    static func isSecure(_ element: AXUIElement) -> Bool {
        let role = string(element, kAXRoleAttribute)
        let subrole = string(element, kAXSubroleAttribute)
        return role == "AXSecureTextField" || subrole == "AXSecureTextField" || IsSecureEventInputEnabled()
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &out) == .success else { return nil }
        return out as? String
    }

    private static func bounds(of element: AXUIElement) -> CGRect? {
        var range: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success, let rangeValue = range else { return nil }
        var rect: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &rect) == .success,
              let raw = rect, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var frame = CGRect.zero
        guard AXValueGetValue(unsafeBitCast(raw, to: AXValue.self), .cgRect, &frame), frame.width > 0 || frame.height > 0 else { return nil }
        return frame
    }

    /// For apps that do not report their selection: copy it, read it, and put the clipboard back. Slow and visible to the
    /// clipboard, so it runs only where the person allowed it, never in password fields, and never twice in a row.
    static func readByCopying(monitor: ClipboardMonitor) -> String? {
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled() else { return nil }
        let board = NSPasteboard.general
        let saved = ClipboardPaster.snapshot(board)
        let before = board.changeCount
        ClipboardPaster.sendCopy()
        var changed = false
        for _ in 0..<40 {
            Thread.sleep(forTimeInterval: 0.005)
            if board.changeCount != before { changed = true; break }
        }
        guard changed else { return nil }
        let concealed = !Set((board.types ?? []).map(\.rawValue)).isDisjoint(with: clipConcealedTypes())
        let text = concealed ? nil : board.string(forType: .string)
        let copied = board.changeCount
        ClipboardPaster.restore(saved, to: board)
        // Neither the temporary copy nor the put-back belongs in the clipboard history.
        DispatchQueue.main.async {
            monitor.ignore(changeCount: copied)
            monitor.ignore(changeCount: board.changeCount)
        }
        return text
    }
}

extension ClipboardPaster {
    static func sendCopy() {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: down) else { continue }
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: EventMonitor.syntheticMarker)
            event.post(tap: .cghidEventTap)
        }
    }

    static func sendCut() {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 7, keyDown: down) else { continue }
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: EventMonitor.syntheticMarker)
            event.post(tap: .cghidEventTap)
        }
    }

    /// Presses ⌘Z in the app in front: the way back from a replacement the bar made.
    static func sendUndo() {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 6, keyDown: down) else { continue }
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: EventMonitor.syntheticMarker)
            event.post(tap: .cghidEventTap)
        }
    }
}

/// Carries out a selection action.
final class SelectionActionRunner {
    private let store: SelectionStore
    private let clipboard: ClipboardService
    private let approvals: ScriptApprovals
    private let toast = Toast()
    private let lookUp = LookUpPresenter()
    /// Holds the small window the share menu hangs from, until the menu is done.
    private var shareAnchor: NSWindow?

    /// Runs a workflow by id with the selection as its input. Set when the automation engine exists.
    var runWorkflow: (_ id: String, _ selection: String) -> Void = { _, _ in }
    /// Hands the selection to Apple Intelligence. `replace` puts a result in place of the selection, and is nil when the
    /// text cannot be replaced. Set when Apple Intelligence is set up.
    var runIntelligence: (_ task: IntelligenceTask, _ text: String, _ pointer: CGPoint, _ replace: ((String) -> Bool)?) -> Void = { _, _, _, _ in }

    init(store: SelectionStore, clipboard: ClipboardService, approvals: ScriptApprovals) {
        self.store = store
        self.clipboard = clipboard
        self.approvals = approvals
    }

    func run(_ action: SelectionAction, on snapshot: SelectionSnapshot, pointer: CGPoint) {
        Log.info("Selection", "Action: \(String(describing: action.kind).prefix(20))")
        UsageLogStore.selection.record(action.title, detail: NSWorkspace.shared.frontmostApplication?.localizedName ?? "")
        switch action.kind {
        case .copy:
            copyToClipboard(snapshot.text)
            toast.show("Copied")
        case .cut:
            cut(snapshot)
        case .paste:
            ClipboardPaster.sendPaste()
        case .pastePlain:
            clipboard.paster.pasteCurrentAsPlainText()
        case .copyPlain:
            copyToClipboard(snapshot.text)
            toast.show("Copied as plain text")
        case .copyMarkdown:
            copyAsMarkdown(snapshot)
        case .count:
            toast.show(Self.counts(snapshot.text))
        case .share:
            share(snapshot.text, near: pointer)
        case .pressKeys(let keyCode, let modifiers):
            pressKeys(keyCode, modifiers: modifiers)
        case .openInApp(let appID):
            openInApp(appID, text: snapshot.text)
        case .uuid:
            let id = UUID().uuidString
            if snapshot.editable, replace(snapshot, with: id) {
                toast.show("Inserted a new UUID")
            } else {
                copyToClipboard(id)
                toast.show("New UUID copied")
            }
        case .transform(let ops, let copyOnly):
            transform(ops, copyOnly: copyOnly, snapshot)
        case .urlTemplate(let template):
            open(template: template, text: snapshot.text)
        case .openUrls:
            openLinks(in: snapshot.text)
        case .dictionary:
            lookUp.show(snapshot.text, near: pointer)
        case .spelling:
            suggestSpelling(snapshot, at: pointer)
        case .translate(let target, let provider):
            if let url = try? selectionTranslateUrl(provider: provider, target: target, text: snapshot.text) { NSWorkspace.shared.open(URL(string: url)!) }
            else { toast.show("That language code is not valid.", isError: true) }
        case .script(let language, let source, let replace):
            runScript(action, language, source, replace, snapshot)
        case .shortcut(let name, let replace):
            runShortcut(name, replace, snapshot)
        case .workflow(let id):
            runWorkflow(id, snapshot.text)
        case .copyHtml:
            let html = textToHtml(text: snapshot.text)
            let board = NSPasteboard.general
            board.clearContents()
            board.setString(html, forType: .html)
            board.setString(html, forType: .string)
            toast.show("Copied as HTML")
        case .revealPath:
            if let url = Self.fileURL(from: snapshot.text), FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            else { toast.show("That path does not exist.", isError: true) }
        case .openInTerminal:
            openTerminal(at: snapshot.text)
        case .sendToShelf:
            sendToShelf(snapshot.text)
            toast.show("Put on the shelf")
        case .intelligence(let task):
            // The text is not logged, and not sent anywhere but the model on this Mac. An app can report only part of a
            // selection when the bar first appears, so it is read again now, and the fuller reading is used.
            let (_, config) = store.current
            let canCopy = selectionBehavior(config: config, appId: snapshot.appID).allowCopyFallback && !snapshot.editable
            let monitor = clipboard.monitor
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                var text = snapshot.text
                text = Self.fuller(text, SelectionReader.read()?.text)
                if canCopy { text = Self.fuller(text, SelectionReader.readByCopying(monitor: monitor)) }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.runIntelligence(task, text, pointer, snapshot.editable ? { [weak self] result in self?.replace(snapshot, with: result) ?? false } : nil)
                }
            }
        }
    }

    /// `first`, unless `later` is a longer reading of the same selection (it contains what was read before), in which
    /// case that. Something unrelated, such as a different selection made since, is never taken.
    static func fuller(_ first: String, _ later: String?) -> String {
        guard let later, later.count > first.count else { return first }
        let a = first.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty, later.contains(a) else { return first }
        return later
    }

    // MARK: Pieces

    /// "12 words · 68 characters · 3 lines", and for a longer text how long it takes to read.
    static func counts(_ text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).count
        let lines = text.isEmpty ? 0 : text.components(separatedBy: .newlines).count
        func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        var parts = [plural(words, "word"), plural(text.count, "character"), plural(lines, "line")]
        if words >= 110 { parts.append("\(max(1, Int((Double(words) / 220).rounded()))) min read") }
        return parts.joined(separator: " · ")
    }

    /// A path typed in text, as a file address: `~` is the home folder, and a `file://` address is read as one.
    static func fileURL(from text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("file://") { return URL(string: t) }
        guard t.hasPrefix("/") || t.hasPrefix("~") else { return nil }
        return URL(fileURLWithPath: (t as NSString).expandingTildeInPath)
    }

    /// Opens a terminal in the folder (or the folder holding the file) the text names.
    private func openTerminal(at text: String) {
        guard let url = Self.fileURL(from: text), FileManager.default.fileExists(atPath: url.path) else { toast.show("That path does not exist.", isError: true); return }
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        let folder = isFolder ? url : url.deletingLastPathComponent()
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Puts text on the file shelf. Set by the app.
    var sendToShelf: (String) -> Void = { _ in }

    /// Opens the system share menu next to the pointer.
    private func share(_ text: String, near pointer: CGPoint) {
        let height = NSScreen.screens.first?.frame.height ?? 0
        let anchor = NSWindow(contentRect: NSRect(x: pointer.x, y: height - pointer.y, width: 1, height: 1), styleMask: .borderless, backing: .buffered, defer: false)
        anchor.isOpaque = false
        anchor.backgroundColor = .clear
        anchor.hasShadow = false
        anchor.level = .popUpMenu
        anchor.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        anchor.contentView = view
        anchor.orderFrontRegardless()
        shareAnchor = anchor
        NSSharingServicePicker(items: [text]).show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            self?.shareAnchor?.orderOut(nil)
            self?.shareAnchor = nil
        }
    }

    /// Presses a key combination in the app that has focus, such as Command-B.
    private func pressKeys(_ keyCode: UInt16, modifiers: UInt64) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { continue }
            event.flags = KeyModifiers.flags(from: modifiers)
            event.setIntegerValueField(.eventSourceUserData, value: EventMonitor.syntheticMarker)
            event.post(tap: .cghidEventTap)
        }
    }

    /// Opens the text in another app, as a text file.
    private func openInApp(_ appID: String, text: String) {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appID) else {
            toast.show("That app is not installed.", isError: true)
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Selection \(Int(Date().timeIntervalSince1970)).txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            toast.show("Could not save the text to open it.", isError: true)
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Copies the selection with its formatting turned into Markdown. The app is asked to copy, its rich text is read
    /// from the clipboard, and the Markdown replaces it. Falls back to the plain text when the app gives no formatting.
    private func copyAsMarkdown(_ snapshot: SelectionSnapshot) {
        guard !IsSecureEventInputEnabled() else {
            toast.show("Not while a password is being typed.", isError: true)
            return
        }
        let board = NSPasteboard.general
        let before = board.changeCount
        let monitor = clipboard.monitor
        ClipboardPaster.sendCopy()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var changed = false
            for _ in 0..<60 {
                Thread.sleep(forTimeInterval: 0.005)
                if board.changeCount != before { changed = true; break }
            }
            var html: String?
            if changed {
                html = board.string(forType: .html)
                if html == nil, let rtf = board.data(forType: .rtf),
                   let attributed = try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil),
                   let data = try? attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.html]) {
                    html = String(data: data, encoding: .utf8)
                }
            }
            let markdown = html.map { htmlToMarkdown(html: $0) }.flatMap { $0.isEmpty ? nil : $0 } ?? snapshot.text
            let copied = board.changeCount
            DispatchQueue.main.async {
                guard let self else { return }
                // Neither the app's own copy nor the Markdown belongs in the clipboard history.
                monitor.ignore(changeCount: copied)
                self.copyToClipboard(markdown)
                monitor.ignore(changeCount: board.changeCount)
                self.toast.show("Copied as Markdown")
            }
        }
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func cut(_ snapshot: SelectionSnapshot) {
        guard snapshot.editable else {
            copyToClipboard(snapshot.text)
            toast.show("Copied. This text cannot be cut.")
            return
        }
        copyToClipboard(snapshot.text)
        if !replace(snapshot, with: "") { ClipboardPaster.sendCut() }
        toast.show("Cut")
    }

    private func transform(_ ops: [TextOp], copyOnly: Bool, _ snapshot: SelectionSnapshot) {
        do {
            let result = try textApplyAll(ops: ops, text: snapshot.text)
            if copyOnly || !snapshot.editable {
                copyToClipboard(result)
                toast.show("Result copied")
            } else if !replace(snapshot, with: result) {
                toast.show("This app would not take the change. Result copied instead.", isError: true)
                copyToClipboard(result)
            } else if result != snapshot.text {
                // What changed, with a way back: the app's own Undo (⌘Z), or the original on the clipboard.
                ReplacementPeek.shared.show(original: snapshot.text, result: result, title: ops.first.map { textOpTitle(op: $0) } ?? "Replaced") { [weak self] in
                    ClipboardPaster.sendUndo()
                    self?.toast.show("Undone with ⌘Z. The original is also on the clipboard.")
                    self?.copyToClipboard(snapshot.text)
                }
            }
        } catch {
            toast.show(error.userMessage, isError: true)
        }
    }

    /// Puts text in place of the selection: straight into the field when the app allows it, otherwise by pasting.
    @discardableResult
    private func replace(_ snapshot: SelectionSnapshot, with text: String) -> Bool {
        if let element = snapshot.element,
           AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success {
            // Some apps say yes and do nothing; look again.
            var out: CFTypeRef?
            let now = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &out) == .success ? (out as? String) : nil
            if text.isEmpty || now == text || now == nil { return true }
        }
        guard AXIsProcessTrusted() else { return false }
        let board = NSPasteboard.general
        let saved = ClipboardPaster.snapshot(board)
        board.clearContents()
        board.setString(text, forType: .string)
        clipboard.monitor.ignore(changeCount: board.changeCount)
        ClipboardPaster.sendPaste()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [clipboard] in
            ClipboardPaster.restore(saved, to: board)
            clipboard.monitor.ignore(changeCount: board.changeCount)
        }
        return true
    }

    private func open(template: String, text: String) {
        guard let address = try? textUrlTemplate(template: template, text: text), let url = URL(string: address) else {
            toast.show("That address is not valid.", isError: true)
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func openLinks(in text: String) {
        let urls = textFindUrls(text: text).compactMap(URL.init(string:))
        guard !urls.isEmpty else { toast.show("No link found.", isError: true); return }
        if urls.count > 3 {
            let alert = NSAlert()
            alert.messageText = "Open \(urls.count) links?"
            alert.addButton(withTitle: "Open All")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        urls.forEach { NSWorkspace.shared.open($0) }
    }

    private func suggestSpelling(_ snapshot: SelectionSnapshot, at pointer: CGPoint) {
        let checker = NSSpellChecker.shared
        let text = snapshot.text as NSString
        let range = checker.checkSpelling(of: snapshot.text, startingAt: 0)
        guard range.location != NSNotFound else {
            toast.show("No spelling problems")
            return
        }
        let guesses = checker.guesses(forWordRange: range, in: snapshot.text, language: nil, inSpellDocumentWithTag: 0) ?? []
        let menu = NSMenu()
        if guesses.isEmpty {
            menu.addItem(withTitle: "No suggestions for “\(text.substring(with: range))”", action: nil, keyEquivalent: "")
        }
        let handler = SpellingChoice { [weak self] guess in
            guard let self else { return }
            let fixed = text.replacingCharacters(in: range, with: guess)
            if snapshot.editable { _ = replace(snapshot, with: fixed) } else { copyToClipboard(fixed); toast.show("Corrected text copied") }
        }
        for guess in guesses.prefix(8) {
            let item = NSMenuItem(title: guess, action: #selector(SpellingChoice.choose(_:)), keyEquivalent: "")
            item.target = handler
            menu.addItem(item)
        }
        objc_setAssociatedObject(menu, &SpellingChoice.key, handler, .OBJC_ASSOCIATION_RETAIN)
        let location = NSPoint(x: pointer.x, y: (NSScreen.screens.first?.frame.height ?? 0) - pointer.y)
        menu.popUp(positioning: nil, at: location, in: nil)
    }

    private func runScript(_ action: SelectionAction, _ language: FinderScript, _ source: String, _ replaceOutput: Bool, _ snapshot: SelectionSnapshot) {
        let languageName = language == .shell ? "shell" : "AppleScript"
        guard approvals.ensureApproved(language: languageName, source: source, title: action.title) else { return }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
                let environment = ["KRIYA_SELECTION": snapshot.text, "KRIYA_APP": snapshot.appID ?? ""]
                let output: String
                switch language {
                case .shell:
                    output = try ToolRunner.run("/bin/zsh", ["-c", source, "kriya", snapshot.text], environment: environment, timeout: 60)
                case .appleScript:
                    let script = source.contains("on run") ? source : "on run argv\n\(source)\nend run"
                    output = try ToolRunner.run("/usr/bin/osascript", ["-e", script, snapshot.text], environment: environment, timeout: 60)
                }
                DispatchQueue.main.async { [self] in
                    if replaceOutput, snapshot.editable, !output.isEmpty { _ = replace(snapshot, with: output); toast.show("Done") }
                    else if replaceOutput, !output.isEmpty { copyToClipboard(output); toast.show("Result copied") }
                    else { toast.show(output.isEmpty ? "Script finished" : String(output.prefix(120))) }
                }
            } catch {
                toast.show(error.localizedDescription, isError: true)
            }
        }
    }

    private func runShortcut(_ name: String, _ replaceOutput: Bool, _ snapshot: SelectionSnapshot) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kriya-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let input = folder.appendingPathComponent("selection.txt")
                let output = folder.appendingPathComponent("result.txt")
                try snapshot.text.write(to: input, atomically: true, encoding: .utf8)
                var args = ["run", name, "--input-path", input.path]
                if replaceOutput { args += ["--output-path", output.path] }
                try ToolRunner.run("/usr/bin/shortcuts", args, timeout: 120)
                let result = replaceOutput ? (try? String(contentsOf: output, encoding: .utf8)) : nil
                DispatchQueue.main.async { [self] in
                    if let result, !result.isEmpty {
                        if snapshot.editable { _ = replace(snapshot, with: result) } else { copyToClipboard(result) }
                        toast.show("Done")
                    } else {
                        toast.show("Shortcut finished")
                    }
                }
            } catch {
                toast.show(error.localizedDescription, isError: true)
            }
        }
    }
}

private final class SpellingChoice: NSObject {
    static var key: UInt8 = 0
    private let handler: (String) -> Void
    init(handler: @escaping (String) -> Void) { self.handler = handler }
    @objc func choose(_ sender: NSMenuItem) { handler(sender.title) }
}

/// Shows the system's own dictionary popover next to the selection.
final class LookUpPresenter {
    private var panel: NSPanel?

    func show(_ text: String, near pointer: CGPoint) {
        let height = NSScreen.screens.first?.frame.height ?? 0
        let point = NSPoint(x: pointer.x, y: height - pointer.y)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 4, height: 4))
        let panel = self.panel ?? NSPanel(contentRect: NSRect(x: point.x, y: point.y, width: 4, height: 4), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.panel = panel
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.contentView = view
        panel.setFrame(NSRect(x: point.x, y: point.y, width: 4, height: 4), display: false)
        panel.orderFrontRegardless()
        view.showDefinition(for: NSAttributedString(string: text), at: NSPoint(x: 0, y: 0))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak panel] in panel?.alphaValue = 0.01 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak panel] in panel?.orderOut(nil) }
    }
}
