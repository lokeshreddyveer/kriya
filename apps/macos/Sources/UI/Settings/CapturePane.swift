import AppKit
import SwiftUI

/// Screenshots, reading text from the screen, hiding private text, and marking pictures up.
struct CapturePane: View {
    @EnvironmentObject private var capture: ScreenCaptureService
    @ObservedObject var store: CaptureSettingsStore
    @State private var screenAllowed = CGPreflightScreenCaptureAccess()
    @State private var newWord = ""

    private var settings: CaptureSettings { store.settings }

    var body: some View {
        Form {
            if !screenAllowed {
                Section {
                    Banner(symbol: "rectangle.dashed.badge.record", tint: Theme.warn, title: "Screen Recording is off for Kriya", message: "macOS asks for this before any app may capture the screen. Kriya only captures when you ask it to.") {
                        Button("Allow…") {
                            CGRequestScreenCaptureAccess()
                            screenAllowed = CGPreflightScreenCaptureAccess()
                        }.controlSize(.small)
                    }
                }
            }

            Section {
                HStack(spacing: 8) {
                    ForEach(CaptureMode.allCases) { mode in
                        Button { capture.capture(mode) } label: { Label(mode.title, systemImage: mode.symbol) }
                    }
                    Button { capture.capture(.region, action: .text) } label: { Label("Copy Text", systemImage: "text.viewfinder") }
                    Spacer()
                }
                .disabled(capture.isCapturing)
            } header: { Text("Capture now") } footer: {
                Text("Region and window captures use the system's own selection: drag, or click a window, and press Escape to cancel. “Copy Text” reads the words in the region you pick and copies only the text. Scrolling captures are not included.")
            }

            Section {
                Toggle("Copy the picture to the clipboard", isOn: bind(\.copyImage))
                Toggle("Save it in a folder", isOn: bind(\.saveToFolder))
                if settings.saveToFolder {
                    LabeledContent("Folder") {
                        HStack {
                            Text(settings.folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Button("Choose…") { chooseFolder() }.controlSize(.small)
                            if !settings.folderPath.isEmpty { Button("Reset") { store.update { $0.folderPath = "" } }.controlSize(.small) }
                        }
                    }
                }
                Toggle("Open the editor to mark it up first", isOn: bind(\.openEditor))
                Toggle("Hide private text automatically", isOn: bind(\.redactAutomatically))
                Picker("Wait before capturing", selection: Binding(get: { settings.delaySeconds }, set: { v in store.update { $0.delaySeconds = v } })) {
                    Text("No wait").tag(0); Text("3 seconds").tag(3); Text("5 seconds").tag(5); Text("10 seconds").tag(10)
                }
                Toggle("Play the camera sound", isOn: bind(\.playSound))
            } header: { Text("After a capture") } footer: {
                Text("Pictures are made and kept on this Mac. Reading text and hiding private text use the Mac's own text recognition, with no internet.")
            }

            Section {
                if settings.redactWords.isEmpty { Text("None.").font(.callout).foregroundStyle(.secondary) }
                ForEach(settings.redactWords, id: \.self) { word in
                    HStack {
                        Text(word)
                        Spacer()
                        Button(role: .destructive) { store.update { $0.redactWords.removeAll { $0 == word } } } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("A name or word to hide", text: $newWord).onSubmit(addWord)
                    Button("Add", action: addWord).disabled(newWord.trimmingCharacters(in: .whitespaces).count < 2)
                }
            } header: { Text("Always hide") } footer: {
                Text("When private text is hidden, these words are covered too, on top of email addresses, phone numbers, card numbers, IP addresses and keys or tokens. Check the result before you share it: text the recognizer cannot read is not covered.")
            }

            Section {
                ForEach(CaptureSettings.commands, id: \.command) { entry in
                    LabeledContent(entry.title) {
                        ShortcutRecorder(shortcut: Binding(
                            get: { store.shortcut(for: entry.command).map { RecordedShortcut(keyCode: $0.keyCode, modifiers: $0.modifiers) } },
                            set: { new in store.setShortcut(entry.command, keyCode: new?.keyCode, modifiers: new?.modifiers ?? 0) }
                        ))
                        .frame(width: 180, height: 26)
                    }
                }
            } header: { Text("Shortcuts") } footer: {
                Text("The same commands (capture.region, capture.window, capture.screen, capture.text, capture.redacted) can be used from a mouse button, a hot corner, a workflow, the selection bar or the launcher.")
            }
        }
        .formStyle(.grouped)
        .onAppear { screenAllowed = CGPreflightScreenCaptureAccess() }
    }

    private func bind(_ path: WritableKeyPath<CaptureSettings, Bool>) -> Binding<Bool> {
        Binding(get: { store.settings[keyPath: path] }, set: { value in store.update { $0[keyPath: path] = value } })
    }

    private func addWord() {
        let word = newWord.trimmingCharacters(in: .whitespaces)
        guard word.count >= 2 else { return }
        store.update { $0.redactWords.append(word) }
        newWord = ""
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Where should captures be saved?"
        if panel.runModal() == .OK, let url = panel.url { store.update { $0.folderPath = url.path } }
    }
}
