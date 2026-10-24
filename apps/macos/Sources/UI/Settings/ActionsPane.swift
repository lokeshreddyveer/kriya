import SwiftUI

extension Action {
    /// A short plain-words description for lists.
    var summary: String {
        switch self {
        case .noop: return "Does nothing"
        case .keyPress(let keyCode, let modifiers): return "Press \(KeyNames.describe(keyCode: UInt16(keyCode), modifiers: modifiers))"
        case .openApplication(let target): return "Open \(target)"
        case .openUrl(let url): return "Open \(url)"
        case .runShell(let script): return "Run: \(script.split(separator: "\n").first.map(String.init) ?? script)"
        case .runScript(_, let source): return "Run script: \(source.split(separator: "\n").first.map(String.init) ?? source)"
        case .runShortcut(let name): return "Run shortcut “\(name)”"
        case .builtin(let command): return WindowCommands.title(for: command).map { "Window: \($0)" } ?? "Built-in: \(command)"
        case .click(_, _, let button, let count, let inWindow):
            return "\(button == 1 ? "Right-click" : count == 2 ? "Double-click" : count == 3 ? "Triple-click" : "Click")\(inWindow ? " in the front window" : " on the screen")"
        case .sequence(let steps, _): return "\(steps.count) steps in order"
        }
    }

    var symbol: String {
        switch self {
        case .noop: return "nosign"
        case .keyPress: return "keyboard"
        case .openApplication: return "app"
        case .openUrl: return "link"
        case .runShell: return "terminal"
        case .runScript: return "applescript"
        case .runShortcut: return "square.2.layers.3d"
        case .click: return "cursorarrow.click"
        case .builtin: return "wand.and.stars"
        case .sequence: return "list.number"
        }
    }
}

struct ActionsPane: View {
    @EnvironmentObject private var library: ActionLibrary
    @Environment(\.executor) private var executor

    @State private var showingEditor = false
    @State private var recording = false
    @State private var results: [String: ActionOutcome] = [:]
    @State private var errorMessage: String?
    @State private var added: Int?
    @State private var query = ""
    @State private var pendingDelete: NamedAction?

    var body: some View {
        let shown = ActionInsight.search(library.actions, text: query, describe: { $0.summary })
        let duplicates = ActionInsight.duplicates(library.actions)
        Form {
            if !duplicates.isEmpty {
                Section {
                    ForEach(Array(duplicates.enumerated()), id: \.offset) { _, group in
                        Label(group.map { "“\($0.name)”" }.joined(separator: " and ") + " do the same thing.", systemImage: "square.on.square").font(.callout)
                    }
                } header: { Text("Duplicates") }
            }
            if library.actions.count > 5 {
                Section { TextField("Search actions", text: $query) }
            }
            if let added {
                Section {
                    Text(added == 0 ? "The common actions are already in your list." : "Added \(added) common action\(added == 1 ? "" : "s").")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .transition(.opacity)
            }
            Section {
                if library.actions.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "bolt").font(.largeTitle).foregroundStyle(.tertiary)
                        Text("No saved actions").font(.headline)
                        Text("An action can open an app or address, run a script or shortcut, or press keys. Later, mouse buttons, gestures and shortcuts pick from this list.")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                }
                ForEach(shown) { saved in
                    ActionRow(saved: saved, outcome: results[saved.id], onRun: { run(saved) }, onDelete: { pendingDelete = saved })
                }
            } header: {
                HStack {
                    Text("Saved actions")
                    Spacer()
                    Button { added = library.addSuggested() } label: { Label("Add Common Actions", systemImage: "wand.and.stars") }
                        .controlSize(.small)
                        .help("Back, Forward, Mission Control, desktops, tabs and a few window and pointer actions")
                    Button { recording = true } label: { Label("Record Keys", systemImage: "record.circle") }
                        .controlSize(.small)
                        .help("Press keys once and save them as an action that presses them again")
                    Button { showingEditor = true } label: { Label("New Action", systemImage: "plus") }
                        .controlSize(.small)
                }
            }
            if let errorMessage {
                Section { Text(errorMessage).font(.callout).foregroundStyle(Theme.danger) }
            }
        }
        .formStyle(.grouped)
        .animation(.smooth(duration: 0.3), value: library.actions)
        .animation(.smooth(duration: 0.25), value: errorMessage)
        .animation(.smooth(duration: 0.25), value: added)
        .confirmationDialog("Delete “\(pendingDelete?.name ?? "")”?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let saved = pendingDelete { delete(saved) }; pendingDelete = nil }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { Text("A mouse button, shortcut or rule that uses it will stop doing anything.") }
        .sheet(isPresented: $showingEditor) { ActionEditor() }
        .sheet(isPresented: $recording) { KeyRecorderSheet(onClose: { recording = false }) }
    }

    private func run(_ saved: NamedAction) {
        guard let executor else { return }
        results[saved.id] = nil
        UsageLogStore.actions.record(saved.name)
        Task {
            let outcome = await executor.perform(saved.action)
            await MainActor.run { withAnimation(.smooth) { results[saved.id] = outcome } }
        }
    }

    private func delete(_ saved: NamedAction) {
        do {
            try library.delete(saved)
            errorMessage = nil
        } catch {
            errorMessage = error.userMessage
        }
    }
}

private struct ActionRow: View {
    let saved: NamedAction
    let outcome: ActionOutcome?
    let onRun: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: saved.action.symbol).font(.title3).frame(width: 28).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(saved.name).font(.headline)
                Text(saved.action.summary).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                if let last = UsageLogStore.actions.log.lastUsed(saved.name) {
                    Text("Last run here \(last.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.tertiary)
                }
                let risk = ActionInsight.risk(of: saved.action)
                if risk >= .medium { StateBadge(text: risk.title, color: risk == .high ? Theme.danger : Theme.warn).help(ActionInsight.reason(for: saved.action)) }
                if let outcome {
                    switch outcome {
                    case .success: StateBadge(text: "Done", color: Theme.ok)
                    case .failure(let message): StateBadge(text: message, color: Theme.danger)
                    }
                }
            }
            Spacer()
            Button("Run", action: onRun).controlSize(.small)
            Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                .accessibilityLabel("Delete \(saved.name)")
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 3)
    }
}

/// Creates a saved action. Used from the Actions pane and from every place that picks an action.
struct ActionEditor: View {
    var onSaved: (String) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.executor) private var executor
    @EnvironmentObject private var library: ActionLibrary

    private enum Kind: String, CaseIterable, Identifiable {
        case keys = "Press a keyboard shortcut"
        case window = "Do a window action"
        case app = "Open an app"
        case url = "Open a web address"
        case shell = "Run a shell command"
        case appleScript = "Run an AppleScript"
        case shortcut = "Run a Shortcut"
        var id: String { rawValue }

        var prompt: String {
            switch self {
            case .url: return "https://example.com"
            case .app: return "/Applications/Notes.app or com.apple.Notes"
            case .shell: return "open -a Calculator"
            case .appleScript: return "tell application \"Finder\" to activate"
            case .shortcut: return "Name of the shortcut"
            case .keys, .window: return ""
            }
        }

        var isMultiline: Bool { self == .shell || self == .appleScript }
        var usesText: Bool { self != .keys && self != .window }
    }

    @State private var name = ""
    @State private var kind: Kind = .keys
    @State private var value = ""
    @State private var recorded: RecordedShortcut?
    @State private var windowCommand = WindowCommands.all[0].command
    @State private var message: String?
    @State private var testing = false

    private var action: Action {
        switch kind {
        case .keys: return .keyPress(keyCode: recorded?.keyCode ?? 0, modifiers: recorded?.modifiers ?? 0)
        case .window: return .builtin(command: windowCommand)
        case .url: return .openUrl(url: value)
        case .app: return .openApplication(target: value)
        case .shell: return .runShell(script: value)
        case .appleScript: return .runScript(language: .appleScript, source: value)
        case .shortcut: return .runShortcut(name: value)
        }
    }

    private var suggestedName: String {
        switch kind {
        case .keys: return recorded.map { "Press \($0.title)" } ?? ""
        case .window: return WindowCommands.title(for: windowCommand).map { "Window: \($0)" } ?? ""
        default: return ""
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Action").font(.title3.bold())
            Form {
                TextField("Name", text: $name, prompt: Text(suggestedName.isEmpty ? "Name" : suggestedName))
                Picker("Does this", selection: $kind) {
                    ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                switch kind {
                case .keys:
                    LabeledContent("Shortcut") { ShortcutRecorder(shortcut: $recorded).frame(width: 200, height: 28) }
                case .window:
                    Picker("Window action", selection: $windowCommand) {
                        ForEach(WindowCommands.all, id: \.command) { Text($0.title).tag($0.command) }
                    }
                    Text("The action does nothing while Window Management is turned off.")
                        .font(.caption).foregroundStyle(.secondary)
                default:
                    if kind.isMultiline {
                        TextEditor(text: $value)
                            .font(.system(.body, design: .monospaced))
                            .frame(height: 110)
                    } else {
                        HStack {
                            TextField("Value", text: $value, prompt: Text(kind.prompt))
                            if kind == .app {
                                Button("Choose…") { if let id = AppChoice.choose() { value = id } }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            if let message {
                Text(message).font(.callout).foregroundStyle(Theme.danger).transition(.opacity)
            }
            HStack {
                Button("Test") { test() }.disabled(testing || executor == nil)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500)
        .animation(.smooth(duration: 0.25), value: message)
        .animation(.smooth(duration: 0.25), value: kind)
    }

    private func save() {
        if kind == .keys, recorded == nil {
            message = "Click the box and press the keys first."
            return
        }
        let finalName = (name.trimmingCharacters(in: .whitespaces).isEmpty ? suggestedName : name).trimmingCharacters(in: .whitespaces)
        guard !finalName.isEmpty else { message = "Give the action a name."; return }
        let id = UUID().uuidString
        do {
            try library.save(name: finalName, action: action, id: id)
            onSaved(id)
            dismiss()
        } catch {
            message = error.userMessage
        }
    }

    private func test() {
        if kind == .keys, recorded == nil {
            message = "Click the box and press the keys first."
            return
        }
        if let problem = actionProblem(action: action) {
            message = problem.prefix(1).uppercased() + problem.dropFirst()
            return
        }
        guard let executor else { return }
        testing = true
        message = nil
        Task {
            let outcome = await executor.perform(action)
            await MainActor.run {
                testing = false
                if case .failure(let text) = outcome { message = text }
            }
        }
    }
}

/// Records some key presses and saves them as one action. The keys are listened to only while this window is open.
private struct KeyRecorderSheet: View {
    @EnvironmentObject private var library: ActionLibrary
    @EnvironmentObject private var events: EventMonitor
    @StateObject private var holder = RecorderHolder()
    let onClose: () -> Void
    @State private var name = ""
    @State private var problem: String?

    var body: some View {
        let recorder = holder.make(events)
        VStack(spacing: 0) {
            RecorderBody(recorder: recorder, name: $name, problem: $problem, onSave: { save(recorder) }, onClose: { recorder.stop(); onClose() })
        }
        .frame(width: 480, height: 340)
        .onAppear { recorder.start() }
        .onDisappear { recorder.stop() }
    }

    private func save(_ recorder: KeystrokeRecorder) {
        recorder.stop()
        guard let action = KeystrokeRecording.action(keys: recorder.keys, clicks: recorder.clicks) else { problem = "Nothing was recorded."; return }
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { problem = "Give the action a name."; recorder.start(); return }
        do {
            try library.save(name: clean, action: action)
            onClose()
        } catch {
            problem = error.userMessage
        }
    }
}

private final class RecorderHolder: ObservableObject {
    private var recorder: KeystrokeRecorder?
    func make(_ events: EventMonitor) -> KeystrokeRecorder {
        if let recorder { return recorder }
        let made = KeystrokeRecorder(events: events)
        made.includeClicks = true
        recorder = made
        return made
    }
}

private struct RecorderBody: View {
    @ObservedObject var recorder: KeystrokeRecorder
    @Binding var name: String
    @Binding var problem: String?
    let onSave: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Circle().fill(recorder.isRecording ? Color.red : Color.secondary).frame(width: 10, height: 10)
                        .opacity(recorder.isRecording ? 1 : 0.5)
                    Text(recorder.isRecording ? "Recording: press keys and click now" : "Stopped").font(.headline)
                }
                Text(KeystrokeRecording.summary(recorder.keys, clicks: recorder.clicks)).font(.system(.body, design: .rounded)).foregroundStyle(recorder.keys.isEmpty && recorder.clicks.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading).padding(10)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                TextField("Name for the action", text: $name)
                if let problem { Text(problem).font(.callout).foregroundStyle(Theme.danger) }
                Text("Keys and clicks are kept in order, with their pauses. A click is saved as where it landed in the front window, so it still hits the same button after the window has moved. What you type is not looked at or saved, and nothing is recorded once this window closes. Up to \(KeystrokeRecording.maxSteps) steps.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            Spacer(minLength: 0)
            Divider()
            HStack {
                Button(recorder.isRecording ? "Stop" : "Record Again") { recorder.isRecording ? recorder.stop() : { recorder.clear(); recorder.start() }() }
                Button("Clear") { recorder.clear() }.disabled(recorder.keys.isEmpty && recorder.clicks.isEmpty)
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button("Save Action", action: onSave).buttonStyle(.borderedProminent).disabled(recorder.keys.isEmpty && recorder.clicks.isEmpty)
            }
            .padding(12)
        }
    }
}
