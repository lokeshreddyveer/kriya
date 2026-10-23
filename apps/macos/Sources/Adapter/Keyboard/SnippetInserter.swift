import AppKit
import SwiftUI

/// Types or pastes text into the app in front, then moves the cursor where a {cursor} marker said.
final class TextInjector {
    private let clipboard: ClipboardService
    private let store: KeyboardStore

    init(clipboard: ClipboardService, store: KeyboardStore) {
        self.clipboard = clipboard
        self.store = store
    }

    /// Short single-line text is typed key by key, which leaves the clipboard alone; anything else is pasted and the
    /// clipboard put back. Call from a background queue: it waits between key presses.
    func insert(_ text: String, cursorBack: Int) {
        let config = store.currentConfig
        if config.typeInsteadOfPaste, !text.contains("\n"), text.utf16.count <= 400 {
            type(text)
        } else {
            paste(text)
        }
        if cursorBack > 0 {
            usleep(30_000)
            for _ in 0..<cursorBack { key(123); usleep(1500) }   // left arrow
        }
    }

    func deleteBackwards(_ count: Int) {
        for _ in 0..<count { key(51); usleep(1500) }
    }

    private func key(_ code: CGKeyCode) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            event.setIntegerValueField(.eventSourceUserData, value: EventMonitor.syntheticMarker)
            event.post(tap: .cghidEventTap)
        }
    }

    private func type(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            // Do not cut a character made of two units in half.
            var end = min(index + 16, units.count)
            if end < units.count, UTF16.isLeadSurrogate(units[end - 1]) { end -= 1 }
            var chunk = Array(units[index..<end])
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                event.setIntegerValueField(.eventSourceUserData, value: EventMonitor.syntheticMarker)
                event.post(tap: .cghidEventTap)
            }
            index = end
            usleep(2000)
        }
    }

    private func paste(_ text: String) {
        let board = NSPasteboard.general
        let monitor = clipboard.monitor
        let saved = ClipboardPaster.snapshot(board)
        board.clearContents()
        board.setString(text, forType: .string)
        DispatchQueue.main.sync { monitor.ignore(changeCount: board.changeCount) }
        ClipboardPaster.sendPaste()
        usleep(250_000)
        ClipboardPaster.restore(saved, to: board)
        DispatchQueue.main.sync { monitor.ignore(changeCount: board.changeCount) }
    }
}

/// Fills in a snippet's placeholders, asking for any values it needs, and inserts the result.
final class SnippetInserter {
    private let store: KeyboardStore
    private let injector: TextInjector
    private let prompt = PromptPanel()
    private let queue = DispatchQueue(label: "app.kriya.insert", qos: .userInitiated)

    init(store: KeyboardStore, injector: TextInjector) {
        self.store = store
        self.injector = injector
    }

    /// The text a snippet becomes now, for a preview or a copy. Prompts show as empty.
    static func preview(_ body: String, prompts: [PromptValue] = []) -> TemplateOutput {
        var env = SnippetPreprocessor.Environment()
        env.snippet = lookup
        env.counter = { SnippetCounters.peek($0) }
        env.clipboard = NSPasteboard.general.string(forType: .string)
        return renderSnippet(body: SnippetPreprocessor.process(body, env), context: context(prompts: prompts))
    }

    /// Finds another snippet by its abbreviation or title, for `{snippet:…}`. Set by the app.
    static var lookup: (String) -> String? = { _ in nil }

    static func context(prompts: [PromptValue]) -> TemplateContext {
        TemplateContext(
            now: SystemInfo.nowSeconds, utcOffsetSeconds: Int32(TimeZone.current.secondsFromGMT()),
            clipboard: NSPasteboard.general.string(forType: .string), selection: nil,
            appName: NSWorkspace.shared.frontmostApplication?.localizedName, uuid: UUID().uuidString, prompts: prompts
        )
    }

    /// Inserts a snippet into the app in front. `deleting` characters before the cursor are removed first (the typed
    /// abbreviation), and `trailing` is typed after (the delimiter that ended it).
    func insert(_ snippet: ExpansionSnippet, deleting: Int = 0, trailing: String = "") {
        DispatchQueue.main.async { [self] in
            let first = Self.preview(snippet.body)
            if first.promptsNeeded.isEmpty {
                finish(snippet, answers: [], deleting: deleting, trailing: trailing)
            } else {
                // The prompt takes keyboard input without taking over the app, so the abbreviation is still where it was typed.
                prompt.ask(first.promptsNeeded, title: snippet.title) { [self] values in
                    guard let values else { return }
                    finish(snippet, answers: values, deleting: deleting, trailing: trailing)
                }
            }
        }
    }

    private func finish(_ snippet: ExpansionSnippet, answers: [PromptValue], deleting: Int, trailing: String) {
        let output = Self.preview(snippet.body, prompts: answers)
        let injector = injector
        queue.async { [store] in
            injector.deleteBackwards(deleting)
            // The delimiter goes at the very end, so the cursor has to step back over it as well.
            injector.insert(output.text + trailing, cursorBack: output.cursorBack > 0 ? Int(output.cursorBack) + trailing.count : 0)
            DispatchQueue.main.async { store.markUsed(snippet.id); SnippetCounters.advance(in: snippet.body) }
        }
    }
}

/// A small form that asks for the values a snippet needs. It does not take the app's focus away.
final class PromptPanel: NSObject, NSWindowDelegate {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private var panel: Panel?
    private var completion: (([PromptValue]?) -> Void)?

    func ask(_ names: [String], title: String, completion: @escaping ([PromptValue]?) -> Void) {
        self.completion = completion
        let model = PromptModel(names: names)
        let view = PromptView(title: title, model: model, onDone: { [weak self] values in self?.finish(values) })
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let panel = self.panel ?? Panel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: false)
        self.panel = panel
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let frame = screen?.visibleFrame ?? .zero
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.midY, width: size.width, height: size.height), display: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func finish(_ values: [PromptValue]?) {
        panel?.orderOut(nil)
        let done = completion
        completion = nil
        done?(values)
    }

    func windowDidResignKey(_ notification: Notification) {
        if completion != nil { finish(nil) }
    }
}

private final class PromptModel: ObservableObject {
    let names: [String]
    @Published var values: [String]
    init(names: [String]) {
        self.names = names
        values = Array(repeating: "", count: names.count)
    }
}

private struct PromptView: View {
    let title: String
    @ObservedObject var model: PromptModel
    let onDone: ([PromptValue]?) -> Void
    @FocusState private var focused: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.isEmpty ? "Fill in" : title).font(.headline)
            ForEach(Array(model.names.enumerated()), id: \.offset) { index, name in
                TextField(name, text: $model.values[index])
                    .textFieldStyle(.roundedBorder).focused($focused, equals: index)
                    .onSubmit { if index == model.names.count - 1 { submit() } else { focused = index + 1 } }
            }
            HStack {
                Spacer()
                Button("Cancel") { onDone(nil) }.keyboardShortcut(.cancelAction)
                Button("Insert") { submit() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16).frame(width: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator))
        .onAppear { focused = 0 }
    }

    private func submit() {
        onDone(zip(model.names, model.values).map { PromptValue(name: $0, value: $1) })
    }
}
