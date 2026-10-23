import AppKit
import SwiftUI

/// Apple Intelligence in Kriya: whether it is ready, where it is used, and a place to try it.
struct IntelligencePane: View {
    @EnvironmentObject private var intelligence: AppleIntelligence

    @State private var task: AITaskChoice = .summarize
    @State private var instruction = ""
    @State private var sample = ""
    @State private var result: String?
    @State private var problem: String?
    @State private var working = false
    @State private var running: Task<Void, Never>?

    private var settings: IntelligenceSettings { intelligence.settings }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: intelligence.isAvailable ? "sparkles" : "exclamationmark.triangle")
                        .font(.title2).foregroundStyle(intelligence.isAvailable ? Theme.accent : Theme.warn)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(intelligence.availability.title).font(.headline)
                        Text(intelligence.availability.explanation).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !intelligence.isAvailable {
                        Button("Open System Settings") { openSystemSettings() }.controlSize(.small)
                    }
                }
                .animation(.smooth(duration: 0.2), value: intelligence.availability)
            } header: { Text("Status") } footer: {
                Text("Kriya uses only the model that runs on this Mac. It never uses a cloud model, and sends nothing to Apple or anyone else. What you select or copy is not logged, saved or kept after the result is shown. Because it works offline it cannot look things up: it does not know current facts, films, or other specifics, and may refuse or guess. Use it to rewrite, summarize or explain the text you give it, and use a web search (the “Search with” rows in the launcher) to find facts.")
            }

            Section {
                Toggle("Selection bar actions (Summarize, Fix grammar, Explain…)", isOn: bind(\.inSelectionBar))
                Toggle("Launcher: ask a question, and work on the clipboard text", isOn: bind(\.inLauncher))
                Toggle("Clipboard history items: Summarize, Explain, Fix grammar", isOn: bind(\.onClipboardItems))
            } header: { Text("Where to use it") } footer: {
                Text("In the selection bar the actions sit under one “Apple Intelligence” button, and are left out when it is not available. Pick which ones show in Selection Bar. In the launcher, type “ask” and a question. Items labelled sensitive in clipboard history, and text that looks like a password or key, are never sent to the model.")
            }

            Section {
                Toggle("Allow web research", isOn: Binding(get: { settings.webResearchOn == true }, set: { v in intelligence.update { $0.webResearchOn = v ? true : nil } }))
            } header: { Text("Web research") } footer: {
                Text("Off by default. The on-device model cannot look things up, so this lets it read the opening of Wikipedia articles first. In the launcher type “research” and a question, for example “research who directed Baahubali”. Only the words of your question are sent, to Wikipedia, in the language of your question (Telugu script goes to the Telugu Wikipedia) and in English. The model then answers only from what was found, cites it as [1], [2], and the sources are listed under the answer. If nothing matches, it says so instead of guessing. Nothing is sent while Local-only mode is on.")
            }

            Section {
                TextField("Language of the result", text: Binding(get: { settings.outputLanguage }, set: { v in intelligence.update { $0.outputLanguage = v } }), prompt: Text("Same as the text"))
            } header: { Text("Language") } footer: {
                Text("Leave empty to get a result in the language of the text. Type a language, such as French, to always get that one. The model supports a limited set of languages.")
            }

            Section {
                Picker("Task", selection: $task) { ForEach(AITaskChoice.allCases) { Text($0.title).tag($0) } }
                if task == .custom { TextField("What should it do?", text: $instruction) }
                TextEditor(text: $sample).font(.system(size: 13)).frame(height: 90)
                    .overlay(alignment: .topLeading) { if sample.isEmpty { Text("Type or paste some text to try it on").foregroundStyle(.tertiary).padding(6).allowsHitTesting(false) } }
                HStack {
                    Button(working ? "Stop" : "Try It") { working ? stop() : run() }
                        .disabled(!intelligence.isAvailable || (!working && sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                    if working { ProgressView().controlSize(.small) }
                    Spacer()
                }
                if let result {
                    Text(result).textSelection(.enabled).font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous)).transition(.opacity)
                }
                if let problem { Label(problem, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Theme.warn).transition(.opacity) }
            } header: { Text("Try it") } footer: {
                Text("Text longer than about \(AppleIntelligence.maxInputCharacters) characters is cut down to fit the model. AI can make mistakes: check what it writes.")
            }
        }
        .formStyle(.grouped)
        .animation(.smooth(duration: 0.2), value: result)
        .animation(.smooth(duration: 0.2), value: problem)
        .onAppear { intelligence.refresh() }
    }

    private func bind(_ path: WritableKeyPath<IntelligenceSettings, Bool>) -> Binding<Bool> {
        Binding(get: { intelligence.settings[keyPath: path] }, set: { value in intelligence.update { $0[keyPath: path] = value } })
    }

    private func run() {
        result = nil
        problem = nil
        working = true
        let chosen = task.task(instruction: instruction)
        let text = sample
        running = Task {
            do {
                let output = try await intelligence.run(chosen, on: text)
                if Task.isCancelled { return }
                await MainActor.run { result = output.text + (output.truncated ? "\n\n(The text was long, so only the first part was used.)" : ""); working = false }
            } catch {
                if Task.isCancelled { return }
                let reason = IntelligenceError.classify(error)
                await MainActor.run { problem = reason.errorDescription; working = false }
            }
        }
    }

    private func stop() {
        running?.cancel()
        working = false
    }

    private func openSystemSettings() {
        // The Apple Intelligence & Siri page, or System Settings itself when macOS does not know that address.
        for address in ["x-apple.systempreferences:com.apple.Siri-Settings.extension", "x-apple.systempreferences:"] {
            if let url = URL(string: address), NSWorkspace.shared.open(url) { return }
        }
    }
}
