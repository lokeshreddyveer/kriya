import AppKit
import SwiftUI

/// Screenshots, reading text from the screen, hiding private text, and marking pictures up.
struct CapturePane: View {
    @EnvironmentObject private var capture: ScreenCaptureService
    @ObservedObject var store: CaptureSettingsStore
    @State private var screenAllowed = CGPreflightScreenCaptureAccess()
    @State private var newWord = ""
    @StateObject private var profiles = CaptureProfileStore()
    @State private var profileName = ""
    @AppStorage(OCRLanguages.defaultsKey) private var ocrLanguages = ""
    @ObservedObject private var registry = ShortcutRegistry.shared
    private let systemEditor = SystemShortcutEditor()
    @State private var systemStates = SystemShortcutEditor().states()
    @State private var keysNote: String?

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
                HStack(spacing: 8) {
                    Button { capture.capture(.window, action: .scroll) } label: { Label("Whole Page", systemImage: "arrow.down.to.line") }
                    Button { capture.capture(.region, action: .record) } label: { Label("Record", systemImage: "record.circle") }
                    Button { capture.capture(.region, action: .recordGIF) } label: { Label("Record GIF", systemImage: "photo.stack") }
                    Button { capture.capture(.region, action: .qr) } label: { Label("Read QR Code", systemImage: "qrcode.viewfinder") }
                    Button { capture.capture(.screen, action: .ruler) } label: { Label("Pixel Ruler", systemImage: "ruler") }
                    Button { capture.capture(.screen, action: .pin) } label: { Label("Pin", systemImage: "pin") }
                    Spacer()
                }
                .disabled(capture.isCapturing)
                RecordingControls(capture: capture)
            } header: { Text("Capture now") } footer: {
                Text("Region and window captures use the system's own selection: drag, or click a window, and press Escape to cancel. “Copy Text” reads the words in the region you pick and copies only the text. “Whole Page” scrolls the window in front by itself and joins the pages, so keep the mouse still; pages with a bar fixed at the top may repeat it. “Record” and “Record GIF” use the system recorder: choose the area, then click its stop button in the menu bar. “Read QR Code” copies what the code says. “Pixel Ruler” freezes the screen: move for a magnifier and the colour under the pointer, drag to measure a box, click to measure the box of one colour, hold ⌥ for distances to the edges, C copies the colour and Return copies the size.")
            }

            RecordingSection(store: store)

            CaptureHistorySection()

            Section {
                let supported = TextRecognizer.supportedLanguages
                let chosen = OCRLanguages.parse(ocrLanguages)
                Text(OCRLanguages.summary(chosen: chosen)).font(.callout).foregroundStyle(.secondary)
                Menu("Choose Languages") {
                    Button("Automatic") { ocrLanguages = "" }
                    Divider()
                    ForEach(supported, id: \.self) { code in
                        Button { ocrLanguages = OCRLanguages.join(chosen.contains(code) ? chosen.filter { $0 != code } : chosen + [code]) } label: {
                            Label(OCRLanguages.name(of: code), systemImage: chosen.contains(code) ? "checkmark" : "")
                        }
                    }
                }.fixedSize()
            } header: { Text("Text in pictures (OCR)") } footer: { Text("Pick up to five languages if the automatic choice misreads. Reading happens on this Mac.") }

            Section {
                ForEach(profiles.profiles) { profile in
                    HStack {
                        Text(profile.name)
                        Spacer()
                        Button("Use") { store.update { $0 = profile.applied(to: $0) } }.controlSize(.small)
                        Button(role: .destructive) { profiles.profiles.removeAll { $0.id == profile.id } } label: { Image(systemName: "trash") }.buttonStyle(.borderless).accessibilityLabel("Delete \(profile.name)")
                    }
                }
                HStack {
                    TextField("Name for the current settings", text: $profileName)
                    Button("Save") { profiles.profiles.append(CaptureProfile.from(settings, named: profileName.trimmingCharacters(in: .whitespaces))); profileName = "" }
                        .disabled(profileName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: { Text("Capture profiles") } footer: { Text("A profile sets where the picture goes and what happens to it. Your shortcuts, hidden words and recording options stay as they are.") }

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
                Toggle("Include the pointer in screenshots", isOn: Binding(get: { settings.includeCursor ?? false }, set: { v in store.update { $0.includeCursor = v } }))
                VStack(alignment: .leading, spacing: 4) {
                    TextField("File name", text: Binding(get: { settings.namePattern ?? CaptureNaming.defaultPattern }, set: { value in store.update { $0.namePattern = value == CaptureNaming.defaultPattern ? nil : value } }))
                    if let problem = CaptureNaming.problem(settings.namePattern ?? CaptureNaming.defaultPattern) { Text(problem).font(.caption).foregroundStyle(Theme.danger) }
                    else {
                        Text("Example: " + CaptureNaming.fileName(pattern: settings.namePattern, date: Date(), app: NSWorkspace.shared.frontmostApplication?.localizedName ?? "Safari", mode: "capture", ext: "png")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: { Text("After a capture") } footer: {
                Text("In the file name, {date}, {time}, {app} (the app in front), {mode} and {n} are filled in; recordings use the same pattern with “Recording” in place of “Capture”. Pictures are made and kept on this Mac. Reading text and hiding private text use the Mac's own text recognition, with no internet.")
            }

            CaptureOutputSection()
            CaptureUploadSection()

            Section {
                if settings.redactWords.isEmpty { Text("None.").font(.callout).foregroundStyle(.secondary) }
                ForEach(settings.redactWords, id: \.self) { word in
                    HStack {
                        Text(word)
                        Spacer()
                        Button(role: .destructive) { store.update { $0.redactWords.removeAll { $0 == word } } } label: { Image(systemName: "trash") }.accessibilityLabel("Delete").buttonStyle(.borderless)
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
                macOSKeysBanner
                ForEach(CaptureSettings.commands, id: \.command) { entry in
                    LabeledContent(entry.title) {
                        VStack(alignment: .trailing, spacing: 3) {
                            ShortcutRecorder(shortcut: Binding(
                                get: { store.shortcut(for: entry.command).map { RecordedShortcut(keyCode: $0.keyCode, modifiers: $0.modifiers) } },
                                set: { new in store.setShortcut(entry.command, keyCode: new?.keyCode, modifiers: new?.modifiers ?? 0) }
                            ), needsModifier: true)
                            .frame(width: 180, height: 26)
                            if let problem = problem(for: entry.command) {
                                Text(problem).font(.caption).foregroundStyle(Theme.warn).multilineTextAlignment(.trailing).frame(maxWidth: 300, alignment: .trailing).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            } header: { Text("Shortcuts") } footer: {
                Text("The same commands (capture.region, capture.window, capture.screen, capture.text, capture.redacted, capture.qr, capture.record, capture.gif, capture.scroll, capture.ruler, capture.pin) can be used from a mouse button, a hot corner, a workflow, the selection bar or the launcher.")
            }
        }
        .formStyle(.grouped)
        .onAppear { screenAllowed = CGPreflightScreenCaptureAccess() }
    }

    // MARK: Shortcuts and macOS's own screenshot keys

    /// Said when a saved shortcut was refused, with the reason: macOS's own screenshot keys are the usual one.
    private func problem(for command: String) -> String? {
        guard let saved = store.shortcut(for: command) else { return nil }
        let entry = registry.entries.first { $0.owner == "Screen capture" && $0.command == command }
        guard entry?.status == .refused else { return nil }
        if let known = SystemScreenshotKeys.occupant(keyCode: saved.keyCode, modifiers: saved.modifiers, states: systemStates) {
            return "macOS uses these keys for “\(known.name)”. Use “Let Kriya use ⌘⇧3, ⌘⇧4 and ⌘⇧5” above, or choose other keys."
        }
        return "These keys did not work: another app, or macOS itself, already uses them. Choose other keys."
    }

    private var macOSKeysBanner: some View {
        let still = SystemScreenshotKeys.enabled(states: systemStates, among: SystemScreenshotKeys.usual)
        let released = systemEditor.released
        return VStack(alignment: .leading, spacing: 8) {
            if !still.isEmpty {
                Banner(symbol: "keyboard", tint: Theme.warn, title: "macOS is still using ⌘⇧3, ⌘⇧4 and ⌘⇧5", message: "macOS takes these keys before any app sees them, so pressing them here (to record them, or to capture) takes a macOS screenshot instead. Kriya can turn macOS's off and use them for its own capture. You can give them back here at any time.") {
                    Button("Let Kriya use ⌘⇧3, ⌘⇧4 and ⌘⇧5…") { useUsualKeys() }.controlSize(.small)
                }
            }
            if !released.isEmpty {
                Banner(symbol: "checkmark.circle", tint: Theme.ok, title: "macOS's screenshot keys are off", message: "Kriya turned them off so it can use them. Turn them back on to go back to how macOS was.") {
                    Button("Give Them Back to macOS") { giveBack() }.controlSize(.small)
                }
            }
            if let note = keysNote { Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }

    private func useUsualKeys() {
        let alert = NSAlert()
        alert.messageText = "Let Kriya use ⌘⇧3, ⌘⇧4 and ⌘⇧5?"
        alert.informativeText = "macOS's own screenshot shortcuts on those keys are turned off, and Kriya's are set: ⌘⇧3 captures the whole screen, ⌘⇧4 an area, ⌘⇧5 records the screen. You can change each below, and give the keys back to macOS here at any time. If the keys still do the macOS thing afterwards, sign out and back in once."
        alert.addButton(withTitle: "Use These Keys")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard systemEditor.release(SystemScreenshotKeys.usual) else {
            keysNote = "macOS did not let Kriya change its shortcuts. Turn them off yourself in System Settings › Keyboard › Keyboard Shortcuts › Screenshots."
            return
        }
        let cmdShift = KeyModifiers.command | KeyModifiers.shift
        store.setShortcut("capture.screen", keyCode: 20, modifiers: cmdShift)
        store.setShortcut("capture.region", keyCode: 21, modifiers: cmdShift)
        store.setShortcut("capture.rec.screen", keyCode: 23, modifiers: cmdShift)
        keysNote = "Done. Kriya's capture now answers ⌘⇧3, ⌘⇧4 and ⌘⇧5."
        reloadAfterSystemChange()
    }

    private func giveBack() {
        keysNote = systemEditor.giveBack() ? "macOS's screenshot keys are on again. Kriya's shortcuts on the same keys will stop working until you choose other keys." : "macOS did not let Kriya change its shortcuts."
        reloadAfterSystemChange()
    }

    /// The system takes a moment to apply a change; once it has, Kriya asks for its shortcuts again so ones refused earlier are tried anew.
    private func reloadAfterSystemChange() {
        systemStates = systemEditor.states()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            systemStates = systemEditor.states()
            capture.reregisterShortcuts()
        }
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

/// The last pictures and recordings in the capture folder, to pin, copy or find again.
struct CaptureHistorySection: View {
    @EnvironmentObject private var capture: ScreenCaptureService
    @State private var entries: [CaptureHistory.Entry] = []

    var body: some View {
        Section {
            if entries.isEmpty { Text("Nothing in the capture folder yet.").foregroundStyle(.secondary) }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(entries) { entry in
                        VStack(spacing: 4) {
                            thumbnail(entry).frame(width: 120, height: 80).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
                            Text(entry.date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                if !entry.isMovie { Button { if let image = NSImage(contentsOfFile: entry.path) { PinnedShots.shared.pin(image) } } label: { Image(systemName: "pin") }.help("Pin on screen").accessibilityLabel("Pin on screen") }
                                if !entry.isMovie { Button { if let image = NSImage(contentsOfFile: entry.path) { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([image]) } } label: { Image(systemName: "doc.on.doc") }.help("Copy").accessibilityLabel("Copy") }
                                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)]) } label: { Image(systemName: "magnifyingglass") }.help("Show in Finder").accessibilityLabel("Show in Finder")
                            }.buttonStyle(.borderless).controlSize(.small)
                        }
                    }
                }
            }
        } header: {
            HStack { Text("Recent captures"); Spacer(); Button { reload() } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Refresh").buttonStyle(.borderless) }
        } footer: {
            Text("Pin keeps a picture on top of everything: drag it, scroll to resize it, ⌥-scroll to make it see-through, double-click to close.")
        }
        .onAppear(perform: reload)
    }

    @ViewBuilder
    private func thumbnail(_ entry: CaptureHistory.Entry) -> some View {
        if entry.isMovie { ZStack { Color.black.opacity(0.7); Image(systemName: "play.fill").foregroundStyle(.white) } }
        else if let image = NSImage(contentsOfFile: entry.path) { Image(nsImage: image).resizable().scaledToFill() }
        else { Color.gray.opacity(0.2) }
    }

    private func reload() { entries = CaptureHistory.read(folder: capture.settings.settings.folder, limit: 12) }
}

/// Buttons for Kriya's own recorder, which turn into Pause and Stop while it runs.
private struct RecordingControls: View {
    @ObservedObject var capture: ScreenCaptureService
    @ObservedObject private var recorder: ScreenRecorder

    init(capture: ScreenCaptureService) {
        self.capture = capture
        _recorder = ObservedObject(wrappedValue: capture.recording.recorder)
    }

    var body: some View {
        HStack(spacing: 8) {
            if recorder.state == .recording || recorder.state == .paused {
                Button { capture.capture(.screen, action: .pauseRecording) } label: {
                    Label(recorder.state == .paused ? "Resume" : "Pause", systemImage: recorder.state == .paused ? "play.fill" : "pause.fill")
                }
                Button { capture.capture(.screen, action: .stopRecording) } label: { Label("Stop and Save", systemImage: "stop.fill") }
            } else {
                Button { capture.capture(.screen, action: .recordScreen) } label: { Label("Record Screen", systemImage: "record.circle.fill") }
                Button { capture.capture(.window, action: .recordWindow) } label: { Label("Record Window", systemImage: "macwindow") }
                Button { capture.capture(.window, action: .recordApp) } label: { Label("Record App", systemImage: "app.dashed") }
                Button { capture.capture(.window, action: .mirror) } label: { Label("Float a Window", systemImage: "rectangle.on.rectangle") }
                    .help("A live, view-only copy of the window in front that stays on top")
            }
            Spacer()
        }
        .disabled(recorder.state == .starting || recorder.state == .stopping)
    }
}

/// How Kriya's own recorder records.
private struct RecordingSection: View {
    @ObservedObject var store: CaptureSettingsStore

    private var options: RecordingOptions { store.settings.recording }

    private func bind<T>(_ path: WritableKeyPath<RecordingOptions, T>) -> Binding<T> {
        Binding(get: { store.settings.recording[keyPath: path] }, set: { value in store.update { $0.recording[keyPath: path] = value } })
    }

    var body: some View {
        Section {
            Toggle("Record the Mac's sound", isOn: bind(\.systemAudio))
            Toggle("Record the microphone", isOn: bind(\.microphone))
            Toggle("Show the keys I press", isOn: bind(\.showKeystrokes))
            Toggle("Show the camera in a small window", isOn: bind(\.webcam))
            Toggle("Show the pointer", isOn: bind(\.showCursor))
            Toggle("Record in HDR", isOn: bind(\.hdr)).disabled(!ScreenRecorder.hdrAvailable)
            Picker("Frame rate", selection: bind(\.framesPerSecond)) {
                ForEach(RecordingOptions.allowedFrameRates, id: \.self) { Text("\($0) per second").tag($0) }
            }
        } header: { Text("Recording") } footer: {
            Text("Record Screen, Record Window and Record App use Kriya's own recorder, which saves a movie in the capture folder. The Mac's sound and the microphone go on separate audio tracks. Pause cuts the paused time out, so the movie has no gap. The keys and the camera are shown in windows on screen, so they are in a screen or app recording but not a window recording. A password field never shows its keys. HDR needs macOS 15 and a screen that supports it, and is untested on some displays. The first time Screen Recording is allowed, quit and open Kriya again.")
        }
    }
}
