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
        case .builtin: return "wand.and.stars"
        case .sequence: return "list.number"
        }
    }
}

struct ActionsPane: View {
    @EnvironmentObject private var library: ActionLibrary
    @Environment(\.executor) private var executor

    @State private var showingEditor = false
    @State private var results: [String: ActionOutcome] = [:]
    @State private var errorMessage: String?
    @State private var added: Int?

    var body: some View {
        Form {
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
                ForEach(library.actions) { saved in
                    ActionRow(saved: saved, outcome: results[saved.id], onRun: { run(saved) }, onDelete: { delete(saved) })
                }
            } header: {
                HStack {
                    Text("Saved actions")
                    Spacer()
                    Button { added = library.addSuggested() } label: { Label("Add Common Actions", systemImage: "wand.and.stars") }
                        .controlSize(.small)
                        .help("Back, Forward, Mission Control, desktops, tabs and a few window and pointer actions")
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
        .sheet(isPresented: $showingEditor) { ActionEditor() }
    }

    private func run(_ saved: NamedAction) {
        guard let executor else { return }
        results[saved.id] = nil
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
                    Text("Window actions start working when Window Management arrives.")
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
        let finalName = name.trimmingCharacters(in: .whitespaces).isEmpty ? suggestedName : name
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
